package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const scopeColumns = `id, name, kind, created_at`
const profileColumns = `id, name, kind, owner_actor_id, timezone, status`

func scanScope(sc scanner) (domain.Scope, error) {
	var (
		s       domain.Scope
		kind    string
		created string
	)
	if err := sc.Scan(&s.ID, &s.Name, &kind, &created); err != nil {
		return domain.Scope{}, err
	}
	s.Kind = domain.ScopeKind(kind)
	createdAt, err := parseTime("scopes.created_at", created)
	if err != nil {
		return domain.Scope{}, err
	}
	s.CreatedAt = createdAt
	return s, nil
}

func scanProfile(sc scanner) (domain.Profile, error) {
	var p domain.Profile
	if err := sc.Scan(&p.ID, &p.Name, &p.Kind, &p.OwnerActor, &p.Timezone, &p.Status); err != nil {
		return domain.Profile{}, err
	}
	return p, nil
}

// addScopeTx applies one scope declaration inside an existing transaction.
// existed reports whether the row was already there with an identical
// configuration.
//
// Pre: cmd passes app.ValidateScopeCmd. Post: an identical row is returned
// untouched, a different kind or name for the same id is conflict, and a new
// id is inserted. Nothing is written on conflict.
func addScopeTx(ctx context.Context, tx *sql.Tx, cmd app.ScopeCmd, now time.Time) (domain.Scope, bool, error) {
	if err := app.ValidateScopeCmd(cmd); err != nil {
		return domain.Scope{}, false, err
	}
	if cmd.Name == "" {
		cmd.Name = cmd.ID
	}
	existing, err := scanScope(tx.QueryRowContext(ctx,
		"SELECT "+scopeColumns+" FROM scopes WHERE id = ?", cmd.ID))
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return domain.Scope{}, false, err
	default:
		if existing.Kind != domain.ScopeKind(cmd.Kind) || existing.Name != cmd.Name {
			return domain.Scope{}, true, domain.NewError(domain.Conflict,
				"scope %s already exists with a different kind or name", cmd.ID)
		}
		return existing, true, nil
	}
	scope := domain.Scope{
		ID: domain.ScopeID(cmd.ID), Name: cmd.Name,
		Kind: domain.ScopeKind(cmd.Kind), CreatedAt: now,
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)`,
		scope.ID, scope.Name, string(scope.Kind), fmtTime(now)); err != nil {
		return domain.Scope{}, false, err
	}
	return scope, false, nil
}

// AddScope declares one scope.
//
// Pre: cmd validates. Post: one transaction. An identical configuration is
// returned without writing; a different kind or name for the same id is
// conflict. Nothing is written on failure.
func (s *Store) AddScope(ctx context.Context, cmd app.ScopeCmd, now time.Time) (domain.Scope, error) {
	now = now.UTC().Truncate(time.Second)
	var out domain.Scope
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var err error
		out, _, err = addScopeTx(ctx, tx, cmd, now)
		return err
	})
	if err != nil {
		return domain.Scope{}, err
	}
	return out, nil
}

// ListScopes returns every declared scope ordered by id, so the listing is
// deterministic across calls.
func (s *Store) ListScopes(ctx context.Context) ([]domain.Scope, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+scopeColumns+" FROM scopes ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Scope{}
	for rows.Next() {
		sc, err := scanScope(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, rows.Err()
}

// Legacy profile methods adapt to singleton settings; scopes are declared once.
func addProfileTx(ctx context.Context, tx *sql.Tx, cmd app.ProfileCmd, now time.Time) (domain.Profile, bool, error) {
	if cmd.ID != "personal" || cmd.Kind != "personal" {
		return domain.Profile{}, false, domain.Invalid("ZTD has one planning view; declare scopes instead of profiles")
	}
	if err := app.ValidateProfileCmd(cmd); err != nil {
		return domain.Profile{}, false, err
	}
	for _, sc := range cmd.Scopes {
		if err := requireScopeDeclared(ctx, tx, domain.ScopeID(sc)); err != nil {
			return domain.Profile{}, false, err
		}
	}
	var owner, zone string
	err := tx.QueryRowContext(ctx, "SELECT owner_actor_id,timezone FROM settings WHERE id=1").Scan(&owner, &zone)
	existed := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return domain.Profile{}, false, err
	}
	if existed && owner != cmd.Actor {
		return domain.Profile{}, true, domain.NewError(domain.Conflict, "store belongs to another owner")
	}
	if !existed {
		owner = cmd.Actor
		zone = localTimezone()
		if _, err := tx.ExecContext(ctx, "INSERT INTO settings(id,owner_actor_id,timezone) VALUES(1,?,?)", owner, zone); err != nil {
			return domain.Profile{}, false, err
		}
	}
	p := domain.Profile{ID: "personal", Name: "Personal", Kind: domain.PersonalProfile, OwnerActor: domain.ActorID(owner), Timezone: zone, Status: "active"}
	rows, err := tx.QueryContext(ctx, "SELECT id FROM scopes ORDER BY rowid")
	if err != nil {
		return p, false, err
	}
	defer rows.Close()
	for rows.Next() {
		var id domain.ScopeID
		if err := rows.Scan(&id); err != nil {
			return p, false, err
		}
		p.Scopes = append(p.Scopes, id)
	}
	return p, existed, rows.Err()
}
func (s *Store) AddProfile(ctx context.Context, cmd app.ProfileCmd, now time.Time) (domain.Profile, error) {
	var p domain.Profile
	err := s.withTx(ctx, func(tx *sql.Tx) error { var err error; p, _, err = addProfileTx(ctx, tx, cmd, now); return err })
	return p, err
}
func (s *Store) SetProfileScopes(ctx context.Context, id domain.ProfileID, scopes []domain.ScopeID, now time.Time) (domain.Profile, error) {
	return domain.Profile{}, domain.Invalid("the planning view covers declared scopes; narrow the session binding instead")
}
func (s *Store) ListProfiles(ctx context.Context) ([]domain.Profile, error) {
	p, err := scanProfile(s.db.QueryRowContext(ctx, "SELECT "+profileColumns+" FROM profiles"))
	if errors.Is(err, sql.ErrNoRows) {
		return []domain.Profile{}, nil
	}
	if err != nil {
		return nil, err
	}
	p.Scopes, err = s.ProfileScopes(ctx, "personal")
	return []domain.Profile{p}, err
}
func (s *Store) ApplyConfig(ctx context.Context, scopes []app.ScopeCmd, profiles []app.ProfileCmd, now time.Time) (app.ConfigResult, error) {
	if len(scopes) == 0 || len(profiles) != 1 {
		return app.ConfigResult{}, domain.Invalid("declare scopes and one owner")
	}
	res := app.ConfigResult{Scopes: []app.ConfigEntry{}, Profiles: []app.ConfigEntry{}}
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		for _, cmd := range scopes {
			_, exists, err := addScopeTx(ctx, tx, cmd, now)
			if err != nil {
				return err
			}
			res.Scopes = append(res.Scopes, app.ConfigEntry{ID: cmd.ID, Existed: exists})
		}
		_, exists, err := addProfileTx(ctx, tx, profiles[0], now)
		if err != nil {
			return err
		}
		res.Profiles = append(res.Profiles, app.ConfigEntry{ID: "personal", Existed: exists})
		return nil
	})
	return res, err
}
func (s *Store) ProfileScopes(ctx context.Context, profile domain.ProfileID) ([]domain.ScopeID, error) {
	var one int
	if profile != "personal" {
		return nil, domain.NewError(domain.NotFound, "unknown planning view")
	}
	if err := s.db.QueryRowContext(ctx, "SELECT 1 FROM settings").Scan(&one); errors.Is(err, sql.ErrNoRows) {
		return nil, domain.NewError(domain.NotFound, "run ztd init first")
	} else if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id FROM scopes ORDER BY rowid")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.ScopeID{}
	for rows.Next() {
		var id domain.ScopeID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
