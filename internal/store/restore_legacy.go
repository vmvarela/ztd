package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"ztd/internal/app"
	"ztd/internal/domain"
)

// Restore old exports into an isolated schema-7 database, then run the same
// migrations as an installed database. The destination is untouched on failure.
func (s *Store) restoreLegacyExport(ctx context.Context, doc exportDoc) (app.RestoreReport, error) {
	dir, err := os.MkdirTemp("", "ztd-restore-")
	if err != nil {
		return app.RestoreReport{}, err
	}
	defer os.RemoveAll(dir)
	db, err := sql.Open("sqlite", filepath.Join(dir, "old.db")+"?_pragma=foreign_keys(1)")
	if err != nil {
		return app.RestoreReport{}, err
	}
	old := &Store{db: db}
	defer old.Close()
	db.SetMaxOpenConns(1)
	migrations, err := loadMigrations()
	if err != nil {
		return app.RestoreReport{}, err
	}
	for _, m := range migrations {
		if m.version > 7 {
			break
		}
		if err := old.applyMigration(ctx, m); err != nil {
			return app.RestoreReport{}, err
		}
	}
	tables := []tableDef{{"scopes", nil}, {"profiles", nil}, {"profile_scopes", nil}, {"contexts", nil}, {"areas", nil}, {"projects", nil}, {"documents", nil}, {"captures", nil}, {"sources", nil}, {"source_reviews", nil}, {"work_items", nil}, {"plans", nil}, {"plan_items", nil}, {"routines", nil}, {"knowledge_records", nil}, {"daily_limit_overrides", nil}, {"calendar_review_assertions", nil}, {"focus_sessions", nil}, {"checkpoints", nil}, {"reviews", nil}, {"history_events", nil}, {"idempotency_records", nil}, {"import_runs", nil}, {"legacy_records", nil}, {"goals", nil}}
	// goals were omitted by the v1 exporter. Accept them if explicitly present.
	known := map[string]bool{}
	for _, t := range tables {
		known[t.name] = true
		if _, ok := doc.Tables[t.name]; !ok && t.name != "goals" {
			return app.RestoreReport{}, domain.NewError(domain.UnsupportedFormat, "legacy export is missing table %s", t.name)
		}
	}
	for name := range doc.Tables {
		if !known[name] {
			return app.RestoreReport{}, domain.NewError(domain.UnsupportedFormat, "unknown legacy table %s", name)
		}
	}
	err = old.withTx(ctx, func(tx *sql.Tx) error {
		if _, err := tx.ExecContext(ctx, "PRAGMA defer_foreign_keys=ON"); err != nil {
			return err
		}
		for _, t := range tables {
			cols, err := tableColumns(ctx, tx, t.name)
			if err != nil {
				return err
			}
			for _, row := range doc.Tables[t.name] {
				if err := insertRow(ctx, tx, t.name, cols, row); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return app.RestoreReport{}, err
	}
	for _, m := range migrations {
		if m.version <= 7 {
			continue
		}
		if err := old.applyMigration(ctx, m); err != nil {
			return app.RestoreReport{}, err
		}
	}
	out := filepath.Join(dir, "upgraded.json")
	if err := old.Export(ctx, out); err != nil {
		return app.RestoreReport{}, err
	}
	return s.Restore(ctx, out)
}
