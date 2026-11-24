package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func buildPortableState(t *testing.T) (*testEnv, domain.Capture) {
	t.Helper()
	e := newTestEnv(t)
	c := e.capture("portable note", "k")
	items := e.mustProcess(c.ID, "p", 1, "alpha task", "beta task").WorkItems
	if _, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{
		Binding: e.binding, Key: "pl", Kind: domain.DailyPlan, Period: "2026-11-19",
		Items: []domain.PlanItem{
			{WorkItemID: items[0].ID, Role: domain.MITRole},
			{WorkItemID: items[1].ID, Role: domain.BigRockRole},
		},
	}, e.now); err != nil {
		t.Fatalf("CommitPlan: %v", err)
	}
	return e, c
}

func TestExportRestoreRoundTrip(t *testing.T) {
	src, cap := buildPortableState(t)
	dir := t.TempDir()
	one := filepath.Join(dir, "one.json")
	two := filepath.Join(dir, "two.json")
	if err := src.s.Export(src.ctx(), one); err != nil {
		t.Fatalf("Export: %v", err)
	}
	if err := src.s.Export(src.ctx(), two); err != nil {
		t.Fatalf("second Export: %v", err)
	}
	raw1, err := os.ReadFile(one)
	if err != nil {
		t.Fatal(err)
	}
	raw2, err := os.ReadFile(two)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw1) != string(raw2) {
		t.Fatal("two exports of the same database differ; row order must be deterministic")
	}
	var doc exportDoc
	if err := json.Unmarshal(raw1, &doc); err != nil {
		t.Fatalf("decode export: %v", err)
	}
	if doc.Format != "ztd-export" || doc.Version != 2 {
		t.Fatalf("export header = %q v%d", doc.Format, doc.Version)
	}
	if len(doc.Tables) != len(canonicalTables) {
		t.Fatalf("export has %d tables, want %d", len(doc.Tables), len(canonicalTables))
	}
	if len(doc.Tables["captures"]) != 1 || len(doc.Tables["work_items"]) != 2 || len(doc.Tables["plans"]) != 1 {
		t.Fatalf("unexpected export contents: captures %d work_items %d plans %d",
			len(doc.Tables["captures"]), len(doc.Tables["work_items"]), len(doc.Tables["plans"]))
	}

	// Restore into a fresh, empty database.
	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))
	report, err := dst.Restore(src.ctx(), one)
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if report.Tables["scopes"] != 2 || report.Tables["captures"] != 1 ||
		report.Tables["work_items"] != 2 || report.Tables["plans"] != 1 {
		t.Fatalf("restore report = %+v", report.Tables)
	}
	srcCounts := src.counts()
	dstCounts := (&testEnv{t: t, s: dst}).counts()
	if dstCounts != srcCounts {
		t.Fatalf("counts differ after round trip: src %v dst %v", srcCounts, dstCounts)
	}

	// The restored rows are identical, not merely equal in number.
	gotCap, err := dst.GetCapture(src.ctx(), src.binding, cap.ID)
	if err != nil {
		t.Fatalf("GetCapture on restored store: %v", err)
	}
	wantCap, err := src.s.GetCapture(src.ctx(), src.binding, cap.ID)
	if err != nil {
		t.Fatal(err)
	}
	mustJSONEqual(t, wantCap, gotCap, "restored capture")
	srcItems, err := src.s.ListWorkItems(src.ctx(), src.binding, domain.Next)
	if err != nil {
		t.Fatal(err)
	}
	dstItems, err := dst.ListWorkItems(src.ctx(), src.binding, domain.Next)
	if err != nil {
		t.Fatal(err)
	}
	mustJSONEqual(t, srcItems, dstItems, "restored work items")
	// Prepare reads the plan and its items back from the restored rows.
	brief, err := dst.Prepare(src.ctx(), src.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("Prepare on restored store: %v", err)
	}
	if brief.Plan == nil || len(brief.Plan.Items) != 2 || brief.Plan.Revision != 1 || len(brief.MITs) != 1 {
		t.Fatalf("restored plan brief: MITs %d %+v", len(brief.MITs), brief.Plan)
	}
	if rep, err := dst.Check(src.ctx(), &src.binding); err != nil || !rep.OK {
		t.Fatalf("check on restored store: %+v (err %v)", rep.Errors, err)
	}

	// A nonempty target is never overwritten.
	if _, err := dst.Restore(src.ctx(), one); !domain.Of(err, domain.DestinationNotEmpty) {
		t.Fatalf("second Restore: got %v, want destination_not_empty", err)
	}
}

func TestRestoreRejectsInvalidInput(t *testing.T) {
	src, _ := buildPortableState(t)
	dir := t.TempDir()
	valid := filepath.Join(dir, "valid.json")
	if err := src.s.Export(src.ctx(), valid); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(valid)
	if err != nil {
		t.Fatal(err)
	}
	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))

	if _, err := dst.Restore(src.ctx(), filepath.Join(dir, "missing.json")); !domain.Of(err, domain.IOError) {
		t.Fatalf("missing file: got %v, want io_error", err)
	}

	garbage := filepath.Join(dir, "garbage.json")
	if err := os.WriteFile(garbage, []byte("not json at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := dst.Restore(src.ctx(), garbage); !domain.Of(err, domain.UnsupportedFormat) {
		t.Fatalf("garbage file: got %v, want unsupported_format", err)
	}

	writeDoc := func(name string, doc exportDoc) string {
		t.Helper()
		b, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	if _, err := dst.Restore(src.ctx(), writeDoc("wrong-format.json",
		exportDoc{Format: "other", Version: 1, Tables: map[string][]map[string]any{}})); !domain.Of(err, domain.UnsupportedFormat) {
		t.Fatalf("wrong format: got %v, want unsupported_format", err)
	}
	if _, err := dst.Restore(src.ctx(), writeDoc("wrong-version.json",
		exportDoc{Format: "ztd-export", Version: 2, Tables: map[string][]map[string]any{}})); !domain.Of(err, domain.UnsupportedFormat) {
		t.Fatalf("wrong version: got %v, want unsupported_format", err)
	}
	if _, err := dst.Restore(src.ctx(), writeDoc("missing-table.json",
		exportDoc{Format: "ztd-export", Version: 1, Tables: map[string][]map[string]any{}})); !domain.Of(err, domain.UnsupportedFormat) {
		t.Fatalf("missing table: got %v, want unsupported_format", err)
	}
	complete := map[string][]map[string]any{}
	for _, tc := range canonicalTables {
		complete[tc.name] = []map[string]any{}
	}
	complete["bogus"] = []map[string]any{}
	if _, err := dst.Restore(src.ctx(), writeDoc("unknown-table.json",
		exportDoc{Format: "ztd-export", Version: 1, Tables: complete})); !domain.Of(err, domain.UnsupportedFormat) {
		t.Fatalf("unknown table: got %v, want unsupported_format", err)
	}

	// A row that breaks scope ownership fails validation and leaves the target
	// completely empty — no partial activation.
	var doc exportDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	doc.Tables["work_items"][0]["scope_id"] = "ghost"
	mutated := writeDoc("mutated.json", doc)
	if _, err := dst.Restore(src.ctx(), mutated); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("scope-owning row: got %v, want invalid_input", err)
	}
	for _, tc := range canonicalTables {
		if n := countRows(t, dst, tc.name); n != 0 {
			t.Fatalf("failed restore left %d rows in %s", n, tc.name)
		}
	}
}

// TestExportRestoreKeepsCustomFields proves the new column travels through the
// whole-table export and restore without a column list change.
func TestExportRestoreKeepsCustomFields(t *testing.T) {
	e := newTestEnv(t)
	item := e.workItems(1, "portable-fields")[0]
	moved, err := e.s.MoveWorkItem(e.ctx(), app.MoveWorkItemCmd{
		Binding: e.binding, Key: "pf-1", ID: item.ID, Target: domain.Someday,
		Text:   ptrStr("renamed title"),
		Fields: map[string]string{"siguiente": "draft section 2", "resultado": ""},
	}, e.now)
	if err != nil {
		t.Fatalf("MoveWorkItem: %v", err)
	}
	path := filepath.Join(t.TempDir(), "fields.json")
	if err := e.s.Export(e.ctx(), path); err != nil {
		t.Fatalf("Export: %v", err)
	}
	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))
	if _, err := dst.Restore(e.ctx(), path); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	got, err := dst.GetWorkItem(e.ctx(), e.binding, moved.ID)
	if err != nil {
		t.Fatalf("GetWorkItem on restored store: %v", err)
	}
	mustJSONEqual(t, moved, got, "restored work item with custom fields")
	if got.CustomFields["siguiente"] != "draft section 2" || got.CustomFields["resultado"] != "" {
		t.Fatalf("restored custom fields = %v", got.CustomFields)
	}
	if rep, err := dst.Check(e.ctx(), &e.binding); err != nil || !rep.OK {
		t.Fatalf("check on restored store: %+v (err %v)", rep.Errors, err)
	}
}

func TestSnapshotNeverOverwrites(t *testing.T) {
	e, _ := buildPortableState(t)
	out := filepath.Join(t.TempDir(), "snap.db")
	if err := e.s.Snapshot(e.ctx(), out); err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), "SQLite format 3") {
		t.Fatalf("snapshot is not a SQLite database (header %q)", raw[:16])
	}
	// The snapshot is itself a complete, openable store.
	snap := openTestStore(t, out)
	if n := countRows(t, snap, "captures"); n != 1 {
		t.Fatalf("snapshot captures = %d, want 1", n)
	}
	if err := e.s.Snapshot(e.ctx(), out); !domain.Of(err, domain.DestinationNotEmpty) {
		t.Fatalf("overwrite attempt: got %v, want destination_not_empty", err)
	}
	if err := e.s.Snapshot(e.ctx(), " "); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("empty path: got %v, want invalid_input", err)
	}
}

func TestCheckCatchesDeliberatelyBrokenRows(t *testing.T) {
	e, _ := buildPortableState(t)

	// A valid store passes first.
	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil {
		t.Fatalf("Check: %v", err)
	}
	if !rep.OK {
		t.Fatalf("healthy store reported errors: %v", rep.Errors)
	}

	// Break three invariants with direct SQL, none of which the schema blocks.
	e.mustExec(`INSERT INTO scopes (id, name, kind, created_at) VALUES ('other','other','personal',?)`, fmtTime(e.now))
	e.insertItem("T-19990505-001", "other", "outsider linked into the plan", domain.Next, e.now)
	e.mustExec(`INSERT INTO plan_items (plan_id, work_item_id, role, position)
		VALUES ('P-personal-daily-2026-11-19', 'T-19990505-001', 'batch', 9)`)
	e.insertItem("T-19990505-002", "personal", "created outside the command path", domain.Next, e.now)
	e.mustExec(`UPDATE work_items SET closed_at = ? WHERE id = 'T-19990505-002'`, fmtTime(e.now))

	rep, err = e.s.Check(e.ctx(), &e.binding)
	if err != nil {
		t.Fatalf("Check after breakage: %v", err)
	}
	if rep.OK {
		t.Fatal("broken store reported OK")
	}
	joined := strings.Join(rep.Errors, "\n")
	for _, want := range []string{
		"has no history events",
		"carries closure fields while not archived",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("check errors missing %q:\n%s", want, joined)
		}
	}
	// The unscoped check sees the same breakage.
	repAll, err := e.s.Check(e.ctx(), nil)
	if err != nil || repAll.OK {
		t.Fatalf("unscoped check = %+v (err %v)", repAll, err)
	}
}
