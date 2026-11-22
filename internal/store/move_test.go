package store

import (
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func ptrStr(s string) *string { return &s }

// TestMoveWorkItemLifecycleChain walks next -> waiting -> next -> someday ->
// archive and pins the state each target sets, the revision ladder, the
// merged custom fields and the history trail.
func TestMoveWorkItemLifecycleChain(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "chain")[0]
	move := func(key string, now time.Time, mutate func(*app.MoveWorkItemCmd)) domain.WorkItem {
		t.Helper()
		cmd := app.MoveWorkItemCmd{Binding: e.binding, Key: key, ID: item.ID}
		mutate(&cmd)
		got, err := e.s.MoveWorkItem(e.ctx(), cmd, now)
		if err != nil {
			t.Fatalf("MoveWorkItem(%s): %v", key, err)
		}
		return got
	}

	waiting := move("m1", e.now, func(c *app.MoveWorkItemCmd) {
		c.Target = domain.Waiting
		c.WaitingOn = ptrStr("builder @2026-11-25")
		c.Fields = map[string]string{"siguiente": "draft section 2"}
	})
	if waiting.Lifecycle != domain.Waiting || waiting.WaitingOn != "builder @2026-11-25" {
		t.Fatalf("waiting move = %+v", waiting)
	}
	if waiting.ClosureKind != "" || waiting.ClosedAt != nil || waiting.Resolution != "" {
		t.Fatalf("waiting kept closure state: %+v", waiting)
	}
	if waiting.Revision != 2 {
		t.Fatalf("revision after first move = %d, want 2", waiting.Revision)
	}
	if waiting.CustomFields["siguiente"] != "draft section 2" {
		t.Fatalf("custom fields after first move = %v", waiting.CustomFields)
	}

	back := move("m2", e.now.Add(time.Minute), func(c *app.MoveWorkItemCmd) {
		c.Target = domain.Next
	})
	if back.Lifecycle != domain.Next || back.WaitingOn != "" {
		t.Fatalf("back to next = %+v, waiting_on must be cleared", back)
	}
	if back.Revision != 3 {
		t.Fatalf("revision after second move = %d, want 3", back.Revision)
	}
	if back.CustomFields["siguiente"] != "draft section 2" {
		t.Fatalf("custom fields lost on move back: %v", back.CustomFields)
	}

	someday := move("m3", e.now.Add(2*time.Minute), func(c *app.MoveWorkItemCmd) {
		c.Target = domain.Someday
		c.Text = ptrStr("learn Go generics")
	})
	if someday.Lifecycle != domain.Someday || someday.Title != "learn Go generics" || someday.Revision != 4 {
		t.Fatalf("someday move = %+v", someday)
	}

	archived := move("m4", e.now.Add(3*time.Minute), func(c *app.MoveWorkItemCmd) {
		c.Target = domain.Archived
		c.Resolution = ptrStr("renewed at the counter")
	})
	if archived.Lifecycle != domain.Archived || archived.Revision != 5 {
		t.Fatalf("archive move = %+v", archived)
	}
	if archived.ClosedAt == nil || !archived.ClosedAt.Equal(e.now.Add(3*time.Minute)) {
		t.Fatalf("closed_at = %v, want %v", archived.ClosedAt, e.now.Add(3*time.Minute))
	}
	if archived.ClosureKind != domain.Completed {
		t.Fatalf("closure kind = %q, want completed by default", archived.ClosureKind)
	}
	if archived.Resolution != "renewed at the counter" || archived.WaitingOn != "" {
		t.Fatalf("archived resolution/waiting_on = %q/%q", archived.Resolution, archived.WaitingOn)
	}

	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'work_item' AND event = 'moved'`); n != 4 {
		t.Fatalf("moved history events = %d, want 4", n)
	}
	var lastPayload string
	if err := e.s.db.QueryRowContext(e.ctx(),
		`SELECT payload_json FROM history_events WHERE event = 'moved' ORDER BY seq DESC LIMIT 1`).
		Scan(&lastPayload); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(lastPayload, `"target":"archived"`) || !strings.Contains(lastPayload, "renewed at the counter") {
		t.Fatalf("last moved payload = %s", lastPayload)
	}
	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("check after chain: %+v (err %v)", rep.Errors, err)
	}
	got, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil || !got.UpdatedAt.Equal(e.now.Add(3*time.Minute)) {
		t.Fatalf("updated_at = %v (err %v), want the last move time", got.UpdatedAt, err)
	}
}

// TestMoveWorkItemRejectsInvalidCommands pins every precondition: each
// rejection keeps its family and writes nothing at all.
func TestMoveWorkItemRejectsInvalidCommands(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "reject")[0]
	before := e.counts()
	base := func(key string, target domain.Lifecycle) app.MoveWorkItemCmd {
		return app.MoveWorkItemCmd{Binding: e.binding, Key: key, ID: item.ID, Target: target}
	}
	cases := []struct {
		name string
		want domain.Family
		cmd  app.MoveWorkItemCmd
	}{
		{"waiting without waiting_on", domain.InvalidInput, base("r1", domain.Waiting)},
		{"archive without resolution", domain.InvalidInput, base("r2", domain.Archived)},
		{"inbox is not a move target", domain.InvalidInput, base("r3", domain.Lifecycle("inbox"))},
		{"unknown closure kind", domain.InvalidInput, func() app.MoveWorkItemCmd {
			c := base("r4", domain.Archived)
			c.Resolution = ptrStr("done")
			c.ClosureKind = "done"
			return c
		}()},
		{"reserved field key", domain.InvalidInput, func() app.MoveWorkItemCmd {
			c := base("r5", domain.Someday)
			c.Fields = map[string]string{"waiting_on": "someone"}
			return c
		}()},
		{"blank field key", domain.InvalidInput, func() app.MoveWorkItemCmd {
			c := base("r6", domain.Someday)
			c.Fields = map[string]string{"  ": "x"}
			return c
		}()},
		{"empty text", domain.InvalidInput, func() app.MoveWorkItemCmd {
			c := base("r7", domain.Someday)
			c.Text = ptrStr("   ")
			return c
		}()},
		{"missing idempotency key", domain.InvalidInput, func() app.MoveWorkItemCmd {
			c := base("r8", domain.Someday)
			c.Key = " "
			return c
		}()},
		{"stale expected revision", domain.StaleRevision, func() app.MoveWorkItemCmd {
			c := base("r9", domain.Someday)
			c.Expected = 9
			return c
		}()},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := e.s.MoveWorkItem(e.ctx(), tc.cmd, e.now)
			wantFamily(t, err, tc.want)
			if after := e.counts(); after != before {
				t.Fatalf("rejected move wrote state: before %v after %v", before, after)
			}
			got, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
			if err != nil || got.Lifecycle != domain.Next || got.Revision != 1 {
				t.Fatalf("item after rejection = %+v (err %v), untouched next revision 1", got, err)
			}
		})
	}
}

// TestMoveWorkItemIdempotency pins the key contract: an identical replay
// returns the stored result, a different payload under the same key conflicts
// and changes nothing.
func TestMoveWorkItemIdempotency(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "idem")[0]
	cmd := app.MoveWorkItemCmd{
		Binding: e.binding, Key: "move-1", ID: item.ID,
		Target: domain.Waiting, WaitingOn: ptrStr("ana"),
	}
	first, err := e.s.MoveWorkItem(e.ctx(), cmd, e.now)
	if err != nil {
		t.Fatalf("first move: %v", err)
	}
	replay, err := e.s.MoveWorkItem(e.ctx(), cmd, e.now.Add(time.Hour))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	mustJSONEqual(t, first, replay, "replayed MoveWorkItem")
	if n := e.count(`SELECT count(*) FROM history_events WHERE event = 'moved'`); n != 1 {
		t.Fatalf("moved events after replay = %d, want 1", n)
	}
	afterFirst := e.counts()

	other := cmd
	other.Target = domain.Next
	_, err = e.s.MoveWorkItem(e.ctx(), other, e.now)
	wantFamily(t, err, domain.IdempotencyConflict)
	if after := e.counts(); after != afterFirst {
		t.Fatalf("conflicting payload wrote state: before %v after %v", afterFirst, after)
	}
	got, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil || got.Lifecycle != domain.Waiting || got.Revision != 2 {
		t.Fatalf("item after conflict = %+v (err %v), want waiting revision 2", got, err)
	}
}

// TestMoveWorkItemCrossScopeIsNotFound proves a move never discloses an item
// that lives outside the binding, and never touches it.
func TestMoveWorkItemCrossScopeIsNotFound(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "cross")[0] // personal scope
	outside := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}

	_, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: outside, Key: "x1", ID: item.ID, Target: domain.Someday,
	}, e.now)
	wantFamily(t, err, domain.NotFound)

	_, err = e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: e.binding, Key: "x2", ID: "T-19990101-001", Target: domain.Someday,
	}, e.now)
	wantFamily(t, err, domain.NotFound)

	got, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil || got.Lifecycle != domain.Next || got.Revision != 1 {
		t.Fatalf("item after cross-scope attempts = %+v (err %v), untouched", got, err)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE event = 'moved'`); n != 0 {
		t.Fatalf("cross-scope moves wrote %d history events", n)
	}
}

// TestWorkItemCustomFieldsSurviveCreateProcessAndMerge covers the column
// itself: a fresh work item starts empty, moves merge instead of replacing,
// and the stored value reads back as the same object.
func TestWorkItemCustomFieldsSurviveCreateProcessAndMerge(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "fields")[0]
	got, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil {
		t.Fatalf("GetWorkItem: %v", err)
	}
	if len(got.CustomFields) != 0 {
		t.Fatalf("fresh work item custom fields = %v, want empty", got.CustomFields)
	}

	if _, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: e.binding, Key: "f1", ID: item.ID, Target: domain.Someday,
		Fields: map[string]string{"siguiente": "draft", "resultado": ""},
	}, e.now); err != nil {
		t.Fatalf("first field move: %v", err)
	}
	second, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: e.binding, Key: "f2", ID: item.ID, Target: domain.Someday,
		Fields: map[string]string{"ok": "yes"},
	}, e.now.Add(time.Minute))
	if err != nil {
		t.Fatalf("second field move: %v", err)
	}
	if second.Revision != 3 {
		t.Fatalf("revision = %d, want 3", second.Revision)
	}
	if len(second.CustomFields) != 3 ||
		second.CustomFields["siguiente"] != "draft" ||
		second.CustomFields["resultado"] != "" ||
		second.CustomFields["ok"] != "yes" {
		t.Fatalf("merged custom fields = %v", second.CustomFields)
	}
	stored, err := e.s.GetWorkItem(e.ctx(), e.binding, item.ID)
	if err != nil || len(stored.CustomFields) != 3 {
		t.Fatalf("stored custom fields = %v (err %v)", stored.CustomFields, err)
	}
	var raw string
	if err := e.s.db.QueryRowContext(e.ctx(),
		`SELECT custom_fields FROM work_items WHERE id = ?`, string(item.ID)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if raw == "" || raw[0] != '{' {
		t.Fatalf("raw custom_fields = %q, want a JSON object", raw)
	}
}

// TestCheckCatchesInvalidCustomFields pins the new invariant: the JSON must be
// an object, and a broken value is reported instead of crashing every read.
func TestCheckCatchesInvalidCustomFields(t *testing.T) {
	e := newTestEnv(t)
	e.workItems(1, "broken")
	for _, bad := range []string{"not json", "[]", `"text"`} {
		e.mustExec(`UPDATE work_items SET custom_fields = ?`, bad)
		rep, err := e.s.Check(e.ctx(), &e.binding)
		if err != nil {
			t.Fatalf("Check(%s): %v", bad, err)
		}
		if rep.OK {
			t.Fatalf("Check with custom_fields %q reported OK", bad)
		}
		joined := strings.Join(rep.Errors, "\n")
		if !strings.Contains(joined, "custom fields") {
			t.Fatalf("Check(%q) errors = %s, want the custom fields message", bad, joined)
		}
	}
	e.mustExec(`UPDATE work_items SET custom_fields = '{}'`)
	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("Check after repair = %+v (err %v)", rep.Errors, err)
	}
}
