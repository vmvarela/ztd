package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// insertItem plants a work item through direct SQL, bypassing the command
// path — used for arrange steps and for deliberately broken rows.
func (e *testEnv) insertItem(id, scope, title string, lifecycle domain.Lifecycle, updatedAt time.Time) {
	e.t.Helper()
	var waiting any
	if lifecycle == domain.Waiting {
		waiting = "someone"
	}
	e.mustExec(`INSERT INTO work_items (id, scope_id, title, status, waiting_on, revision, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 1, ?, ?)`,
		id, scope, title, string(lifecycle), waiting, fmtTime(updatedAt), fmtTime(updatedAt))
}

func mustJSONEqual(t *testing.T, a, b any, what string) {
	t.Helper()
	ja, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("marshal %s: %v", what, err)
	}
	jb, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("marshal %s: %v", what, err)
	}
	if string(ja) != string(jb) {
		t.Fatalf("%s differs:\n%s\n%s", what, ja, jb)
	}
}

func TestProcessEachOutcome(t *testing.T) {
	t.Run("work_items is atomic and links references", func(t *testing.T) {
		e := newTestEnv(t)
		e.mustExec(`INSERT INTO contexts (id, scope_id, name, revision) VALUES ('ctx1','personal','errands',1)`)
		e.mustExec(`INSERT INTO contexts (id, scope_id, name, revision) VALUES ('ar1','personal','home',1)`)
		e.mustExec(`INSERT INTO projects (id, scope_id, area_id, desired_outcome, status, revision)
			VALUES ('pr1','personal','ar1','ship it','active',1)`)
		c := e.capture("two things", "k")
		ctxID, areaID, projID := domain.ContextID("ctx1"), domain.AreaID("ar1"), domain.ProjectID("pr1")
		res, err := e.process(c.ID, "p", 1, domain.Outcome{
			Kind: domain.OutcomeWorkItems, Titles: []string{"first", "second"},
			ContextID: &ctxID, AreaID: &areaID, ProjectID: &projID,
		}, e.now)
		if err != nil {
			t.Fatalf("Process: %v", err)
		}
		if len(res.WorkItems) != 2 {
			t.Fatalf("got %d work items, want 2", len(res.WorkItems))
		}
		wantIDs := []domain.WorkItemID{"T-20261119-001", "T-20261119-002"}
		for i, w := range res.WorkItems {
			if w.ID != wantIDs[i] {
				t.Errorf("work item %d id = %s, want %s", i, w.ID, wantIDs[i])
			}
			if w.Lifecycle != domain.Next || w.Revision != 1 || w.Scope != "personal" {
				t.Errorf("work item %d = %+v", i, w)
			}
			if w.OriginCaptureID == nil || *w.OriginCaptureID != c.ID {
				t.Errorf("work item %d origin = %v, want %s", i, w.OriginCaptureID, c.ID)
			}
			if w.ContextID == nil || *w.ContextID != ctxID || w.ProjectID == nil || *w.ProjectID != projID || w.AreaID == nil || *w.AreaID != areaID {
				t.Errorf("work item %d links = %+v", i, w)
			}
		}
		if res.Capture.State != domain.Processed || res.Capture.Revision != 2 {
			t.Fatalf("capture after process = state %s revision %d", res.Capture.State, res.Capture.Revision)
		}
		if res.Capture.Outcome == nil || res.Capture.Outcome.Kind != domain.OutcomeWorkItems {
			t.Fatalf("capture outcome = %+v", res.Capture.Outcome)
		}
		// captured + 2 created work items + processed = 4 history rows.
		if n := e.count(`SELECT count(*) FROM history_events`); n != 4 {
			t.Fatalf("history = %d, want 4", n)
		}
		if n := e.count(`SELECT count(*) FROM idempotency_records`); n != 2 {
			t.Fatalf("idempotency records = %d, want 2", n)
		}
		got, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
		if err != nil || got.OriginalText != "two things" {
			t.Fatalf("original text mutated: %q (err %v)", got.OriginalText, err)
		}
	})

	t.Run("reference keeps the inbox clean", func(t *testing.T) {
		e := newTestEnv(t)
		c := e.capture("just a pointer", "k")
		res, err := e.process(c.ID, "p", 1, domain.Outcome{Kind: domain.OutcomeReference}, e.now)
		if err != nil {
			t.Fatalf("Process: %v", err)
		}
		if res.Capture.State != domain.Processed || len(res.WorkItems) != 0 {
			t.Fatalf("reference outcome = state %s, %d items", res.Capture.State, len(res.WorkItems))
		}
		if n := e.count(`SELECT count(*) FROM work_items`); n != 0 {
			t.Fatalf("work items = %d, want 0", n)
		}
	})

	t.Run("immediate records evidence as a declaration", func(t *testing.T) {
		e := newTestEnv(t)
		c := e.capture("send the mail", "k")
		res, err := e.process(c.ID, "p", 1, domain.Outcome{
			Kind: domain.OutcomeImmediate, ResultEvidence: "declared sent at 09:00",
		}, e.now)
		if err != nil {
			t.Fatalf("Process: %v", err)
		}
		if res.Capture.State != domain.Processed {
			t.Fatalf("state = %s", res.Capture.State)
		}
		if res.Capture.Outcome == nil || res.Capture.Outcome.ResultEvidence != "declared sent at 09:00" {
			t.Fatalf("evidence = %+v", res.Capture.Outcome)
		}
		// The evidence is recorded in history, not claimed as external fact.
		var payload string
		if err := e.s.db.QueryRow(`SELECT payload_json FROM history_events
			WHERE entity_type='capture' AND event='processed'`).Scan(&payload); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(payload, "declared sent at 09:00") {
			t.Fatalf("history payload missing evidence: %s", payload)
		}
	})

	t.Run("discard preserves the original and the reason", func(t *testing.T) {
		e := newTestEnv(t)
		c := e.capture("spam idea", "k")
		res, err := e.process(c.ID, "p", 1, domain.Outcome{
			Kind: domain.OutcomeDiscard, Reason: "not actionable",
		}, e.now)
		if err != nil {
			t.Fatalf("Process: %v", err)
		}
		if res.Capture.State != domain.Discarded {
			t.Fatalf("state = %s, want discarded", res.Capture.State)
		}
		got, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
		if err != nil || got.OriginalText != "spam idea" {
			t.Fatalf("original text lost: %q (err %v)", got.OriginalText, err)
		}
		if got.State != domain.Discarded {
			t.Fatalf("stored state = %s", got.State)
		}
	})

	t.Run("defer stores a visible review_after", func(t *testing.T) {
		e := newTestEnv(t)
		c := e.capture("think later", "k")
		reviewAt := e.now.Add(24 * time.Hour)
		res, err := e.process(c.ID, "p", 1, domain.Outcome{
			Kind: domain.OutcomeDefer, ReviewAfter: &reviewAt,
		}, e.now)
		if err != nil {
			t.Fatalf("Process: %v", err)
		}
		if res.Capture.State != domain.Deferred || res.Capture.ReviewAfter == nil {
			t.Fatalf("defer outcome = state %s review %v", res.Capture.State, res.Capture.ReviewAfter)
		}
		if !res.Capture.ReviewAfter.Equal(reviewAt) {
			t.Fatalf("review_after = %v, want %v", res.Capture.ReviewAfter, reviewAt)
		}
		got, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
		if err != nil || got.State != domain.Deferred || got.ReviewAfter == nil {
			t.Fatalf("stored deferred capture: %+v (err %v)", got, err)
		}
		if got.Outcome == nil || got.Outcome.Kind != domain.OutcomeDefer {
			t.Fatalf("stored outcome = %+v", got.Outcome)
		}
	})
}

func TestProcessIdempotentReplay(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("replay me", "k")
	first := e.mustProcess(c.ID, "p1", 1, "one task")
	second, err := e.process(c.ID, "p1", 1, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"one task"},
	}, e.now.Add(time.Hour))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	mustJSONEqual(t, first, second, "replayed ProcessResult")
	if n := e.count(`SELECT count(*) FROM work_items`); n != 1 {
		t.Fatalf("work items after replay = %d, want 1", n)
	}
	// Without the original key the state transition itself rejects the repeat.
	_, err = e.process(c.ID, "p2", 2, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"one task"},
	}, e.now)
	wantFamily(t, err, domain.InvalidTransition)
}

func TestProcessAtomicRollback(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("boom", "k")
	// Inject a failure on the last write of the transaction: if the work items
	// or the capture transition survived, the transaction was not atomic.
	e.mustExec(`CREATE TRIGGER reject_idem BEFORE INSERT ON idempotency_records
		BEGIN SELECT RAISE(ABORT, 'injected failure'); END`)
	before := e.counts()
	_, err := e.process(c.ID, "p1", 1, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"a", "b"},
	}, e.now)
	if err == nil {
		t.Fatal("expected the injected failure to surface")
	}
	if after := e.counts(); after != before {
		t.Fatalf("partial writes survived: before %v after %v", before, after)
	}
	got, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
	if err != nil || got.State != domain.Pending || got.Revision != 1 {
		t.Fatalf("capture after rollback = state %s revision %d (err %v)", got.State, got.Revision, err)
	}
}

func TestProcessRejectsCrossScopeReference(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("scoped", "k")
	e.mustExec(`INSERT INTO contexts (id, scope_id, name, revision) VALUES ('ctx-os','opensource','foreign',1)`)
	ctxID := domain.ContextID("ctx-os")
	before := e.counts()
	_, err := e.process(c.ID, "p1", 1, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"t"}, ContextID: &ctxID,
	}, e.now)
	wantFamily(t, err, domain.ScopeDenied)
	if after := e.counts(); after != before {
		t.Fatalf("rejected reference wrote state: before %v after %v", before, after)
	}
	missing := domain.ContextID("nope")
	_, err = e.process(c.ID, "p2", 1, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"t"}, ContextID: &missing,
	}, e.now)
	wantFamily(t, err, domain.InvalidInput)
	if after := e.counts(); after != before {
		t.Fatalf("unknown reference wrote state: before %v after %v", before, after)
	}
}

// TestFailedValidationLeavesStateUntouched is table-driven over the exposed
// edge cases: every rejected input must fail with its family and change
// nothing at all.
func TestFailedValidationLeavesStateUntouched(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("untouched subject", "seed")
	before := e.counts()

	cases := []struct {
		name string
		want domain.Family
		run  func() error
	}{
		{"capture empty text", domain.InvalidInput, func() error {
			_, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: "v1", Text: "   "}, e.now)
			return err
		}},
		{"capture missing key", domain.InvalidInput, func() error {
			_, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: " ", Text: "x"}, e.now)
			return err
		}},
		{"capture external id without revision", domain.InvalidInput, func() error {
			eid := "ext"
			_, err := e.s.Capture(e.ctx(), app.CaptureCmd{
				Binding: e.binding, Key: "v2", Text: "x", SourceID: "src", ExternalID: &eid,
			}, e.now)
			return err
		}},
		{"capture over 64 KiB", domain.InvalidInput, func() error {
			_, err := e.s.Capture(e.ctx(), app.CaptureCmd{
				Binding: e.binding, Key: "v3", Text: strings.Repeat("a", 64*1024+1),
			}, e.now)
			return err
		}},
		{"capture invalid utf-8", domain.InvalidInput, func() error {
			_, err := e.s.Capture(e.ctx(), app.CaptureCmd{
				Binding: e.binding, Key: "v4", Text: "\xff\xfe",
			}, e.now)
			return err
		}},
		{"process missing key", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "", 1, domain.Outcome{Kind: domain.OutcomeReference}, e.now)
			return err
		}},
		{"process missing id", domain.InvalidInput, func() error {
			_, err := e.s.Process(e.ctx(), app.ProcessCmd{
				Binding: e.binding, Key: "v5", Outcome: domain.Outcome{Kind: domain.OutcomeReference},
			}, e.now)
			return err
		}},
		{"process unknown outcome", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v6", 1, domain.Outcome{Kind: "bogus"}, e.now)
			return err
		}},
		{"process work_items without titles", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v7", 1, domain.Outcome{Kind: domain.OutcomeWorkItems}, e.now)
			return err
		}},
		{"process work_items with blank title", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v8", 1, domain.Outcome{
				Kind: domain.OutcomeWorkItems, Titles: []string{"ok", "  "},
			}, e.now)
			return err
		}},
		{"process immediate without evidence", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v9", 1, domain.Outcome{Kind: domain.OutcomeImmediate}, e.now)
			return err
		}},
		{"process discard without reason", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v10", 1, domain.Outcome{Kind: domain.OutcomeDiscard}, e.now)
			return err
		}},
		{"process defer without review_after", domain.InvalidInput, func() error {
			_, err := e.process(c.ID, "v11", 1, domain.Outcome{Kind: domain.OutcomeDefer}, e.now)
			return err
		}},
		{"commit plan missing period", domain.InvalidInput, func() error {
			_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
				Binding: e.binding, Key: "v12", Kind: domain.DailyPlan,
			}, e.now)
			return err
		}},
		{"commit plan bad kind", domain.InvalidInput, func() error {
			_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
				Binding: e.binding, Key: "v13", Kind: "yearly", Period: "2026",
			}, e.now)
			return err
		}},
		{"find empty query", domain.InvalidInput, func() error {
			_, err := e.s.Find(e.ctx(), e.binding, "  ", 0)
			return err
		}},
		{"prepare malformed date", domain.InvalidInput, func() error {
			_, err := e.s.Prepare(e.ctx(), e.binding, "november")
			return err
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.run()
			wantFamily(t, err, tc.want)
			if after := e.counts(); after != before {
				t.Fatalf("failed validation wrote state: before %v after %v", before, after)
			}
		})
	}
}

// TestStaleRevision is table-driven over every operation with optimistic
// concurrency: a rejected expected revision must not touch state.
func TestStaleRevision(t *testing.T) {
	ref := domain.Outcome{Kind: domain.OutcomeReference}
	oneMit := func(id domain.WorkItemID) []domain.PlanItem {
		return []domain.PlanItem{{WorkItemID: id, Role: domain.MITRole}}
	}
	var updateItem domain.WorkItemID
	cases := []struct {
		name  string
		want  domain.Family
		setup func(e *testEnv, c domain.Capture)
		run   func(e *testEnv, c domain.Capture) error
	}{
		{
			name: "process above the actual revision",
			want: domain.StaleRevision,
			run: func(e *testEnv, c domain.Capture) error {
				_, err := e.process(c.ID, "s1", 2, ref, e.now)
				return err
			},
		},
		{
			name: "process below the actual revision",
			want: domain.StaleRevision,
			setup: func(e *testEnv, c domain.Capture) {
				e.mustProcess(c.ID, "pre", 1, "already done") // capture moves to revision 2
			},
			run: func(e *testEnv, c domain.Capture) error {
				_, err := e.process(c.ID, "s2", 1, ref, e.now)
				return err
			},
		},
		{
			name: "plan create-only with nonzero expected",
			want: domain.StaleRevision,
			run: func(e *testEnv, c domain.Capture) error {
				_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
					Binding: e.binding, Key: "s3", Kind: domain.DailyPlan,
					Period: "2026-11-19", Expected: 7,
				}, e.now)
				return err
			},
		},
		{
			name: "plan update with wrong expected",
			want: domain.StaleRevision,
			setup: func(e *testEnv, c domain.Capture) {
				items := e.workItems(1, "pw")
				updateItem = items[0].ID
				if _, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
					Binding: e.binding, Key: "setup-plan", Kind: domain.DailyPlan,
					Period: "2026-11-19", Items: oneMit(updateItem),
				}, e.now); err != nil {
					e.t.Fatalf("setup plan: %v", err)
				}
			},
			run: func(e *testEnv, c domain.Capture) error {
				// The plan sits at revision 1; expected 9 must fail before any write.
				_, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
					Binding: e.binding, Key: "s4", Kind: domain.DailyPlan,
					Period: "2026-11-19", Expected: 9, Items: oneMit(updateItem),
				}, e.now)
				return err
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newTestEnv(t)
			c := e.capture("stale subject", "stale-cap")
			if tc.setup != nil {
				tc.setup(e, c)
			}
			before := e.counts()
			err := tc.run(e, c)
			wantFamily(t, err, tc.want)
			if after := e.counts(); after != before {
				t.Fatalf("stale revision wrote state: before %v after %v", before, after)
			}
		})
	}
}

func TestDeferBecomesDue(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("waiting for review", "k")
	reviewAt := e.now.Add(time.Hour)
	res, err := e.process(c.ID, "p-defer", 1, domain.Outcome{
		Kind: domain.OutcomeDefer, ReviewAfter: &reviewAt,
	}, e.now)
	if err != nil {
		t.Fatalf("defer: %v", err)
	}
	if res.Capture.State != domain.Deferred || res.Capture.Revision != 2 {
		t.Fatalf("after defer: state %s revision %d", res.Capture.State, res.Capture.Revision)
	}
	before := e.counts()
	// Not due yet: rejected, and the failed attempt writes nothing — not even
	// an idempotency record for its key.
	_, err = e.process(c.ID, "p-ref", 2, domain.Outcome{Kind: domain.OutcomeReference}, e.now)
	wantFamily(t, err, domain.InvalidTransition)
	if after := e.counts(); after != before {
		t.Fatalf("premature process wrote state: before %v after %v", before, after)
	}
	// Due an hour later, with the same key as the failed attempt.
	later := e.now.Add(2 * time.Hour)
	res2, err := e.process(c.ID, "p-ref", 2, domain.Outcome{Kind: domain.OutcomeReference}, later)
	if err != nil {
		t.Fatalf("process due deferred capture: %v", err)
	}
	if res2.Capture.State != domain.Processed || res2.Capture.Revision != 3 {
		t.Fatalf("after due process: state %s revision %d", res2.Capture.State, res2.Capture.Revision)
	}
	got, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
	if err != nil || got.ReviewAfter != nil {
		t.Fatalf("review_after not cleared on processed capture: %+v (err %v)", got.ReviewAfter, err)
	}
	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("check after defer cycle: %+v (err %v)", rep.Errors, err)
	}
}

func TestInboxNext(t *testing.T) {
	e := newTestEnv(t)
	if _, err := e.s.InboxNext(e.ctx(), e.binding, e.now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("empty inbox: got %v, want not_found", err)
	}
	c1 := e.capture("first", "k1")
	c2 := e.capture("second", "k2")
	got, err := e.s.InboxNext(e.ctx(), e.binding, e.now)
	if err != nil || got.ID != c1.ID {
		t.Fatalf("inbox next = %v (err %v), want %s", got.ID, err, c1.ID)
	}
	e.mustProcess(c1.ID, "p1", 1, "first task")
	got, err = e.s.InboxNext(e.ctx(), e.binding, e.now)
	if err != nil || got.ID != c2.ID {
		t.Fatalf("inbox next = %v (err %v), want %s", got.ID, err, c2.ID)
	}
	// Defer the remaining capture: it leaves the inbox until it is due.
	reviewAt := e.now.Add(time.Hour)
	if _, err := e.process(c2.ID, "p2", 1, domain.Outcome{
		Kind: domain.OutcomeDefer, ReviewAfter: &reviewAt,
	}, e.now); err != nil {
		t.Fatalf("defer second: %v", err)
	}
	if _, err := e.s.InboxNext(e.ctx(), e.binding, e.now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("deferred inbox: got %v, want not_found", err)
	}
	got, err = e.s.InboxNext(e.ctx(), e.binding, e.now.Add(2*time.Hour))
	if err != nil || got.ID != c2.ID {
		t.Fatalf("due inbox next = %v (err %v), want %s", got.ID, err, c2.ID)
	}
}

func TestFindOrderingCaseAndLimits(t *testing.T) {
	e := newTestEnv(t)
	e.insertItem("T-19990101-001", "personal", "Comprar PAN grande", domain.Next, e.now)
	e.insertItem("T-19990101-002", "personal", "pan integral", domain.Next, e.now.Add(time.Minute))
	e.insertItem("T-19990101-003", "personal", "Someday pan trip", domain.Someday, e.now.Add(2*time.Minute))

	got, err := e.s.Find(e.ctx(), e.binding, "PAN", 0)
	if err != nil {
		t.Fatalf("Find: %v", err)
	}
	want := []domain.WorkItemID{"T-19990101-002", "T-19990101-001", "T-19990101-003"}
	if len(got) != len(want) {
		t.Fatalf("Find returned %d rows, want %d", len(got), len(want))
	}
	for i, id := range want {
		if got[i].ID != id {
			t.Errorf("result %d = %s, want %s (lifecycle then updated_at desc)", i, got[i].ID, id)
		}
	}
	limited, err := e.s.Find(e.ctx(), e.binding, "pan", 1)
	if err != nil || len(limited) != 1 {
		t.Fatalf("Find limit 1 = %d rows (err %v)", len(limited), err)
	}
	if none, err := e.s.Find(e.ctx(), e.binding, "zzz", 0); err != nil || len(none) != 0 {
		t.Fatalf("Find without matches = %d rows (err %v)", len(none), err)
	}

	for i := 0; i < 55; i++ {
		e.insertItem(fmt.Sprintf("T-19990202-%03d", i), "personal",
			fmt.Sprintf("pagelimit item %d", i), domain.Next, e.now)
	}
	if rows, err := e.s.Find(e.ctx(), e.binding, "pagelimit", 100); err != nil || len(rows) != 50 {
		t.Fatalf("Find with limit 100 = %d rows (err %v), want the cap of 50", len(rows), err)
	}
	if rows, err := e.s.Find(e.ctx(), e.binding, "pagelimit", 0); err != nil || len(rows) != 10 {
		t.Fatalf("Find with default limit = %d rows (err %v), want 10", len(rows), err)
	}
}
