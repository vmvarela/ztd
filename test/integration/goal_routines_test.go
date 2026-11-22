package integration

import (
	"path/filepath"
	"testing"
)

type goalData struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type addedRoutineData struct {
	ID       string `json:"id"`
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	Cadence  string `json:"cadence"`
	Active   bool   `json:"active"`
	Revision int    `json:"revision"`
}

// TestGoalCompleteCancel drives goal set/complete/cancel end to end: the
// close returns the goal, `goal show` reports no active goal afterwards,
// repeating the same close is idempotent, the other terminal status is
// invalid_transition, a profile without a goal is not_found and check stays
// green.
func TestGoalCompleteCancel(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	run(t, db, "goal", "complete").wantErr(t, 1, "goal", "not_found")

	set := decode[goalData](t, run(t, db, "goal", "set", "--statement", "ship ZTD").wantOK(t, "goal set"))
	if set.Status != "active" {
		t.Fatalf("goal set status = %q, want active", set.Status)
	}

	done := decode[goalData](t, run(t, db, "goal", "complete").wantOK(t, "goal complete"))
	if done.ID != set.ID || done.Status != "completed" {
		t.Fatalf("goal complete = %+v, want %s completed", done, set.ID)
	}
	if raw := run(t, db, "goal", "show").wantOK(t, "goal show"); string(raw) != "null" {
		t.Fatalf("goal show after complete = %s, want null", raw)
	}

	again := decode[goalData](t, run(t, db, "goal", "complete").wantOK(t, "goal complete"))
	if again.ID != set.ID || again.Status != "completed" {
		t.Fatalf("second complete = %+v, want the same closed goal", again)
	}
	run(t, db, "goal", "cancel").wantErr(t, 1, "goal", "invalid_transition")

	second := decode[goalData](t, run(t, db, "goal", "set", "--statement", "second").wantOK(t, "goal set"))
	cancelled := decode[goalData](t, run(t, db, "goal", "cancel").wantOK(t, "goal cancel"))
	if cancelled.ID != second.ID || cancelled.Status != "cancelled" {
		t.Fatalf("goal cancel = %+v, want %s cancelled", cancelled, second.ID)
	}
	if raw := run(t, db, "goal", "show").wantOK(t, "goal show"); string(raw) != "null" {
		t.Fatalf("goal show after cancel = %s, want null", raw)
	}

	chk := decode[checkData](t, run(t, db, "check").wantOK(t, "check"))
	if !chk.OK {
		t.Fatalf("check after goal closes: %v", chk.Errors)
	}
}

func routineIDs(rs []addedRoutineData) []string {
	ids := make([]string, len(rs))
	for i, r := range rs {
		ids[i] = r.ID
	}
	return ids
}

// TestRoutinesAdd drives routines add/due/done end to end: daily and weekly
// rows are registered in the binding's primary scope and show up as due,
// completing one clears it, a duplicate id conflicts, invalid input is
// rejected before any write, and a routine of another scope stays invisible
// to a narrowed binding.
func TestRoutinesAdd(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	// Validation runs before any row exists.
	run(t, db, "routines", "add", "--id", "inbox", "--cadence", "monthly").
		wantErr(t, 1, "routines", "invalid_input")
	run(t, db, "routines", "add", "--id", "inbox", "--cadence", "daily", "--last", "someday").
		wantErr(t, 1, "routines", "invalid_input")
	run(t, db, "routines", "add", "--id", "", "--cadence", "daily").
		wantErr(t, 1, "routines", "invalid_input")

	inbox := decode[addedRoutineData](t, run(t, db, "routines", "add",
		"--id", "inbox", "--cadence", "daily").wantOK(t, "routines add"))
	if inbox.ID != "inbox" || inbox.Scope != "personal" || inbox.Kind != "routine" ||
		inbox.Cadence != "daily" || !inbox.Active || inbox.Revision != 1 {
		t.Fatalf("added daily routine = %+v", inbox)
	}
	review := decode[addedRoutineData](t, run(t, db, "routines", "add",
		"--id", "review", "--cadence", "weekly:mon").wantOK(t, "routines add"))
	if review.ID != "review" || review.Cadence != "weekly:mon" || review.Scope != "personal" {
		t.Fatalf("added weekly routine = %+v", review)
	}

	due := decode[[]addedRoutineData](t, run(t, db, "routines", "due").wantOK(t, "routines due"))
	if ids := routineIDs(due); len(ids) != 2 || ids[0] != "inbox" || ids[1] != "review" {
		t.Fatalf("due after adds = %v, want [inbox review]", ids)
	}

	run(t, db, "routines", "done", "inbox").wantOK(t, "routines done")
	due = decode[[]addedRoutineData](t, run(t, db, "routines", "due").wantOK(t, "routines due"))
	if ids := routineIDs(due); len(ids) != 1 || ids[0] != "review" {
		t.Fatalf("due after done = %v, want [review]", ids)
	}

	run(t, db, "routines", "add", "--id", "inbox", "--cadence", "daily").
		wantErr(t, 1, "routines", "conflict")

	// A routine added in another scope stays invisible to a personal-only
	// binding and is the only one visible to an opensource-only binding.
	osRoutine := decode[addedRoutineData](t, run(t, db, "routines", "add",
		"--id", "os-routine", "--cadence", "daily", "--scope", "opensource").wantOK(t, "routines add"))
	if osRoutine.Scope != "opensource" {
		t.Fatalf("opensource routine scope = %q, want opensource", osRoutine.Scope)
	}
	personalDue := decode[[]addedRoutineData](t, run(t, db, "routines", "due",
		"--scope", "personal").wantOK(t, "routines due"))
	if ids := routineIDs(personalDue); len(ids) != 1 || ids[0] != "review" {
		t.Fatalf("personal due = %v, want [review] without the opensource row", ids)
	}
	osDue := decode[[]addedRoutineData](t, run(t, db, "routines", "due",
		"--scope", "opensource").wantOK(t, "routines due"))
	if ids := routineIDs(osDue); len(ids) != 1 || ids[0] != "os-routine" {
		t.Fatalf("opensource due = %v, want [os-routine]", ids)
	}

	// The `routine add` alias drives the same command.
	run(t, db, "routine", "add", "--id", "alias-check", "--cadence", "daily").
		wantOK(t, "routines add")

	chk := decode[checkData](t, run(t, db, "check").wantOK(t, "check"))
	if !chk.OK {
		t.Fatalf("check after routine adds: %v", chk.Errors)
	}
}
