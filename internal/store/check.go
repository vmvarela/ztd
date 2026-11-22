package store

import (
	"context"
	"database/sql"
	"fmt"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// Check validates the store and reports every violation. With a binding, row
// checks are limited to the bound scopes and profile; foreign key integrity
// always covers the whole database because a broken reference is broken for
// everyone. OK is false when at least one error was found.
func (s *Store) Check(ctx context.Context, b *domain.ScopeBinding) (app.CheckReport, error) {
	if b != nil {
		if err := b.Validate(); err != nil {
			return app.CheckReport{}, err
		}
	}
	return runCheck(ctx, s.db, b)
}

// idRows runs a single-column query and collects its first column.
func idRows(ctx context.Context, q queryer, query string, args ...any) ([]string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// runCheck is shared by Check (against the live pool) and Restore (against
// the staging transaction, before it commits).
func runCheck(ctx context.Context, q queryer, b *domain.ScopeBinding) (app.CheckReport, error) {
	rep := app.CheckReport{OK: true}
	fail := func(format string, args ...any) {
		rep.OK = false
		rep.Errors = append(rep.Errors, fmt.Sprintf(format, args...))
	}

	scopeSQL, sargs := "", []any(nil)
	planSQL, pargs := "", []any(nil)
	if b != nil {
		scopeSQL = " AND scope_id IN (" + scopeFilter(len(b.Scopes)) + ")"
		sargs = scopeArgs(*b)
		planSQL = " AND profile_id = ?"
		pargs = []any{string(b.Profile)}
	}

	// 1. Referential integrity.
	frows, err := q.QueryContext(ctx, "PRAGMA foreign_key_check")
	if err != nil {
		return app.CheckReport{}, err
	}
	for frows.Next() {
		var table, parent string
		var rowid sql.NullInt64
		var fkid int64
		if err := frows.Scan(&table, &rowid, &parent, &fkid); err != nil {
			frows.Close()
			return app.CheckReport{}, err
		}
		rv := any("NULL")
		if rowid.Valid {
			rv = rowid.Int64
		}
		fail("foreign key violation in %s (rowid %v) references %s", table, rv, parent)
	}
	err = frows.Err()
	frows.Close()
	if err != nil {
		return app.CheckReport{}, err
	}

	// 2-7. Invariant queries. Each returns offending ids; each message takes
	// exactly one id.
	checks := []struct {
		format string
		query  string
		args   []any
	}{
		// Required fields.
		{"work item %s has no title",
			"SELECT id FROM work_items WHERE title IS NULL OR trim(title) = ''" + scopeSQL, sargs},
		{"work item %s has custom fields that are not a JSON object",
			"SELECT id FROM work_items WHERE json_valid(custom_fields) = 0 OR json_type(custom_fields) <> 'object'" + scopeSQL, sargs},
		{"capture %s is missing original text or content hash",
			"SELECT id FROM captures WHERE original_text = '' OR content_hash = ''" + scopeSQL, sargs},
		{"plan %s has no period",
			"SELECT id FROM plans WHERE trim(period) = ''" + planSQL, pargs},
		{"scope %s has no name", "SELECT id FROM scopes WHERE trim(name) = ''", nil},

		// Waiting/archive invariants (the schema cannot express all of these).
		{"work item %s is waiting without waiting_on",
			"SELECT id FROM work_items WHERE lifecycle = 'waiting' AND (waiting_on IS NULL OR waiting_on = '')" + scopeSQL, sargs},
		{"work item %s is archived without closed_at or resolution",
			"SELECT id FROM work_items WHERE lifecycle = 'archived' AND (closed_at IS NULL OR resolution IS NULL OR resolution = '')" + scopeSQL, sargs},
		{"work item %s carries closure fields while not archived",
			"SELECT id FROM work_items WHERE lifecycle <> 'archived' AND (closed_at IS NOT NULL OR closure_kind IS NOT NULL OR (resolution IS NOT NULL AND resolution <> ''))" + scopeSQL, sargs},

		// Capture state/review_after invariant.
		{"capture %s has a review_after that does not match its state",
			"SELECT id FROM captures WHERE (processing_state = 'deferred') <> (review_after IS NOT NULL)" + scopeSQL, sargs},
		{"capture %s is processed or discarded without a recorded outcome",
			"SELECT id FROM captures WHERE processing_state IN ('processed','discarded') AND processing_outcome IS NULL" + scopeSQL, sargs},
		{"capture %s is pending with a recorded outcome",
			"SELECT id FROM captures WHERE processing_state = 'pending' AND processing_outcome IS NOT NULL" + scopeSQL, sargs},

		// External identity completeness and duplicates (rows with a NULL
		// external revision escape the partial unique index).
		{"capture %s has an external id without an external revision",
			"SELECT id FROM captures WHERE external_id IS NOT NULL AND external_revision IS NULL" + scopeSQL, sargs},
		{"capture %s has an external revision without an external id",
			"SELECT id FROM captures WHERE external_revision IS NOT NULL AND external_id IS NULL" + scopeSQL, sargs},
		{"duplicate external identity %s",
			"SELECT scope_id || '/' || source_id || '/' || external_id || '/' || ifnull(external_revision, '<null>') FROM captures" +
				" WHERE external_id IS NOT NULL" + scopeSQL +
				" GROUP BY scope_id, source_id, external_id, external_revision HAVING count(*) > 1", sargs},

		// Source registry invariants.
		{"source %s references a missing scope",
			"SELECT id FROM sources WHERE NOT EXISTS (SELECT 1 FROM scopes WHERE scopes.id = sources.scope_id)" + scopeSQL, sargs},
		{"duplicate source id %s",
			"SELECT id FROM sources GROUP BY id HAVING count(*) > 1", nil},
		{"source review %s references a missing source",
			"SELECT id FROM source_reviews WHERE NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = source_reviews.source_id)", nil},
		{"source review %s has an invalid result kind or coverage",
			"SELECT id FROM source_reviews WHERE result_kind NOT IN ('observed','reported')" +
				" OR coverage_state NOT IN ('unknown','unverified','partial','complete','failed')", nil},
		{"capture %s references a missing source",
			"SELECT id FROM captures WHERE external_id IS NOT NULL" +
				" AND NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = captures.source_id)" + scopeSQL, sargs},

		// Document layer invariants.
		{"document %s references a missing scope",
			"SELECT id FROM documents WHERE NOT EXISTS (SELECT 1 FROM scopes WHERE scopes.id = documents.scope_id)" + scopeSQL, sargs},
		{"document %s has an unknown kind",
			"SELECT id FROM documents WHERE kind NOT IN ('knowledge','knowledge_index','project_note','plan_daily','plan_weekly','review','journal','calendar','adoption','passion','routine')" + scopeSQL, sargs},
		{"document %s has an unknown status",
			"SELECT id FROM documents WHERE status NOT IN ('draft','verified','superseded')" + scopeSQL, sargs},
		{"document %s has an empty slug",
			"SELECT id FROM documents WHERE trim(slug) = ''" + scopeSQL, sargs},

		// Project repository metadata: empty or absolute (POSIX or Windows),
		// never nested.
		{"project %s has a relative clone path",
			"SELECT id FROM projects WHERE clone_path <> '' AND NOT (" +
				"substr(clone_path, 1, 1) IN ('/', '\\')" +
				" OR (length(clone_path) >= 3 AND substr(clone_path, 1, 1) GLOB '[A-Za-z]'" +
				" AND substr(clone_path, 2, 1) = ':' AND substr(clone_path, 3, 1) IN ('/', '\\')))" + scopeSQL, sargs},
		{"project %s has a clone path with a .. segment",
			"SELECT id FROM projects WHERE clone_path <> '' AND ('/' || replace(clone_path, '\\', '/') || '/') LIKE '%/../%'" + scopeSQL, sargs},
		{"project %s has a non-absolute repository url",
			"SELECT id FROM projects WHERE repo_url <> '' AND instr(repo_url, '://') = 0 AND repo_url NOT GLOB '*@*:*'" + scopeSQL, sargs},

		// History is evidence for every committed entity mutation.
		{"capture %s has no history events",
			"SELECT id FROM captures WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'capture' AND h.entity_id = captures.id)" + scopeSQL, sargs},
		{"work item %s has no history events",
			"SELECT id FROM work_items WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'work_item' AND h.entity_id = work_items.id)" + scopeSQL, sargs},
		{"plan %s has no history events",
			"SELECT id FROM plans WHERE NOT EXISTS (SELECT 1 FROM history_events h WHERE h.entity_type = 'plan' AND h.entity_id = plans.id)" + planSQL, pargs},
	}
	for _, c := range checks {
		ids, err := idRows(ctx, q, c.query, c.args...)
		if err != nil {
			return app.CheckReport{}, err
		}
		for _, id := range ids {
			fail(c.format, id)
		}
	}

	// Plan items must belong to scopes the plan's profile contains.
	memberSQL := " AND p.profile_id = ?"
	if b == nil {
		memberSQL = ""
	}
	var memberArgs []any
	if b != nil {
		memberArgs = pargs
	}
	rows, err := q.QueryContext(ctx,
		`SELECT pi.work_item_id, pi.plan_id FROM plan_items pi
		     JOIN plans p ON p.id = pi.plan_id
		     JOIN work_items w ON w.id = pi.work_item_id
		     WHERE w.scope_id NOT IN (SELECT scope_id FROM profile_scopes WHERE profile_id = p.profile_id)`+
			memberSQL, memberArgs...)
	if err != nil {
		return app.CheckReport{}, err
	}
	for rows.Next() {
		var item, plan string
		if err := rows.Scan(&item, &plan); err != nil {
			rows.Close()
			return app.CheckReport{}, err
		}
		fail("plan %s references work item %s outside the profile scopes", plan, item)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return app.CheckReport{}, err
	}

	// Journey invariants that outlive the Stage 1 tables.
	journeyChecks := []struct {
		format string
		query  string
	}{
		{"actor %s has more than one open focus",
			"SELECT actor_id FROM focus_sessions WHERE ended_at IS NULL GROUP BY actor_id HAVING count(*) > 1"},
		{"focus %s uses a work item outside its profile scopes",
			"SELECT f.id FROM focus_sessions f JOIN work_items w ON w.id = f.work_item_id" +
				" WHERE w.scope_id NOT IN (SELECT scope_id FROM profile_scopes WHERE profile_id = f.profile_id)"},
		{"checkpoint %s has a scope that differs from its work item",
			"SELECT c.id FROM checkpoints c JOIN work_items w ON w.id = c.work_item_id WHERE c.scope_id <> w.scope_id"},
		{"review %s duplicates a profile/kind/period",
			"SELECT profile_id || '/' || kind || '/' || period FROM reviews GROUP BY profile_id, kind, period HAVING count(*) > 1"},
	}
	for _, c := range journeyChecks {
		ids, err := idRows(ctx, q, c.query)
		if err != nil {
			return app.CheckReport{}, err
		}
		for _, id := range ids {
			fail(c.format, id)
		}
	}
	return rep, nil
}
