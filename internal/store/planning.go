package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const planColumns = `id, profile_id, kind, period, status, revision, created_at, updated_at, exception_reason`

func scanPlan(sc scanner) (domain.Plan, error) {
	var (
		p                domain.Plan
		created, updated string
	)
	if err := sc.Scan(&p.ID, &p.Profile, &p.Kind, &p.Period, &p.Status, &p.Revision, &created, &updated, &p.ExceptionReason); err != nil {
		return domain.Plan{}, err
	}
	var err error
	if p.CreatedAt, err = parseTime("plans.created_at", created); err != nil {
		return domain.Plan{}, err
	}
	if p.UpdatedAt, err = parseTime("plans.updated_at", updated); err != nil {
		return domain.Plan{}, err
	}
	return p, nil
}

// loadPlan fetches the plan for (profile, kind, period); found is false when
// no plan exists.
func loadPlan(ctx context.Context, q queryer, profile domain.ProfileID, kind domain.PlanKind, period string) (domain.Plan, bool, error) {
	row := q.QueryRowContext(ctx,
		"SELECT "+planColumns+" FROM plans WHERE profile_id = ? AND kind = ? AND period = ?",
		string(profile), string(kind), period)
	plan, err := scanPlan(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Plan{}, false, nil
	}
	if err != nil {
		return domain.Plan{}, false, err
	}
	return plan, true, nil
}

// profileScopes returns the scopes the profile explicitly contains.
func profileScopes(ctx context.Context, q queryer, profile domain.ProfileID) (map[domain.ScopeID]bool, error) {
	rows, err := q.QueryContext(ctx, "SELECT scope_id FROM profile_scopes WHERE profile_id = ?", string(profile))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[domain.ScopeID]bool{}
	for rows.Next() {
		var sc domain.ScopeID
		if err := rows.Scan(&sc); err != nil {
			return nil, err
		}
		out[sc] = true
	}
	return out, rows.Err()
}

// Prepare returns the committed/open daily plan for (profile, date) plus the
// MITs it links and up to 10 next and 10 waiting work items visible in the
// binding scopes. It reads existing rows only and invents nothing; a profile
// that does not exist is not_found. It also returns the registered sources so
// the caller can see their coverage state. NeedsHuman stays empty until the
// cross-calendar assertion flow lands.
func (s *Store) Prepare(ctx context.Context, b domain.ScopeBinding, date string) (app.PlanBrief, error) {
	if err := b.Validate(); err != nil {
		return app.PlanBrief{}, err
	}
	if _, err := time.Parse("2006-01-02", date); err != nil {
		return app.PlanBrief{}, domain.Invalid("date must be YYYY-MM-DD")
	}
	var one int
	err := s.db.QueryRowContext(ctx, "SELECT 1 FROM profiles WHERE id = ?", string(b.Profile)).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return app.PlanBrief{}, domain.NewError(domain.NotFound, "profile %s not found", b.Profile)
	case err != nil:
		return app.PlanBrief{}, err
	}
	clause, scopeArgs, err := scopeClause(b)
	if err != nil {
		return app.PlanBrief{}, err
	}
	brief := app.PlanBrief{Profile: b.Profile, Date: date}
	if goal, err := activeGoal(ctx, s.db, b); err != nil {
		return app.PlanBrief{}, err
	} else {
		brief.Goal = goal
	}
	sources, err := s.ListSources(ctx, b)
	if err != nil {
		return app.PlanBrief{}, err
	}
	brief.Sources = sources

	plan, found, err := loadPlan(ctx, s.db, b.Profile, domain.DailyPlan, date)
	if err != nil {
		return app.PlanBrief{}, err
	}
	if found {
		rows, err := s.db.QueryContext(ctx,
			`SELECT work_item_id, role, position FROM plan_items WHERE plan_id = ? ORDER BY position`, plan.ID)
		if err != nil {
			return app.PlanBrief{}, err
		}
		var mitIDs []domain.WorkItemID
		for rows.Next() {
			var it domain.PlanItem
			if err := rows.Scan(&it.WorkItemID, &it.Role, &it.Position); err != nil {
				rows.Close()
				return app.PlanBrief{}, err
			}
			plan.Items = append(plan.Items, it)
			if it.Role == domain.MITRole {
				mitIDs = append(mitIDs, it.WorkItemID)
			}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return app.PlanBrief{}, err
		}
		rows.Close()
		// Bounded: a daily plan holds at most three MITs without an override,
		// so this loop performs at most three row reads.
		for _, id := range mitIDs {
			args := append([]any{string(id)}, scopeArgs...)
			row := s.db.QueryRowContext(ctx,
				"SELECT "+workItemColumns+" FROM work_items WHERE id = ? AND scope_id IN ("+clause+")", args...)
			w, err := scanWorkItem(row)
			if errors.Is(err, sql.ErrNoRows) {
				continue // outside the binding scopes: not visible here
			}
			if err != nil {
				return app.PlanBrief{}, err
			}
			brief.MITs = append(brief.MITs, w)
		}
		visible, err := readPlanItems(ctx, s.db, b, plan.ID)
		if err != nil {
			return app.PlanBrief{}, err
		}
		if len(visible) != len(plan.Items) {
			plan.ExceptionReason = ""
		}
		plan.Items = visible
		brief.Plan = &plan
		for _, item := range brief.MITs {
			args := append([]any{string(item.ID)}, scopeArgs...)
			row := s.db.QueryRowContext(ctx,
				"SELECT "+checkpointColumns+" FROM checkpoints WHERE work_item_id = ? AND scope_id IN ("+clause+") ORDER BY revision DESC LIMIT 1", args...)
			cp, err := scanCheckpoint(row)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			if err != nil {
				return app.PlanBrief{}, err
			}
			brief.Checkpoints = append(brief.Checkpoints, cp)
		}
	}

	for _, lc := range []domain.Lifecycle{domain.Next, domain.Waiting} {
		args := append([]any{string(lc)}, scopeArgs...)
		q := "SELECT " + workItemColumns + " FROM work_items WHERE lifecycle = ? AND scope_id IN (" + clause + ")" +
			" ORDER BY updated_at DESC, id ASC LIMIT 10"
		rows, err := s.db.QueryContext(ctx, q, args...)
		if err != nil {
			return app.PlanBrief{}, err
		}
		items, err := collectWorkItems(rows)
		if err != nil {
			return app.PlanBrief{}, err
		}
		if lc == domain.Next {
			brief.Next = items
		} else {
			brief.Waiting = items
		}
	}
	return brief, nil
}

// CommitPlan creates or replaces one committed plan.
//
// Pre: binding scopes belong to the profile; key and period are set; every item
// exists once in a profile scope with a role valid for the kind; a daily plan has
// 1..3 MITs or a matching daily_limit_overrides row; Expected is 0 for create or
// the current plan revision.
// Post: one transaction upserts the plan (revision 1 or +1), replaces plan_items
// in order, and writes history plus the idempotency record. A validation failure
// leaves the original plan unchanged; an identical retry replays it.
func (s *Store) CommitPlan(ctx context.Context, cmd app.CommitPlanCmd, now time.Time) (domain.Plan, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Plan{}, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.Plan{}, err
	}
	if cmd.Kind != domain.DailyPlan && cmd.Kind != domain.WeeklyPlan {
		return domain.Plan{}, domain.Invalid("plan kind must be daily or weekly")
	}
	if strings.TrimSpace(cmd.Period) == "" {
		return domain.Plan{}, domain.Invalid("plan period is required")
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.Plan{}, err
	}
	var plan domain.Plan
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "commit_plan", cmd.Key, hash, &plan)
		if err != nil || done {
			return err
		}
		var one int
		switch err := tx.QueryRowContext(ctx, "SELECT 1 FROM profiles WHERE id = ?", string(cmd.Binding.Profile)).Scan(&one); {
		case errors.Is(err, sql.ErrNoRows):
			return domain.NewError(domain.NotFound, "profile %s not found", cmd.Binding.Profile)
		case err != nil:
			return err
		}
		owned, err := profileScopes(ctx, tx, cmd.Binding.Profile)
		if err != nil {
			return err
		}
		for _, sc := range cmd.Binding.Scopes {
			if !owned[sc] {
				return domain.NewError(domain.ScopeDenied,
					"scope %s is not part of profile %s", sc, cmd.Binding.Profile)
			}
		}

		existing, found, err := loadPlan(ctx, tx, cmd.Binding.Profile, cmd.Kind, cmd.Period)
		if err != nil {
			return err
		}
		var planID string
		var nextRev domain.Revision
		switch {
		case found && cmd.Expected != existing.Revision:
			return domain.NewError(domain.StaleRevision,
				"plan %s is at revision %d, expected %d", existing.ID, existing.Revision, cmd.Expected)
		case !found && cmd.Expected != 0:
			return domain.NewError(domain.StaleRevision,
				"no plan exists for profile %s %s %s, so expected must be 0",
				cmd.Binding.Profile, cmd.Kind, cmd.Period)
		case found:
			planID = string(existing.ID)
			nextRev = existing.Revision.Next()
		default:
			planID = fmt.Sprintf("P-%s-%s-%s", cmd.Binding.Profile, cmd.Kind, cmd.Period)
			nextRev = 1
		}

		var hidden []domain.PlanItem
		if found {
			clause, args, _ := scopeClause(cmd.Binding)
			args = append([]any{planID}, args...)
			rows, err := tx.QueryContext(ctx, "SELECT pi.work_item_id, pi.role, pi.position FROM plan_items pi JOIN work_items w ON w.id = pi.work_item_id WHERE pi.plan_id = ? AND w.scope_id NOT IN ("+clause+") ORDER BY pi.position", args...)
			if err != nil {
				return err
			}
			for rows.Next() {
				var it domain.PlanItem
				if err := rows.Scan(&it.WorkItemID, &it.Role, &it.Position); err != nil {
					rows.Close()
					return err
				}
				hidden = append(hidden, it)
			}
			err = rows.Err()
			rows.Close()
			if err != nil {
				return err
			}
		}
		if len(hidden) > 0 {
			if cmd.ExceptionReason != "" {
				return domain.NewError(domain.ScopeDenied, "editing the global exception requires a full plan view")
			}
			cmd.ExceptionReason = existing.ExceptionReason
		}
		seen := make(map[domain.WorkItemID]bool, len(cmd.Items))
		mitCount := 0
		for _, item := range cmd.Items {
			if seen[item.WorkItemID] {
				return domain.Invalid("duplicate plan item %s", item.WorkItemID)
			}
			seen[item.WorkItemID] = true
			switch item.Role {
			case domain.MITRole, domain.BigRockRole, domain.BatchRole:
			default:
				return domain.Invalid("invalid plan role %q", item.Role)
			}
			if cmd.Kind == domain.WeeklyPlan && item.Role == domain.MITRole {
				return domain.Invalid("weekly plans accept big_rock and batch roles, not mit")
			}
			var owner string
			err := tx.QueryRowContext(ctx, "SELECT scope_id FROM work_items WHERE id = ?",
				string(item.WorkItemID)).Scan(&owner)
			switch {
			case errors.Is(err, sql.ErrNoRows):
				return domain.NewError(domain.NotFound, "work item %s not found", item.WorkItemID)
			case err != nil:
				return err
			}
			if !cmd.Binding.Allows(domain.ScopeID(owner)) {
				return domain.NewError(domain.ScopeDenied, "plan item is outside the active scopes")
			}
			if !owned[domain.ScopeID(owner)] {
				return domain.NewError(domain.ScopeDenied,
					"work item %s belongs to scope %s, which is not part of profile %s",
					item.WorkItemID, owner, cmd.Binding.Profile)
			}
			if item.Role == domain.MITRole {
				mitCount++
			}
		}
		for _, item := range hidden {
			if item.Role == domain.MITRole {
				mitCount++
			}
		}
		if cmd.Kind == domain.DailyPlan && (mitCount > 3 || cmd.OverrideID != "") && strings.TrimSpace(cmd.ExceptionReason) == "" {
			applies, err := overrideApplies(ctx, tx, cmd.Binding.Actor, cmd.Period, cmd.OverrideID)
			if err != nil {
				return err
			}
			if !applies {
				if cmd.OverrideID != "" {
					return domain.Invalid("daily limit override %q does not apply to %s for actor %s",
						cmd.OverrideID, cmd.Period, cmd.Binding.Actor)
				}
				return domain.NewError(domain.RulesAcknowledgement,
					"daily priority limit exceeded; supply an exception reason from a full plan view")
			}
		}

		if found {
			if _, err := tx.ExecContext(ctx,
				`UPDATE plans SET status = 'committed', revision = ?, updated_at = ? WHERE id = ?`,
				nextRev, fmtTime(now), planID); err != nil {
				return err
			}
		} else if _, err := tx.ExecContext(ctx,
			`INSERT INTO plans (id, profile_id, kind, period, status, revision, created_at, updated_at)
			     VALUES (?, ?, ?, ?, 'committed', ?, ?, ?)`,
			planID, string(cmd.Binding.Profile), string(cmd.Kind), cmd.Period,
			nextRev, fmtTime(now), fmtTime(now)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE plans SET exception_reason = ? WHERE id = ?", cmd.ExceptionReason, planID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM plan_items WHERE plan_id = ?", planID); err != nil {
			return err
		}
		plan = domain.Plan{
			ID:        domain.PlanID(planID),
			Profile:   cmd.Binding.Profile,
			Kind:      cmd.Kind,
			Period:    cmd.Period,
			Status:    domain.CommittedPlan,
			Revision:  nextRev,
			CreatedAt: now,
			UpdatedAt: now,
		}
		if found {
			plan.CreatedAt = existing.CreatedAt
		}
		plan.Items = make([]domain.PlanItem, 0, len(cmd.Items))
		for i, item := range cmd.Items {
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO plan_items (plan_id, work_item_id, role, position) VALUES (?, ?, ?, ?)`,
				planID, string(item.WorkItemID), string(item.Role), i); err != nil {
				return err
			}
			plan.Items = append(plan.Items, domain.PlanItem{
				WorkItemID: item.WorkItemID,
				Role:       item.Role,
				Position:   i,
			})
		}
		for i, item := range hidden {
			if _, err := tx.ExecContext(ctx, "INSERT INTO plan_items (plan_id, work_item_id, role, position) VALUES (?, ?, ?, ?)", planID, item.WorkItemID, item.Role, len(cmd.Items)+i); err != nil {
				return err
			}
		}
		plan.ExceptionReason = cmd.ExceptionReason
		if len(hidden) > 0 {
			plan.ExceptionReason = ""
		}
		if err := insertHistory(ctx, tx, "plan", planID, "committed", "",
			string(cmd.Binding.Profile), plan.Revision, plan, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "commit_plan", cmd.Key, hash, plan, now)
	})
	if err != nil {
		return domain.Plan{}, err
	}
	return plan, nil
}

// overrideApplies reports whether a daily_limit_overrides(mit) row matches the
// actor and local date, narrowed to OverrideID when one was supplied.
func overrideApplies(ctx context.Context, tx *sql.Tx, actor domain.ActorID, localDate, overrideID string) (bool, error) {
	query := `SELECT 1 FROM legacy_records WHERE entity_type='limit_override' AND json_extract(payload_json,'$.rule') = 'mit' AND json_extract(payload_json,'$.actor_id') = ? AND json_extract(payload_json,'$.local_date') = ?`
	args := []any{string(actor), localDate}
	if overrideID != "" {
		query += " AND entity_id = ?"
		args = append(args, overrideID)
	}
	var one int
	err := tx.QueryRowContext(ctx, query, args...).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, err
	}
	return true, nil
}

// readPlanItems only returns task references inside the session binding.
func readPlanItems(ctx context.Context, q queryer, b domain.ScopeBinding, id domain.PlanID) ([]domain.PlanItem, error) {
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	args = append([]any{string(id)}, args...)
	rows, err := q.QueryContext(ctx, "SELECT pi.work_item_id, pi.role, pi.position FROM plan_items pi JOIN work_items w ON w.id = pi.work_item_id WHERE pi.plan_id = ? AND w.scope_id IN ("+clause+") ORDER BY pi.position", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.PlanItem{}
	for rows.Next() {
		var it domain.PlanItem
		if err := rows.Scan(&it.WorkItemID, &it.Role, &it.Position); err != nil {
			return nil, err
		}
		it.Position = len(out)
		out = append(out, it)
	}
	return out, rows.Err()
}
func (s *Store) ReadPlan(ctx context.Context, b domain.ScopeBinding, kind domain.PlanKind, period string) (domain.Plan, error) {
	if err := b.Validate(); err != nil {
		return domain.Plan{}, err
	}
	p, found, err := loadPlan(ctx, s.db, b.Profile, kind, period)
	if err != nil {
		return p, err
	}
	if !found {
		return p, domain.NewError(domain.NotFound, "plan not found")
	}
	p.Items, err = readPlanItems(ctx, s.db, b, p.ID)
	if err != nil {
		return p, err
	}
	var total int
	if err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM plan_items WHERE plan_id=?", p.ID).Scan(&total); err != nil {
		return p, err
	}
	if total != len(p.Items) {
		p.ExceptionReason = ""
	}
	return p, nil
}
