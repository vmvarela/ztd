package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const checkpointColumns = `id, scope_id, work_item_id, result, evidence_json,
	uncertainties, next_action, revision, created_at`

func scanCheckpoint(sc scanner) (domain.Checkpoint, error) {
	var (
		cp                        domain.Checkpoint
		evidence, uncertain, next sql.NullString
		created                   string
	)
	if err := sc.Scan(&cp.ID, &cp.Scope, &cp.WorkItemID, &cp.Result, &evidence,
		&uncertain, &next, &cp.Revision, &created); err != nil {
		return domain.Checkpoint{}, err
	}
	if evidence.Valid {
		if err := json.Unmarshal([]byte(evidence.String), &cp.EvidenceRefs); err != nil {
			return domain.Checkpoint{}, domain.NewError(domain.IOError, "checkpoint %s has invalid evidence: %v", cp.ID, err)
		}
	}
	cp.Uncertainties = uncertain.String
	cp.NextAction = next.String
	var err error
	if cp.CreatedAt, err = parseTime("checkpoints.created_at", created); err != nil {
		return domain.Checkpoint{}, err
	}
	return cp, nil
}

// GetWorkItemWithCheckpoint returns an authorized work item and its latest checkpoint.
func (s *Store) GetWorkItemWithCheckpoint(ctx context.Context, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, *domain.Checkpoint, error) {
	item, err := s.GetWorkItem(ctx, b, id)
	if err != nil {
		return domain.WorkItem{}, nil, err
	}
	row := s.db.QueryRowContext(ctx,
		"SELECT "+checkpointColumns+" FROM checkpoints WHERE work_item_id = ? AND scope_id = ? ORDER BY revision DESC LIMIT 1",
		string(item.ID), string(item.Scope))
	cp, err := scanCheckpoint(row)
	if errors.Is(err, sql.ErrNoRows) {
		return item, nil, nil
	}
	if err != nil {
		return domain.WorkItem{}, nil, err
	}
	return item, &cp, nil
}

func loadWorkItemTx(ctx context.Context, tx *sql.Tx, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, error) {
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.WorkItem{}, err
	}
	args = append([]any{string(id)}, args...)
	row := tx.QueryRowContext(ctx,
		"SELECT "+workItemColumns+" FROM work_items WHERE id = ? AND scope_id IN ("+clause+")", args...)
	w, err := scanWorkItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.WorkItem{}, rowAccessError(ctx, tx, "work_items", "work item", string(id))
	}
	return w, err
}

func openFocus(ctx context.Context, q queryer, actor domain.ActorID) (domain.FocusID, error) {
	var id string
	err := q.QueryRowContext(ctx,
		"SELECT id FROM focus_sessions WHERE ended_at IS NULL").Scan(&id)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return "", nil
	case err != nil:
		return "", err
	}
	return domain.FocusID(id), nil
}

// StartFocus opens the single open focus for the actor.
//
// Pre:  the binding is valid; the WorkItem belongs to a bound scope and is
// actionable (lifecycle next); the actor has no open FocusSession in any
// Profile; the idempotency key identifies one canonical payload.
// Post: exactly one open FocusSession is committed with its history and
// idempotency record, or no state changes and an existing focus is never
// closed or altered.
func (s *Store) StartFocus(ctx context.Context, cmd app.FocusStartCmd, now time.Time) (domain.FocusSession, []domain.Checkpoint, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.FocusSession{}, nil, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.FocusSession{}, nil, err
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.FocusSession{}, nil, err
	}
	type result struct {
		Focus       domain.FocusSession `json:"focus"`
		Checkpoints []domain.Checkpoint `json:"checkpoints,omitempty"`
	}
	var out result
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "focus_start", cmd.Key, hash, &out)
		if err != nil || done {
			return err
		}
		item, err := loadWorkItemTx(ctx, tx, cmd.Binding, cmd.Item)
		if err != nil {
			return err
		}
		if item.Lifecycle != domain.Next {
			return domain.NewError(domain.InvalidTransition,
				"work item %s is %s, not actionable", item.ID, item.Lifecycle)
		}
		id, err := openFocus(ctx, tx, cmd.Binding.Actor)
		if err != nil {
			return err
		}
		if id != "" {
			return domain.NewError(domain.FocusConflict,
				"a focus session is already open")
		}
		date := idDate(now)
		seq, err := nextDailySeq(ctx, tx, "focus_sessions", "F-"+date+"-")
		if err != nil {
			return err
		}
		out.Focus = domain.FocusSession{
			ID:         domain.FocusID(fmt.Sprintf("F-%s-%03d", date, seq)),
			Profile:    cmd.Binding.Profile,
			Actor:      cmd.Binding.Actor,
			WorkItemID: item.ID,
			StartedAt:  now,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO focus_sessions (id, profile_id, actor_id, work_item_id, started_at, ended_at, outcome, revision)
			 VALUES (?, ?, ?, ?, ?, NULL, NULL, 1)`,
			string(out.Focus.ID), string(out.Focus.Profile), string(out.Focus.Actor),
			string(out.Focus.WorkItemID), fmtTime(now)); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "focus_session", string(out.Focus.ID), "started",
			string(item.Scope), string(cmd.Binding.Profile), 1, out.Focus, now); err != nil {
			return err
		}
		row := tx.QueryRowContext(ctx,
			"SELECT "+checkpointColumns+" FROM checkpoints WHERE work_item_id = ? AND scope_id = ? ORDER BY revision DESC LIMIT 1",
			string(item.ID), string(item.Scope))
		cp, err := scanCheckpoint(row)
		switch {
		case err == nil:
			out.Checkpoints = []domain.Checkpoint{cp}
		case errors.Is(err, sql.ErrNoRows):
		default:
			return err
		}
		return writeIdem(ctx, tx, "focus_start", cmd.Key, hash, out, now)
	})
	if err != nil {
		return domain.FocusSession{}, nil, err
	}
	return out.Focus, out.Checkpoints, nil
}

// Checkpoint records progress inside the actor's open focus without touching
// the WorkItem revision.
func (s *Store) Checkpoint(ctx context.Context, cmd app.CheckpointCmd, now time.Time) (domain.Checkpoint, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Checkpoint{}, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.Checkpoint{}, err
	}
	if strings.TrimSpace(cmd.Result) == "" {
		return domain.Checkpoint{}, domain.Invalid("checkpoint result is required")
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.Checkpoint{}, err
	}
	var cp domain.Checkpoint
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "checkpoint", cmd.Key, hash, &cp)
		if err != nil || done {
			return err
		}
		item, err := loadWorkItemTx(ctx, tx, cmd.Binding, cmd.Item)
		if err != nil {
			return err
		}
		if item.Lifecycle == domain.Archived {
			return domain.NewError(domain.InvalidTransition,
				"work item %s is archived", item.ID)
		}
		var focusID string
		err = tx.QueryRowContext(ctx,
			`SELECT id FROM focus_sessions
			 WHERE actor_id = ? AND work_item_id = ? AND ended_at IS NULL`,
			string(cmd.Binding.Actor), string(item.ID)).Scan(&focusID)
		if errors.Is(err, sql.ErrNoRows) {
			return domain.NewError(domain.FocusConflict,
				"actor %s has no open focus on work item %s", cmd.Binding.Actor, item.ID)
		}
		if err != nil {
			return err
		}
		var maxRev int64
		if err := tx.QueryRowContext(ctx,
			"SELECT COALESCE(MAX(revision), 0) FROM checkpoints WHERE work_item_id = ?",
			string(item.ID)).Scan(&maxRev); err != nil {
			return err
		}
		evidence, err := json.Marshal(cmd.Evidence)
		if err != nil {
			return domain.Invalid("evidence is not serializable: %v", err)
		}
		date := idDate(now)
		seq, err := nextDailySeq(ctx, tx, "checkpoints", "CP-"+date+"-")
		if err != nil {
			return err
		}
		cp = domain.Checkpoint{
			ID:            fmt.Sprintf("CP-%s-%03d", date, seq),
			Scope:         item.Scope,
			WorkItemID:    item.ID,
			Result:        cmd.Result,
			EvidenceRefs:  cmd.Evidence,
			Uncertainties: cmd.Uncertain,
			NextAction:    cmd.NextAction,
			CreatedAt:     now,
			Revision:      domain.Revision(maxRev + 1),
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO checkpoints (id, scope_id, work_item_id, focus_id, result,
				evidence_json, uncertainties, next_action, revision, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			cp.ID, string(cp.Scope), string(cp.WorkItemID), focusID, cp.Result,
			string(evidence), nullIfEmpty(cp.Uncertainties), nullIfEmpty(cp.NextAction),
			int64(cp.Revision), fmtTime(now)); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "checkpoint", cp.ID, "recorded",
			string(cp.Scope), string(cmd.Binding.Profile), cp.Revision, cp, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "checkpoint", cmd.Key, hash, cp, now)
	})
	if err != nil {
		return domain.Checkpoint{}, err
	}
	return cp, nil
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *Store) FinishFocus(ctx context.Context, cmd app.FocusFinishCmd, now time.Time) (domain.FocusSession, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.FocusSession{}, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.FocusSession{}, err
	}
	if cmd.Focus == "" {
		return domain.FocusSession{}, domain.Invalid("focus id is required")
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.FocusSession{}, err
	}
	var out domain.FocusSession
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "focus_finish", cmd.Key, hash, &out)
		if err != nil || done {
			return err
		}
		var (
			started                        string
			ended, outcome                 sql.NullString
			rev                            int64
			profileID, actorID, workItemID string
		)
		err = tx.QueryRowContext(ctx,
			`SELECT profile_id, actor_id, work_item_id, started_at, ended_at, outcome, revision
			 FROM focus_sessions WHERE id = ?`, string(cmd.Focus)).
			Scan(&profileID, &actorID, &workItemID, &started, &ended, &outcome, &rev)
		if errors.Is(err, sql.ErrNoRows) {
			return domain.NewError(domain.NotFound, "focus %s does not exist", cmd.Focus)
		}
		if err != nil {
			return err
		}
		if domain.ActorID(actorID) != cmd.Binding.Actor {
			return domain.NewError(domain.ScopeDenied, "focus %s belongs to another actor", cmd.Focus)
		}
		item, err := loadWorkItemTx(ctx, tx, cmd.Binding, domain.WorkItemID(workItemID))
		if err != nil {
			return err
		}
		if ended.Valid {
			return domain.NewError(domain.InvalidTransition, "focus %s is already finished", cmd.Focus)
		}
		if _, err := tx.ExecContext(ctx,
			"UPDATE focus_sessions SET ended_at = ?, outcome = ?, revision = ? WHERE id = ?",
			fmtTime(now), nullIfEmpty(cmd.Outcome), rev+1, string(cmd.Focus)); err != nil {
			return err
		}
		out = domain.FocusSession{
			ID:         cmd.Focus,
			Profile:    domain.ProfileID(profileID),
			Actor:      domain.ActorID(actorID),
			WorkItemID: item.ID,
			StartedAt:  mustParse(started),
			EndedAt:    &now,
			Outcome:    cmd.Outcome,
		}
		if err := insertHistory(ctx, tx, "focus_session", string(out.ID), "finished",
			string(item.Scope), string(out.Profile), domain.Revision(rev+1), out, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "focus_finish", cmd.Key, hash, out, now)
	})
	if err != nil {
		return domain.FocusSession{}, err
	}
	return out, nil
}

func mustParse(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}
