package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

type tableDef struct {
	name string
	pk   []string
}

// canonicalTables lists every exportable table once, in dependency order —
// restore inserts in this order — with the primary key that fixes row order.
var canonicalTables = []tableDef{
	{name: "scopes", pk: []string{"id"}},
	{name: "profiles", pk: []string{"id"}},
	{name: "profile_scopes", pk: []string{"profile_id", "scope_id"}},
	{name: "contexts", pk: []string{"id"}},
	{name: "areas", pk: []string{"id"}},
	{name: "projects", pk: []string{"id"}},
	{name: "documents", pk: []string{"id"}},
	{name: "captures", pk: []string{"id"}},
	{name: "sources", pk: []string{"id"}},
	{name: "source_reviews", pk: []string{"id"}},
	{name: "work_items", pk: []string{"id"}},
	{name: "plans", pk: []string{"id"}},
	{name: "plan_items", pk: []string{"plan_id", "work_item_id"}},
	{name: "routines", pk: []string{"id"}},
	{name: "knowledge_records", pk: []string{"id"}},
	{name: "daily_limit_overrides", pk: []string{"id"}},
	{name: "calendar_review_assertions", pk: []string{"id"}},
	{name: "focus_sessions", pk: []string{"id"}},
	{name: "checkpoints", pk: []string{"id"}},
	{name: "reviews", pk: []string{"id"}},
	{name: "history_events", pk: []string{"seq"}},
	{name: "idempotency_records", pk: []string{"command", "idempotency_key"}},
	{name: "import_runs", pk: []string{"id"}},
	{name: "legacy_records", pk: []string{"source", "entity_type", "entity_id"}},
}

type exportDoc struct {
	Format  string                      `json:"format"`
	Version int                         `json:"version"`
	Tables  map[string][]map[string]any `json:"tables"`
}

// jsonValue converts a driver value into its JSON representation; SQL NULL is
// null and text blobs arrive as their string bytes.
func jsonValue(v any) any {
	switch t := v.(type) {
	case nil:
		return nil
	case int64, float64, string, bool:
		return t
	case []byte:
		return string(t)
	case time.Time:
		return fmtTime(t)
	default:
		return fmt.Sprint(t)
	}
}

// Export writes every row of every canonical table across all scopes to one
// deterministic JSON document: fixed table list, rows ordered by primary key.
func (s *Store) Export(ctx context.Context, out string) error {
	if strings.TrimSpace(out) == "" {
		return domain.Invalid("export path is required")
	}
	tables := make(map[string][]map[string]any, len(canonicalTables))
	for _, t := range canonicalTables {
		rows, err := s.db.QueryContext(ctx, "SELECT * FROM "+t.name+" ORDER BY "+strings.Join(t.pk, ", "))
		if err != nil {
			return err
		}
		cols, err := rows.Columns()
		if err != nil {
			rows.Close()
			return err
		}
		list := make([]map[string]any, 0)
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				rows.Close()
				return err
			}
			row := make(map[string]any, len(cols))
			for i, c := range cols {
				row[c] = jsonValue(vals[i])
			}
			list = append(list, row)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()
		tables[t.name] = list
	}
	b, err := json.Marshal(exportDoc{Format: "ztd-export", Version: 1, Tables: tables})
	if err != nil {
		return domain.Invalid("encode export: %v", err)
	}
	if err := os.WriteFile(out, b, 0o644); err != nil {
		return domain.NewError(domain.IOError, "write export: %v", err)
	}
	return nil
}

// Restore loads a ztd-export version 1 document into an empty database. The
// target must hold no rows in any canonical table; rows are inserted in one
// transaction with foreign keys deferred to commit, then the whole store is
// validated (references, scope ownership, invariants) before that commit — a
// failed or partial input leaves no canonical state behind. Credentials are
// never part of the format and are never read.
func (s *Store) Restore(ctx context.Context, from string) (app.RestoreReport, error) {
	report := app.RestoreReport{Tables: map[string]int{}}
	if strings.TrimSpace(from) == "" {
		return report, domain.Invalid("restore source is required")
	}
	raw, err := os.ReadFile(from)
	if err != nil {
		return report, domain.NewError(domain.IOError, "read export: %v", err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // keep integer ids/revisions exact through the round trip
	var doc exportDoc
	if err := dec.Decode(&doc); err != nil {
		return report, domain.NewError(domain.UnsupportedFormat, "input is not a valid export document: %v", err)
	}
	if doc.Format != "ztd-export" || doc.Version != 1 {
		return report, domain.NewError(domain.UnsupportedFormat,
			"unsupported export format %q version %d (want ztd-export version 1)", doc.Format, doc.Version)
	}
	known := make(map[string]bool, len(canonicalTables))
	for _, t := range canonicalTables {
		known[t.name] = true
		if _, ok := doc.Tables[t.name]; !ok {
			return report, domain.NewError(domain.UnsupportedFormat, "export is missing table %s", t.name)
		}
	}
	for name := range doc.Tables {
		if !known[name] {
			return report, domain.NewError(domain.UnsupportedFormat, "export contains unknown table %s", name)
		}
	}
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		report.Tables = map[string]int{}
		for _, t := range canonicalTables {
			var n int
			if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM "+t.name).Scan(&n); err != nil {
				return err
			}
			if n > 0 {
				return domain.NewError(domain.DestinationNotEmpty,
					"restore target already contains rows in %s", t.name)
			}
		}
		// Row order inside the document is arbitrary; deferring FK enforcement
		// to commit lets self-references restore without a prescribed order.
		if _, err := tx.ExecContext(ctx, "PRAGMA defer_foreign_keys = ON"); err != nil {
			return err
		}
		for _, t := range canonicalTables {
			cols, err := tableColumns(ctx, tx, t.name)
			if err != nil {
				return err
			}
			for _, row := range doc.Tables[t.name] {
				if err := insertRow(ctx, tx, t.name, cols, row); err != nil {
					return err
				}
			}
			report.Tables[t.name] = len(doc.Tables[t.name])
		}
		check, err := runCheck(ctx, tx, nil)
		if err != nil {
			return err
		}
		if !check.OK {
			return domain.Invalid("restored data failed validation: %s", joinCapped(check.Errors))
		}
		return nil
	})
	if err != nil {
		return app.RestoreReport{}, err
	}
	return report, nil
}

// joinCapped renders at most ten validation messages plus a count.
func joinCapped(errs []string) string {
	if len(errs) <= 10 {
		return strings.Join(errs, "; ")
	}
	return strings.Join(errs[:10], "; ") + fmt.Sprintf(" (+%d more)", len(errs)-10)
}

func tableColumns(ctx context.Context, q queryer, table string) (map[string]bool, error) {
	rows, err := q.QueryContext(ctx, "SELECT name FROM pragma_table_info(?)", table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]bool)
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out[name] = true
	}
	return out, rows.Err()
}

// insertRow writes one export row; columns are validated against the live
// schema so an export from a different schema fails before commit.
func insertRow(ctx context.Context, tx *sql.Tx, table string, cols map[string]bool, row map[string]any) error {
	if len(row) == 0 {
		return domain.NewError(domain.UnsupportedFormat, "table %s contains an empty row object", table)
	}
	names := make([]string, 0, len(row))
	for k := range row {
		if !cols[k] {
			return domain.NewError(domain.UnsupportedFormat, "table %s has no column %q", table, k)
		}
		names = append(names, k)
	}
	sort.Strings(names)
	args := make([]any, 0, len(names))
	for _, n := range names {
		v, err := normalizeSQLValue(row[n])
		if err != nil {
			return domain.NewError(domain.UnsupportedFormat, "table %s column %s: %v", table, n, err)
		}
		args = append(args, v)
	}
	query := "INSERT INTO " + table + " (" + strings.Join(names, ", ") + ") VALUES (" + scopeFilter(len(names)) + ")"
	if _, err := tx.ExecContext(ctx, query, args...); err != nil {
		return domain.NewError(domain.UnsupportedFormat, "restore table %s: %v", table, err)
	}
	return nil
}

// normalizeSQLValue turns decoded JSON into the value SQLite expects:
// integer-looking numbers become int64 (so CHECK constraints on integers
// hold), booleans become 0/1, null stays NULL.
func normalizeSQLValue(v any) (any, error) {
	switch t := v.(type) {
	case nil:
		return nil, nil
	case string:
		return t, nil
	case bool:
		if t {
			return int64(1), nil
		}
		return int64(0), nil
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return i, nil
		}
		f, err := t.Float64()
		if err != nil {
			return nil, fmt.Errorf("invalid number %q", t)
		}
		return f, nil
	case int:
		return int64(t), nil
	case int64:
		return t, nil
	case float64:
		return t, nil
	default:
		return nil, fmt.Errorf("unsupported JSON value of type %T", v)
	}
}

// Snapshot writes a consistent point-in-time copy with VACUUM INTO an
// absolute path. An existing file is never overwritten: the destination must
// not exist.
func (s *Store) Snapshot(ctx context.Context, out string) error {
	if strings.TrimSpace(out) == "" {
		return domain.Invalid("snapshot path is required")
	}
	abs, err := filepath.Abs(out)
	if err != nil {
		return domain.NewError(domain.IOError, "resolve snapshot path: %v", err)
	}
	if _, err := os.Stat(abs); err == nil {
		return domain.NewError(domain.DestinationNotEmpty, "snapshot destination %s already exists", abs)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return domain.NewError(domain.IOError, "inspect snapshot destination: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", abs); err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "already exists"):
			return domain.NewError(domain.DestinationNotEmpty, "snapshot destination %s already exists", abs)
		case isBusy(err):
			return domain.NewError(domain.DBBusy, "%v", err)
		default:
			return domain.NewError(domain.IOError, "snapshot: %v", err)
		}
	}
	return nil
}
