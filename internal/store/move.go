package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// loadMoveItem fetches one work item restricted to the binding scopes. A row
// outside the scopes is reported as not_found: a move never discloses that an
// item exists somewhere the binding cannot reach.
func loadMoveItem(ctx context.Context, tx *sql.Tx, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, error) {
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.WorkItem{}, err
	}
	args = append([]any{string(id)}, args...)
	row := tx.QueryRowContext(ctx,
		"SELECT "+workItemColumns+" FROM work_items WHERE id = ? AND scope_id IN ("+clause+")", args...)
	w, err := scanWorkItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.WorkItem{}, domain.NewError(domain.NotFound, "work item %s not found", id)
	}
	if err != nil {
		return domain.WorkItem{}, err
	}
	return w, nil
}

// MoveWorkItem applies one lifecycle transition to one work item.
//
// Pre: the binding validates; the idempotency key is set; the target is next,
// waiting, someday or archived; Text, when provided, is nonblank; waiting
// carries waiting_on; archived carries a resolution; ClosureKind is empty or a
// known kind; every custom field key is nonblank and not reserved; Expected is
// 0 or equals the item revision. The store mirrors app.ValidateMoveCmd.
// Post: one transaction loads the item inside the binding, applies the target
// state (waiting sets waiting_on; next and someday clear it; archived stamps
// closed_at and the closure kind; non-archived targets clear closure state),
// merges the custom fields, bumps the revision and updated_at, and writes one
// "moved" history event plus the idempotency record. An identical replay
// returns the stored result, a different payload under the same key is
// idempotency_conflict, an item in another scope is not_found, a wrong
// Expected is stale_revision. Any error leaves no writes.
func (s *Store) MoveWorkItem(ctx context.Context, cmd app.MoveWorkItemCmd, now time.Time) (domain.WorkItem, error) {
	now = now.UTC().Truncate(time.Second)
	if err := app.ValidateMoveCmd(cmd); err != nil {
		return domain.WorkItem{}, err
	}
	var out domain.WorkItem
	err := s.withTx(ctx, func(tx *sql.Tx) error { var err error; out, err = moveWorkItemTx(ctx, tx, cmd, now); return err })
	return out, err
}
func moveWorkItemTx(ctx context.Context, tx *sql.Tx, cmd app.MoveWorkItemCmd, now time.Time) (domain.WorkItem, error) {
	if err := app.ValidateMoveCmd(cmd); err != nil {
		return domain.WorkItem{}, err
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.WorkItem{}, err
	}
	var out domain.WorkItem
	err = func() error {
		done, err := lookupIdem(ctx, tx, "move", cmd.Key, hash, &out)
		if err != nil || done {
			return err
		}
		item, err := loadMoveItem(ctx, tx, cmd.Binding, cmd.ID)
		if err != nil {
			return err
		}
		if cmd.Expected != 0 && cmd.Expected != item.Revision {
			return domain.NewError(domain.StaleRevision,
				"work item %s is at revision %d, expected %d", item.ID, item.Revision, cmd.Expected)
		}
		if cmd.ProjectID != nil {
			item.ProjectID = nil
			if *cmd.ProjectID != "" {
				if err := checkSameScope(ctx, tx, "projects", "project", string(*cmd.ProjectID), item.Scope); err != nil {
					return err
				}
				item.ProjectID = cmd.ProjectID
			}
		}
		if cmd.ContextID != nil {
			item.ContextID = nil
			if *cmd.ContextID != "" {
				if err := checkSameScope(ctx, tx, "contexts", "context", string(*cmd.ContextID), item.Scope); err != nil {
					return err
				}
				item.ContextID = cmd.ContextID
			}
		}
		if cmd.DueAt != nil {
			item.DueAt = nil
			if *cmd.DueAt != "" {
				t, err := time.Parse(time.RFC3339, *cmd.DueAt)
				if err != nil {
					return domain.Invalid("due_at must be RFC3339 or empty to clear")
				}
				item.DueAt = &t
			}
		}
		if cmd.Text != nil {
			item.Title = *cmd.Text
		}
		if len(cmd.Fields) > 0 {
			if item.CustomFields == nil {
				item.CustomFields = map[string]string{}
			}
			for k, v := range cmd.Fields {
				item.CustomFields[k] = v
			}
		}
		// Closure state belongs to the archived lifecycle only; waiting_on
		// belongs to waiting only, so every move starts from a clean slate.
		previousClosure, previousClosedAt := item.ClosureKind, item.ClosedAt
		item.WaitingOn, item.ClosureKind, item.ClosedAt, item.Resolution = "", "", nil, ""
		var waiting, closed, resolution any
		switch cmd.Target {
		case domain.Waiting:
			item.WaitingOn = *cmd.WaitingOn
			waiting = item.WaitingOn
		case domain.Next, domain.Someday:
		case domain.Archived:
			kind := cmd.ClosureKind
			if kind == "" {
				kind = domain.Completed
			}
			item.ClosureKind = kind
			item.Resolution = *cmd.Resolution
			item.ClosedAt = &now
			if previousClosure == kind && previousClosedAt != nil {
				item.ClosedAt = previousClosedAt
			}
			closed, resolution = fmtTime(*item.ClosedAt), item.Resolution
		}
		item.Lifecycle = cmd.Target
		item.Revision = item.Revision.Next()
		item.UpdatedAt = now

		fields, err := json.Marshal(orEmptyFields(item.CustomFields))
		if err != nil {
			return domain.Invalid("custom fields for work item %s are not serializable: %v", item.ID, err)
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE work_items SET title = ?, status = ?, waiting_on = ?,
			   closed_at = ?, resolution = ?, custom_fields = ?, revision = ?, updated_at = ?, project_id = ?, context_id = ?, due_at = ?
			     WHERE id = ? AND scope_id = ? AND revision = ?`,
			item.Title, item.Task().Status, waiting, closed, resolution,
			string(fields), int64(item.Revision), fmtTime(item.UpdatedAt), argID(item.ProjectID), argID(item.ContextID), argTime(item.DueAt),
			string(item.ID), string(item.Scope), int64(item.Revision-1))
		if err != nil {
			return err
		}
		if n, affErr := res.RowsAffected(); affErr == nil && n != 1 {
			return domain.NewError(domain.StaleRevision, "work item %s changed concurrently", item.ID)
		}
		payload := map[string]any{"target": string(cmd.Target), "fields": moveChangedFields(cmd)}
		if err := insertHistory(ctx, tx, "work_item", string(item.ID), "moved",
			string(item.Scope), "", item.Revision, payload, now); err != nil {
			return err
		}
		out = item
		return writeIdem(ctx, tx, "move", cmd.Key, hash, out, now)
	}()
	if err != nil {
		return domain.WorkItem{}, err
	}
	return out, nil
}

// orEmptyFields keeps the stored JSON a JSON object even when nothing was set.
func orEmptyFields(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

// moveChangedFields records what the transition actually wrote, so the history
// event reads as the change that happened: only the fields the target sets,
// plus the text and the merged custom fields.
func moveChangedFields(cmd app.MoveWorkItemCmd) map[string]any {
	changed := map[string]any{}
	if cmd.Text != nil {
		changed["title"] = *cmd.Text
	}
	switch cmd.Target {
	case domain.Waiting:
		if cmd.WaitingOn != nil {
			changed["waiting_on"] = *cmd.WaitingOn
		}
	case domain.Archived:
		kind := cmd.ClosureKind
		if kind == "" {
			kind = domain.Completed
		}
		changed["closure_kind"] = string(kind)
		if cmd.Resolution != nil {
			changed["resolution"] = *cmd.Resolution
		}
	}
	if len(cmd.Fields) > 0 {
		changed["custom_fields"] = cmd.Fields
	}
	return changed
}

// Task patches use their original payload for retries, not a payload re-derived
// from the task's newer state. The entire read/modify/write is one transaction.
func (s *Store) UpdateTask(ctx context.Context, b domain.ScopeBinding, in app.TaskUpdate, now time.Time) (domain.Task, error) {
	if err := b.Validate(); err != nil {
		return domain.Task{}, err
	}
	if in.Expected <= 0 {
		return domain.Task{}, domain.Invalid("expected_revision must be positive")
	}
	if err := requireKey(in.Key); err != nil {
		return domain.Task{}, err
	}
	hash, err := hashPayload(struct {
		Binding domain.ScopeBinding
		Patch   app.TaskUpdate
	}{b, in})
	if err != nil {
		return domain.Task{}, err
	}
	var out domain.Task
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "task update", in.Key, hash, &out)
		if done || err != nil {
			return err
		}
		w, err := loadMoveItem(ctx, tx, b, in.ID)
		if err != nil {
			return err
		}
		cmd := app.MoveWorkItemCmd{Binding: b, Key: "task:" + in.Key, ID: in.ID, Expected: in.Expected, Target: w.Lifecycle, ClosureKind: w.ClosureKind, Text: in.Title, WaitingOn: &w.WaitingOn, Resolution: &w.Resolution, ProjectID: in.ProjectID, ContextID: in.ContextID, DueAt: in.DueAt}
		switch in.Status {
		case "":
		case "next", "waiting", "someday":
			cmd.Target = domain.Lifecycle(in.Status)
		case "completed", "cancelled":
			cmd.Target = domain.Archived
			cmd.ClosureKind = domain.ClosureKind(in.Status)
		default:
			return domain.Invalid("unknown task status")
		}
		if in.WaitingOn != nil {
			cmd.WaitingOn = in.WaitingOn
		}
		if in.Resolution != nil {
			cmd.Resolution = in.Resolution
		}
		updated, err := moveWorkItemTx(ctx, tx, cmd, now)
		if err != nil {
			return err
		}
		out = updated.Task()
		return writeIdem(ctx, tx, "task update", in.Key, hash, out, now)
	})
	return out, err
}
