package store

import (
	"testing"

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
	if _, err := e.setGoal("g3", "subgoal", "supporting"); err != nil {
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
