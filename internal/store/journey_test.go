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

func TestRecordReviewUpsertsOnePeriod(t *testing.T) {
	e := newTestEnv(t)
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
	if n := e.count(`SELECT count(*) FROM reviews`); n != 1 {
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
