package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"ztd/internal/domain"
)

// Store owns the SQLite persistence behind the app.Repo methods implemented in
// this package.
type Store struct {
	db *sql.DB
}

// Close releases the connection pool.
func (s *Store) Close() error { return s.db.Close() }

// queryer is satisfied by both *sql.DB and *sql.Tx.
type queryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

type scanner interface{ Scan(dest ...any) error }

// withTx runs fn inside one short BEGIN IMMEDIATE transaction (the pool is
// opened with _txlock=immediate); any error from fn rolls back every write,
// current state, history and idempotency record alike.
func (s *Store) withTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return busyOrRaw(err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return busyOrRaw(err)
	}
	return nil
}

func busyOrRaw(err error) error {
	if isBusy(err) {
		return domain.NewError(domain.DBBusy, "%v", err)
	}
	return err
}

func isBusy(err error) bool {
	msg := err.Error()
	return strings.Contains(msg, "database is locked") ||
		strings.Contains(msg, "database table is locked") ||
		strings.Contains(msg, "SQLITE_BUSY") ||
		strings.Contains(msg, "busy")
}

// hashPayload is the canonical request hash: sha256 of the JSON encoding of
// the command struct. Go marshals struct fields in declaration order, so equal
// payloads always hash equally.
func hashPayload(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", domain.Invalid("request payload is not serializable: %v", err)
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

func sha256hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// idDate is the compact UTC date used inside generated ids: C-20261119-001.
func idDate(t time.Time) string { return t.UTC().Format("20060102") }

// lookupIdem is the idempotency contract: the same key with the same payload
// hash replays the stored result into out; the same key with a different hash
// returns domain.IdempotencyConflict. It performs no writes. Callers must run
// it inside the write transaction so two racing processes serialize.
func lookupIdem(ctx context.Context, q queryer, command, key, hash string, out any) (done bool, err error) {
	var storedHash, result string
	err = q.QueryRowContext(ctx,
		"SELECT request_hash, result_json FROM idempotency_records WHERE command = ? AND idempotency_key = ?",
		command, key).Scan(&storedHash, &result)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, err
	}
	if storedHash != hash {
		return false, domain.NewError(domain.IdempotencyConflict,
			"idempotency key %q was already used with a different payload", key)
	}
	if err := json.Unmarshal([]byte(result), out); err != nil {
		return false, domain.NewError(domain.IOError, "stored result for idempotency key %q is unreadable: %v", key, err)
	}
	return true, nil
}

// writeIdem records the command result next to the state it produced; both
// commit or roll back together.
func writeIdem(ctx context.Context, q queryer, command, key, hash string, result any, now time.Time) error {
	b, err := json.Marshal(result)
	if err != nil {
		return domain.Invalid("result for idempotency key %q is not serializable: %v", key, err)
	}
	_, err = q.ExecContext(ctx,
		`INSERT INTO idempotency_records (command, idempotency_key, request_hash, result_json, created_at)
		     VALUES (?, ?, ?, ?, ?)`,
		command, key, hash, string(b), fmtTime(now))
	return err
}

// fmtTime stores every timestamp as second-precision UTC RFC3339, so
// lexicographic comparison in SQL matches chronological order.
func fmtTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func parseTime(col, s string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, domain.NewError(domain.IOError, "invalid timestamp in %s: %q", col, s)
	}
	return t, nil
}

func nullTime(col string, ns sql.NullString) (*time.Time, error) {
	if !ns.Valid {
		return nil, nil
	}
	t, err := parseTime(col, ns.String)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func argTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return fmtTime(*t)
}

func scopeFilter(n int) string {
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

func scopeArgs(b domain.ScopeBinding) []any {
	args := make([]any, 0, len(b.Scopes))
	for _, sc := range b.Scopes {
		args = append(args, string(sc))
	}
	return args
}

// scopeClause renders the binding scope list for SQL; an empty scope list is
// rejected instead of producing an empty IN clause.
func scopeClause(b domain.ScopeBinding) (string, []any, error) {
	if len(b.Scopes) == 0 {
		return "", nil, domain.Invalid("at least one scope is required")
	}
	return scopeFilter(len(b.Scopes)), scopeArgs(b), nil
}

func requireKey(key string) error {
	if strings.TrimSpace(key) == "" {
		return domain.Invalid("idempotency key is required")
	}
	return nil
}

// rowAccessError distinguishes an absent row (not_found) from a row that
// exists but lies outside the binding scopes (scope_denied), without leaking
// the foreign row's contents.
func rowAccessError(ctx context.Context, q queryer, table, noun, id string) error {
	var one int
	err := q.QueryRowContext(ctx, "SELECT 1 FROM "+table+" WHERE id = ?", id).Scan(&one)
	switch {
	case err == nil:
		return domain.NewError(domain.ScopeDenied, "%s %s is outside the active scopes", noun, id)
	case errors.Is(err, sql.ErrNoRows):
		return domain.NewError(domain.NotFound, "%s %s not found", noun, id)
	default:
		return err
	}
}

// checkSameScope enforces that a referenced context/area/project row exists
// and belongs to scope.
func checkSameScope(ctx context.Context, q queryer, table, noun, id string, scope domain.ScopeID) error {
	var owner string
	err := q.QueryRowContext(ctx, "SELECT scope_id FROM "+table+" WHERE id = ?", id).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return domain.Invalid("unknown %s reference %s", noun, id)
	case err != nil:
		return err
	}
	if domain.ScopeID(owner) != scope {
		return domain.NewError(domain.ScopeDenied, "%s %s belongs to scope %s, not %s", noun, id, owner, scope)
	}
	return nil
}

// nextDailySeq returns the first unused numeric suffix after prefix (for
// example "T-20261119-"). The caller holds the write transaction, which makes
// the sequence race-free; ids that merely share the prefix but do not end in a
// number are ignored.
func nextDailySeq(ctx context.Context, q queryer, table, prefix string) (int, error) {
	rows, err := q.QueryContext(ctx, "SELECT id FROM "+table+" WHERE id LIKE ?", prefix+"%")
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	max := 0
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return 0, err
		}
		n, err := strconv.Atoi(strings.TrimPrefix(id, prefix))
		if err != nil {
			continue
		}
		if n > max {
			max = n
		}
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	return max + 1, nil
}

// SeedDefaults idempotently inserts, if absent, the personal and opensource
// scopes and the default personal profile owned by actor with the local
// timezone, linked to both scopes. One transaction; a second call changes
// nothing and creates no duplicates. Seeding is operator setup, not a model
// command, so it writes no history or idempotency record.
func (s *Store) SeedDefaults(ctx context.Context, actor string) error {
	actor = strings.TrimSpace(actor)
	if actor == "" {
		return domain.Invalid("actor is required")
	}
	return s.withTx(ctx, func(tx *sql.Tx) error {
		now := fmtTime(domain.NowUTC())
		for _, sc := range []struct{ id, kind string }{
			{id: "personal", kind: "personal"},
			{id: "opensource", kind: "opensource"},
		} {
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)
				     ON CONFLICT(id) DO NOTHING`,
				sc.id, sc.id, sc.kind, now); err != nil {
				return err
			}
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO profiles (id, name, kind, owner_actor_id, timezone, status)
			     VALUES ('personal', 'Personal', 'personal', ?, ?, 'active')
			     ON CONFLICT(id) DO NOTHING`,
			actor, localTimezone()); err != nil {
			return err
		}
		for _, sc := range []string{"personal", "opensource"} {
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO profile_scopes (profile_id, scope_id) VALUES ('personal', ?)
				     ON CONFLICT(profile_id, scope_id) DO NOTHING`, sc); err != nil {
				return err
			}
		}
		return nil
	})
}

// localTimezone resolves time.Local to its zone name ("Europe/Madrid") when
// possible, falling back to the Go location name ("Local").
func localTimezone() string {
	if n := time.Local.String(); n != "" && n != "Local" {
		return n
	}
	if target, err := filepath.EvalSymlinks("/etc/localtime"); err == nil {
		const marker = "zoneinfo/"
		if i := strings.LastIndex(target, marker); i >= 0 {
			return target[i+len(marker):]
		}
	}
	return time.Local.String()
}
