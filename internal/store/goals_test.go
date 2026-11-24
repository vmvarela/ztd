package store

import (
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func (e *testEnv) setGoal(key, kind, statement string) (domain.Goal, error) {
	return e.s.SetGoal(e.ctx(), app.GoalCmd{
		Binding: e.binding, Key: key, Kind: kind,
		StartOn: "2026-11-19", Statement: statement,
	}, e.now)
}

func TestGoalIsReturnedByPrepare(t *testing.T) {
	e := newTestEnv(t)
	g, err := e.setGoal("g1", "primary", "ship ZTD")
	if err != nil {
		t.Fatalf("SetGoal: %v", err)
	}
	if g.ID != "G-20261119-001" {
		t.Fatalf("goal id = %s", g.ID)
	}
	brief, err := e.s.Prepare(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	if brief.Goal == nil || brief.Goal.ID != g.ID {
		t.Fatalf("prepare goal = %+v, want %s", brief.Goal, g.ID)
	}
}

func TestOneActivePrimaryGoalPerProfile(t *testing.T) {
	e := newTestEnv(t)
	if _, err := e.setGoal("g1", "primary", "first"); err != nil {
		t.Fatalf("first goal: %v", err)
	}
	if _, err := e.setGoal("g2", "primary", "second"); !domain.Of(err, domain.Conflict) {
		t.Fatalf("second primary error = %v, want conflict", err)
	}
	if _, err := e.setGoal("g3", "subgoal", "supporting"); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("subgoal: %v", err)
	}
}

func TestGoalReplayIsIdempotent(t *testing.T) {
	e := newTestEnv(t)
	first, err := e.setGoal("g1", "primary", "ship ZTD")
	if err != nil {
		t.Fatalf("SetGoal: %v", err)
	}
	second, err := e.setGoal("g1", "primary", "ship ZTD")
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if first.ID != second.ID {
		t.Fatalf("replay id = %s, want %s", second.ID, first.ID)
	}
	if _, err := e.setGoal("g1", "primary", "different"); !domain.Of(err, domain.IdempotencyConflict) {
		t.Fatalf("changed payload error = %v, want idempotency_conflict", err)
	}
}

func TestGoalCompleteCancel(t *testing.T) {
	e := newTestEnv(t)

	// Nothing to close yet.
	if _, err := e.s.SetGoalStatus(e.ctx(), e.binding, "completed", e.now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("complete without a goal: %v, want not_found", err)
	}

	g, err := e.setGoal("g1", "primary", "ship ZTD")
	if err != nil {
		t.Fatalf("SetGoal: %v", err)
	}
	later := e.now.Add(time.Hour)
	done, err := e.s.SetGoalStatus(e.ctx(), e.binding, "completed", later)
	if err != nil {
		t.Fatalf("complete: %v", err)
	}
	if done.ID != g.ID || done.Status != "completed" {
		t.Fatalf("complete = %+v, want %s completed", done, g.ID)
	}
	if active, err := e.s.ActiveGoal(e.ctx(), e.binding); err != nil || active != nil {
		t.Fatalf("active goal after complete = %+v (%v), want nil", active, err)
	}
	var updatedAt string
	if err := e.s.db.QueryRowContext(e.ctx(), "SELECT updated_at FROM goals WHERE id = ?", g.ID).Scan(&updatedAt); err != nil {
		t.Fatalf("read updated_at: %v", err)
	}
	if updatedAt != fmtTime(later) {
		t.Fatalf("updated_at = %s, want %s", updatedAt, fmtTime(later))
	}
	if n := e.count(`SELECT count(*) FROM history_events
		WHERE entity_type = 'goal' AND entity_id = ? AND event = 'completed' AND revision = 2`, g.ID); n != 1 {
		t.Fatalf("completed history events = %d, want 1 at revision 2", n)
	}

	// Completing again returns the same closed goal without a second event.
	again, err := e.s.SetGoalStatus(e.ctx(), e.binding, "completed", later)
	if err != nil {
		t.Fatalf("complete again: %v", err)
	}
	if again.ID != g.ID || again.Status != "completed" {
		t.Fatalf("second complete = %+v, want the same closed goal", again)
	}
	if n := e.count(`SELECT count(*) FROM history_events
		WHERE entity_type = 'goal' AND entity_id = ? AND event = 'completed'`, g.ID); n != 1 {
		t.Fatalf("completed history events after replay = %d, want 1", n)
	}

	// The other terminal status is refused, not silently applied.
	if _, err := e.s.SetGoalStatus(e.ctx(), e.binding, "cancelled", later); !domain.Of(err, domain.InvalidTransition) {
		t.Fatalf("cancel after complete: %v, want invalid_transition", err)
	}

	// A fresh primary can be cancelled the same way.
	g2, err := e.setGoal("g2", "primary", "second")
	if err != nil {
		t.Fatalf("second SetGoal: %v", err)
	}
	cancelled, err := e.s.SetGoalStatus(e.ctx(), e.binding, "cancelled", later)
	if err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if cancelled.ID != g2.ID || cancelled.Status != "cancelled" {
		t.Fatalf("cancel = %+v, want %s cancelled", cancelled, g2.ID)
	}
	if active, err := e.s.ActiveGoal(e.ctx(), e.binding); err != nil || active != nil {
		t.Fatalf("active goal after cancel = %+v (%v), want nil", active, err)
	}
	if n := e.count(`SELECT count(*) FROM history_events
		WHERE entity_type = 'goal' AND entity_id = ? AND event = 'cancelled' AND revision = 2`, g2.ID); n != 1 {
		t.Fatalf("cancelled history events = %d, want 1 at revision 2", n)
	}

	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("check after closes: ok=%v errors=%v err=%v", rep.OK, rep.Errors, err)
	}
}
