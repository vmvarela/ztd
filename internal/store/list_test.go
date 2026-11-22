package store

import (
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// listFixture builds four work items across two scopes so every filter has
// something to select and something to exclude:
//
//	A personal, context familia, project pr1, next
//	B opensource, context os-ctx, next
//	C opensource, context familia, waiting
//	D personal, no context or project, someday
func listFixture(t *testing.T, e *testEnv) map[string]domain.WorkItemID {
	t.Helper()
	e.mustExec(`INSERT INTO contexts (id, scope_id, name, revision) VALUES
		('ctx-personal', 'personal', 'familia', 1),
		('ctx-os', 'opensource', 'os-ctx', 1),
		('ctx-os-familia', 'opensource', 'familia', 1)`)
	e.mustExec(`INSERT INTO projects (id, scope_id, desired_outcome, status, revision)
		VALUES ('pr1', 'personal', 'shipped', 'active', 1)`)

	osBinding := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	personalCtx, osCtx, project := domain.ContextID("ctx-personal"), domain.ContextID("ctx-os"), domain.ProjectID("pr1")

	c := e.capture("list seed personal", "list-cap-a")
	res, err := e.process(c.ID, "list-a", 1, domain.Outcome{
		Kind: domain.OutcomeWorkItems, Titles: []string{"alpha"},
		ContextID: &personalCtx, ProjectID: &project,
	}, e.now)
	if err != nil {
		t.Fatalf("process A: %v", err)
	}
	a := res.WorkItems[0]

	oc, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: osBinding, Key: "list-cap-b", Text: "list seed os"}, e.now)
	if err != nil {
		t.Fatalf("capture B: %v", err)
	}
	res, err = e.s.Process(e.ctx(), app.ProcessCmd{
		Binding: osBinding, Key: "list-b", ID: oc.ID, Expected: 1,
		Outcome: domain.Outcome{Kind: domain.OutcomeWorkItems, Titles: []string{"bravo"}, ContextID: &osCtx},
	}, e.now)
	if err != nil {
		t.Fatalf("process B: %v", err)
	}
	b := res.WorkItems[0]

	// C shares the familia context name in the other scope and moves to waiting.
	familia := domain.ContextID("ctx-os-familia")
	res, err = e.s.Process(e.ctx(), app.ProcessCmd{
		Binding: osBinding, Key: "list-c-setup", ID: mustCapture(t, e, osBinding, "list-cap-c", "list seed c").ID,
		Outcome: domain.Outcome{Kind: domain.OutcomeWorkItems, Titles: []string{"charlie"}, ContextID: &familia},
	}, e.now)
	if err != nil {
		t.Fatalf("process C: %v", err)
	}
	cItem := res.WorkItems[0]
	if _, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: osBinding, Key: "list-c-move", ID: cItem.ID,
		Target: domain.Waiting, WaitingOn: ptrStr("designer"),
	}, e.now.Add(time.Minute)); err != nil {
		t.Fatalf("move C: %v", err)
	}

	d := e.workItems(1, "list-d")[0]
	if _, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: e.binding, Key: "list-d-move", ID: d.ID, Target: domain.Someday,
	}, e.now.Add(2*time.Minute)); err != nil {
		t.Fatalf("move D: %v", err)
	}
	return map[string]domain.WorkItemID{"A": a.ID, "B": b.ID, "C": cItem.ID, "D": d.ID}
}

func mustCapture(t *testing.T, e *testEnv, b domain.ScopeBinding, key, text string) domain.Capture {
	t.Helper()
	cap, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: b, Key: key, Text: text}, e.now)
	if err != nil {
		t.Fatalf("Capture(%s): %v", key, err)
	}
	return cap
}

func idsOf(items []domain.WorkItem) []domain.WorkItemID {
	out := make([]domain.WorkItemID, 0, len(items))
	for _, it := range items {
		out = append(out, it.ID)
	}
	return out
}

func wantIDs(t *testing.T, got []domain.WorkItem, want ...domain.WorkItemID) {
	t.Helper()
	gotIDs := idsOf(got)
	if len(gotIDs) != len(want) {
		t.Fatalf("ids = %v, want %v", gotIDs, want)
	}
	for i := range want {
		if gotIDs[i] != want[i] {
			t.Fatalf("ids = %v, want %v (in order)", gotIDs, want)
		}
	}
}

func TestListWorkItemsFiltered(t *testing.T) {
	e := newTestEnv(t)
	ids := listFixture(t, e)
	list := func(filter app.ListWorkItemsFilter) []domain.WorkItem {
		t.Helper()
		got, err := e.s.ListWorkItemsFiltered(e.ctx(), e.binding, filter)
		if err != nil {
			t.Fatalf("ListWorkItemsFiltered(%+v): %v", filter, err)
		}
		return got
	}

	// No filter: every lifecycle, ordered next, waiting, someday; ties inside a
	// lifecycle break by updated_at descending then id ascending.
	all := list(app.ListWorkItemsFilter{})
	wantIDs(t, all, ids["A"], ids["B"], ids["C"], ids["D"])
	if all[0].Lifecycle != domain.Next || all[2].Lifecycle != domain.Waiting || all[3].Lifecycle != domain.Someday {
		t.Fatalf("lifecycle order = %v", idsOf(all))
	}

	wantIDs(t, list(app.ListWorkItemsFilter{Lifecycle: domain.Next}), ids["A"], ids["B"])
	wantIDs(t, list(app.ListWorkItemsFilter{Lifecycle: domain.Waiting}), ids["C"])
	wantIDs(t, list(app.ListWorkItemsFilter{Lifecycle: domain.Someday}), ids["D"])
	if got := list(app.ListWorkItemsFilter{Lifecycle: domain.Archived}); len(got) != 0 {
		t.Fatalf("archived = %v, want empty", idsOf(got))
	}

	// Context matches the name inside the binding scopes: "familia" exists in
	// both scopes, so the full binding sees both items and a narrowed one only
	// its own.
	wantIDs(t, list(app.ListWorkItemsFilter{Context: "familia"}), ids["A"], ids["C"])
	wantIDs(t, list(app.ListWorkItemsFilter{Context: "os-ctx"}), ids["B"])
	if got := list(app.ListWorkItemsFilter{Context: "nowhere"}); len(got) != 0 {
		t.Fatalf("unknown context = %v, want empty", idsOf(got))
	}
	narrow := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	got, err := e.s.ListWorkItemsFiltered(e.ctx(), narrow, app.ListWorkItemsFilter{Context: "familia"})
	if err != nil {
		t.Fatalf("scoped context list: %v", err)
	}
	wantIDs(t, got, ids["C"])

	wantIDs(t, list(app.ListWorkItemsFilter{Project: domain.ProjectID("pr1")}), ids["A"])
	if got := list(app.ListWorkItemsFilter{Project: domain.ProjectID("ghost")}); len(got) != 0 {
		t.Fatalf("unknown project = %v, want empty", idsOf(got))
	}

	// Scope narrows further and must be allowed by the binding.
	wantIDs(t, list(app.ListWorkItemsFilter{Scope: "opensource"}), ids["B"], ids["C"])
	wantIDs(t, list(app.ListWorkItemsFilter{Scope: "personal"}), ids["A"], ids["D"])
	_, err = e.s.ListWorkItemsFiltered(e.ctx(), e.binding, app.ListWorkItemsFilter{Scope: "trabajo"})
	wantFamily(t, err, domain.ScopeDenied)

	// Binding isolation: an opensource-only binding never sees personal rows.
	got, err = e.s.ListWorkItemsFiltered(e.ctx(), narrow, app.ListWorkItemsFilter{})
	if err != nil {
		t.Fatalf("narrow list: %v", err)
	}
	wantIDs(t, got, ids["B"], ids["C"])

	// Lifecycle and scope combine, and an unknown lifecycle is refused.
	wantIDs(t, list(app.ListWorkItemsFilter{Lifecycle: domain.Waiting, Scope: "personal"}))
	_, err = e.s.ListWorkItemsFiltered(e.ctx(), e.binding, app.ListWorkItemsFilter{Lifecycle: "inbox"})
	wantFamily(t, err, domain.InvalidInput)

	// The legacy entry point is the filtered method with only a lifecycle.
	legacy, err := e.s.ListWorkItems(e.ctx(), e.binding, domain.Next)
	if err != nil {
		t.Fatalf("ListWorkItems: %v", err)
	}
	wantIDs(t, legacy, ids["A"], ids["B"])
}

// TestListInboxCoversPendingAndDueDeferred pins the inbox listing behind
// `ztd list --list inbox`: same rows as InboxNext, oldest first, capped.
func TestListInbox(t *testing.T) {
	e := newTestEnv(t)
	if got, err := e.s.ListInbox(e.ctx(), e.binding, e.now); err != nil || len(got) != 0 {
		t.Fatalf("empty inbox = %v (err %v), want empty", got, err)
	}
	first := e.capture("first", "li-1")
	second := e.capture("second", "li-2")
	reviewAt := e.now.Add(time.Hour)
	if _, err := e.process(second.ID, "li-defer", 1, domain.Outcome{
		Kind: domain.OutcomeDefer, ReviewAfter: &reviewAt,
	}, e.now); err != nil {
		t.Fatalf("defer second: %v", err)
	}
	got, err := e.s.ListInbox(e.ctx(), e.binding, e.now)
	if err != nil || len(got) != 1 || got[0].ID != first.ID {
		t.Fatalf("due inbox = %v (err %v), want only %s", idsOf2(got), err, first.ID)
	}
	got, err = e.s.ListInbox(e.ctx(), e.binding, e.now.Add(2*time.Hour))
	if err != nil || len(got) != 2 || got[0].ID != first.ID || got[1].ID != second.ID {
		t.Fatalf("later inbox = %v (err %v), want [%s %s]", idsOf2(got), err, first.ID, second.ID)
	}
	// A binding over other scopes sees no rows.
	outside := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"trabajo"}}
	if got, err := e.s.ListInbox(e.ctx(), outside, e.now); err != nil || len(got) != 0 {
		t.Fatalf("foreign scope inbox = %v (err %v), want empty", got, err)
	}
}

func idsOf2(caps []domain.Capture) []domain.CaptureID {
	out := make([]domain.CaptureID, 0, len(caps))
	for _, c := range caps {
		out = append(out, c.ID)
	}
	return out
}
