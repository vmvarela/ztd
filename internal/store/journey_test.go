package store

import (
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func TestFocusLifecycleDoesNotBumpWorkItemRevision(t *testing.T) {
	e := newTestEnv(t)
	items := e.workItems(2, "focus")
	item := items[0]

	before, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	focus, _, err := e.s.StartFocus(e.ctx(), app.FocusStartCmd{
		Binding: e.binding, Key: "focus-1", Item: item.ID,
	}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.s.Checkpoint(e.ctx(), app.CheckpointCmd{
		Binding: e.binding, Key: "cp-1", Item: item.ID, Result: "half way",
	}, e.now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	after, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.Revision != before.Revision {
		t.Fatalf("checkpoint bumped work item revision %d -> %d", before.Revision, after.Revision)
	}

	if _, _, err := e.s.StartFocus(e.ctx(), app.FocusStartCmd{
		Binding: e.binding, Key: "focus-2", Item: items[1].ID,
	}, e.now); !domain.Of(err, domain.FocusConflict) {
		t.Fatalf("second focus: expected focus_conflict, got %v", err)
	}

	if _, err := e.s.FinishFocus(e.ctx(), app.FocusFinishCmd{
		Binding: e.binding, Key: "finish-1", Focus: focus.ID, Outcome: "partially done",
	}, e.now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.s.StartFocus(e.ctx(), app.FocusStartCmd{
		Binding: e.binding, Key: "focus-3", Item: items[1].ID,
	}, e.now.Add(3*time.Minute)); err != nil {
		t.Fatalf("focus after finish: %v", err)
	}
}

func TestGetWorkItemWithCheckpoint(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "checkpoint-read")[0]

	got, checkpoint, err := e.s.GetWorkItemWithCheckpoint(e.ctx(), e.binding, item.ID)
	if err != nil || got.ID != item.ID || checkpoint != nil {
		t.Fatalf("without checkpoint = (%+v, %v, %v), want item and nil checkpoint", got, checkpoint, err)
	}

	focus, _, err := e.s.StartFocus(e.ctx(), app.FocusStartCmd{
		Binding: e.binding, Key: "checkpoint-read-focus", Item: item.ID,
	}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	for i, result := range []string{"earlier", "latest"} {
		if _, err := e.s.Checkpoint(e.ctx(), app.CheckpointCmd{
			Binding: e.binding, Key: "checkpoint-read-" + result, Item: item.ID,
			Result: result, NextAction: "resume from here",
		}, e.now.Add(time.Duration(i+1)*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	got, checkpoint, err = e.s.GetWorkItemWithCheckpoint(e.ctx(), e.binding, item.ID)
	if err != nil || got.ID != item.ID || checkpoint == nil || checkpoint.Result != "latest" || checkpoint.NextAction != "resume from here" {
		t.Fatalf("latest checkpoint = (%+v, %+v, %v), want result and next action", got, checkpoint, err)
	}
	if _, _, err := e.s.GetWorkItemWithCheckpoint(e.ctx(),
		domain.ScopeBinding{Profile: e.binding.Profile, Actor: e.binding.Actor, Scopes: []domain.ScopeID{"opensource"}},
		item.ID); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("out-of-scope work item = %v, want scope_denied", err)
	}
	if _, err := e.s.FinishFocus(e.ctx(), app.FocusFinishCmd{
		Binding: e.binding, Key: "checkpoint-read-finish", Focus: focus.ID, Outcome: "done",
	}, e.now.Add(3*time.Minute)); err != nil {
		t.Fatal(err)
	}
}

func TestRecordReviewUpsertsOnePeriod(t *testing.T) {
	e := newTestEnv(t)
	e.binding.Scopes = []domain.ScopeID{"personal"}
	first, err := e.s.RecordReview(e.ctx(), app.ReviewCmd{
		Binding: e.binding, Key: "r1", Kind: "daily", Period: "2026-11-19",
		Outcomes: "done", Coverage: "inbox", Complete: true,
	}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	second, err := e.s.RecordReview(e.ctx(), app.ReviewCmd{
		Binding: e.binding, Key: "r2", Kind: "daily", Period: "2026-11-19",
		Outcomes: "done again", Coverage: "inbox+next", Complete: false,
	}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID {
		t.Fatalf("review upsert created a second row: %s vs %s", first.ID, second.ID)
	}
	if second.CompletionState != "partial" {
		t.Fatalf("review state = %q, want partial", second.CompletionState)
	}
	if n := e.count(`SELECT count(*) FROM documents WHERE kind='review'`); n != 1 {
		t.Fatalf("reviews rows = %d, want 1", n)
	}
}

func TestRoutineDue(t *testing.T) {
	d := func(s string) time.Time {
		t.Helper()
		v, err := time.Parse("2006-01-02", s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	last := d("2026-11-18")
	cases := []struct {
		cadence string
		last    *time.Time
		date    string
		want    bool
	}{
		{"daily", nil, "2026-11-19", true},
		{"daily", &last, "2026-11-19", true},
		{"daily", &last, "2026-11-18", false},
		// 2026-11-19 is a Thursday; last run Monday, next is Monday 23rd.
		{"weekly:mon", ptrTime(d("2026-11-16")), "2026-11-19", false},
		{"weekly:mon", ptrTime(d("2026-11-16")), "2026-11-23", true},
		{"weekly:thu", ptrTime(d("2026-11-12")), "2026-11-19", true},
	}
	for _, c := range cases {
		got, err := routineDue(c.cadence, c.last, d(c.date))
		if err != nil {
			t.Fatalf("%s: %v", c.cadence, err)
		}
		if got != c.want {
			t.Errorf("routineDue(%s, %v, %s) = %v, want %v", c.cadence, c.last, c.date, got, c.want)
		}
	}
	if _, err := routineDue("monthly", nil, d("2026-11-19")); err == nil {
		t.Fatal("unknown cadence should fail")
	}
}

func ptrTime(t time.Time) *time.Time { return &t }

func TestDueRoutinesFiltersScope(t *testing.T) {
	e := newTestEnv(t)
	e.mustExec(`INSERT INTO routines (id, scope_id, kind, cadence, last_completed_at, active, revision)
		VALUES ('inbox', 'personal', 'inbox', 'daily', NULL, 1, 1),
		       ('other', 'opensource', 'review', 'daily', NULL, 1, 1)`)
	got, err := e.s.DueRoutines(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("due routines = %d, want 2", len(got))
	}
	solo := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	got, err = e.s.DueRoutines(e.ctx(), solo, "2026-11-19")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "inbox" {
		t.Fatalf("scoped due routines = %+v, want only inbox", got)
	}
	if _, err := e.s.CompleteRoutine(e.ctx(), e.binding, "inbox", "2026-11-19"); err != nil {
		t.Fatal(err)
	}
	got, err = e.s.DueRoutines(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].ID != "other" {
		t.Fatalf("after completion = %+v, want only other", got)
	}
}

func TestAddRoutine(t *testing.T) {
	e := newTestEnv(t)

	// Input is rejected before any row exists.
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: " ", Cadence: "daily"}); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("empty id: %v, want invalid_input", err)
	}
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "x", Cadence: "monthly"}); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("unknown cadence: %v, want invalid_input", err)
	}
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "x", Cadence: "weekly:foo"}); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("unknown weekday: %v, want invalid_input", err)
	}
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "x", Cadence: "daily", Last: "19-11-2026"}); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("bad last: %v, want invalid_input", err)
	}
	if n := e.count("SELECT count(*) FROM routines"); n != 0 {
		t.Fatalf("routines after rejected adds = %d, want 0", n)
	}

	inbox, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "inbox", Cadence: "daily"})
	if err != nil {
		t.Fatalf("add daily: %v", err)
	}
	if inbox.Scope != "personal" || inbox.Kind != "routine" || inbox.Cadence != "daily" ||
		!inbox.Active || inbox.Revision != 1 || inbox.LastCompletedAt != nil {
		t.Fatalf("daily routine = %+v", inbox)
	}
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "review", Cadence: "weekly:mon"}); err != nil {
		t.Fatalf("add weekly: %v", err)
	}
	deep, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "deep", Cadence: "weekly:thu", Last: "2026-11-19"})
	if err != nil {
		t.Fatalf("add weekly with last: %v", err)
	}
	if deep.LastCompletedAt == nil || domain.FormatDate(*deep.LastCompletedAt) != "2026-11-19" {
		t.Fatalf("deep last = %v, want 2026-11-19", deep.LastCompletedAt)
	}

	// A duplicate id conflicts.
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: e.binding, ID: "inbox", Cadence: "daily"}); !domain.Of(err, domain.Conflict) {
		t.Fatalf("duplicate id: %v, want conflict", err)
	}

	// Due now: the rows without --last are due; the weekly:thu row that ran
	// today is not.
	due, err := e.s.DueRoutines(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("DueRoutines: %v", err)
	}
	if ids := routineIDs(due); len(ids) != 2 || ids[0] != "inbox" || ids[1] != "review" {
		t.Fatalf("due = %v, want [inbox review]", ids)
	}

	// Completing the daily row clears it from the due list.
	if _, err := e.s.CompleteRoutine(e.ctx(), e.binding, "inbox", "2026-11-19"); err != nil {
		t.Fatalf("CompleteRoutine: %v", err)
	}
	due, err = e.s.DueRoutines(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("DueRoutines: %v", err)
	}
	if ids := routineIDs(due); len(ids) != 1 || ids[0] != "review" {
		t.Fatalf("due after completion = %v, want [review]", ids)
	}

	// A routine of another scope belongs to that scope only.
	osBinding := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	if _, err := e.s.AddRoutine(e.ctx(), app.RoutineAddCmd{Binding: osBinding, ID: "os-routine", Cadence: "daily"}); err != nil {
		t.Fatalf("add opensource routine: %v", err)
	}
	personalOnly := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	due, err = e.s.DueRoutines(e.ctx(), personalOnly, "2026-11-19")
	if err != nil {
		t.Fatalf("DueRoutines personal: %v", err)
	}
	if ids := routineIDs(due); len(ids) != 1 || ids[0] != "review" {
		t.Fatalf("personal due = %v, want [review] without the opensource row", ids)
	}

	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("check after adds: ok=%v errors=%v err=%v", rep.OK, rep.Errors, err)
	}
}

func routineIDs(rs []domain.Routine) []string {
	ids := make([]string, len(rs))
	for i, r := range rs {
		ids[i] = string(r.ID)
	}
	return ids
}
