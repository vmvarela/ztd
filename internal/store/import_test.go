package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func fixtureCopy(t *testing.T) string {
	t.Helper()
	src := filepath.Join("..", "..", "test", "fixtures", "legacy")
	dst := filepath.Join(t.TempDir(), "legacy")
	copyTree(t, src, dst)
	return dst
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	info, err := os.Stat(src)
	if err != nil {
		t.Fatal(err)
	}
	if info.IsDir() {
		if err := os.MkdirAll(dst, 0o755); err != nil {
			t.Fatal(err)
		}
		entries, err := os.ReadDir(src)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			copyTree(t, filepath.Join(src, e.Name()), filepath.Join(dst, e.Name()))
		}
		return
	}
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func importCommand(root string) app.ImportCmd {
	return app.ImportCmd{
		SourceCopy:    root,
		AgentExport:   filepath.Join(root, "agent-export.json"),
		LegacyCheck:   "ok",
		LegacyVersion: "2",
		Actor:         "tester",
	}
}

func TestImportFixtureIntoEmptyStore(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	report, err := st.Import(ctx, importCommand(src), time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if report.Imported != 19 || report.Quarantined != 0 {
		t.Fatalf("unexpected dispositions: imported=%d quarantined=%d", report.Imported, report.Quarantined)
	}
	check, err := st.Check(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !check.OK {
		t.Fatalf("check failed: %v", check.Errors)
	}
	for table, want := range map[string]int{
		"work_items": 4, "captures": 2, "plans": 2, "plan_items": 3,
		"routines": 2, "documents": 1, "legacy_records": 19,
	} {
		var n int
		if err := st.db.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != want {
			t.Errorf("%s rows = %d, want %d", table, n, want)
		}
	}
	var legacySourced int
	if err := st.db.QueryRowContext(ctx, "SELECT count(*) FROM captures WHERE source_id = ?", domain.LegacySourceID).Scan(&legacySourced); err != nil {
		t.Fatal(err)
	}
	if legacySourced != 2 {
		t.Fatalf("captures with internal legacy provenance = %d, want 2", legacySourced)
	}
	personal := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal", "opensource"}}
	items, err := st.ListWorkItems(ctx, personal, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 3 {
		t.Fatalf("personal items = %d, want 3", len(items))
	}
	if _, err := st.GetWorkItem(ctx, personal, "T-20261118-003"); !domain.Of(err, domain.ScopeDenied) && !domain.Of(err, domain.NotFound) {
		t.Fatalf("cross-scope read = %v, want scope_denied or not_found", err)
	}
}

// TestImportKeepsLegacyCustomFields proves the reserved routing and lifecycle
// fields land in their columns while every other legacy field survives in
// custom_fields instead of being dropped.
func TestImportKeepsLegacyCustomFields(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.Import(ctx, importCommand(src), time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	all := domain.ScopeBinding{Profile: "personal", Actor: "tester",
		Scopes: []domain.ScopeID{"personal", "opensource", "client:acme"}}
	items, err := st.ListWorkItems(ctx, all, "")
	if err != nil {
		t.Fatal(err)
	}
	byID := map[domain.WorkItemID]domain.WorkItem{}
	for _, it := range items {
		byID[it.ID] = it
	}

	archived, ok := byID["T-20261026-006"]
	if !ok {
		t.Fatalf("archived task missing, got %v", idsOf(items))
	}
	if archived.CustomFields["resultado"] != "renewed" {
		t.Fatalf("archived custom fields = %v, want resultado=renewed", archived.CustomFields)
	}
	for _, reserved := range []string{"context", "captured_at", "closed_at", "resolution"} {
		if _, dup := archived.CustomFields[reserved]; dup {
			t.Fatalf("reserved key %q leaked into custom fields: %v", reserved, archived.CustomFields)
		}
	}
	if archived.Resolution != "done at counter" || archived.WaitingOn != "" {
		t.Fatalf("archived columns = resolution %q waiting_on %q", archived.Resolution, archived.WaitingOn)
	}

	next, ok := byID["T-20261118-003"]
	if !ok {
		t.Fatalf("next task missing, got %v", idsOf(items))
	}
	if next.CustomFields["siguiente"] != "draft section 2" {
		t.Fatalf("next custom fields = %v, want siguiente=draft section 2", next.CustomFields)
	}
	for _, reserved := range []string{"context", "client", "project", "captured_at"} {
		if _, dup := next.CustomFields[reserved]; dup {
			t.Fatalf("reserved key %q leaked into custom fields: %v", reserved, next.CustomFields)
		}
	}

	waiting, ok := byID["T-20261118-004"]
	if !ok {
		t.Fatalf("waiting task missing, got %v", idsOf(items))
	}
	if waiting.WaitingOn == "" || len(waiting.CustomFields) != 0 {
		t.Fatalf("waiting task = waiting_on %q custom fields %v", waiting.WaitingOn, waiting.CustomFields)
	}

	// The legacy payload still carries every original field.
	var payload string
	if err := st.db.QueryRowContext(ctx,
		`SELECT payload_json FROM legacy_records WHERE entity_type = 'task' AND entity_id = 'T-20261118-003'`).
		Scan(&payload); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"siguiente", "captured_at", "work/acme/demo", "acme"} {
		if !strings.Contains(payload, want) {
			t.Fatalf("legacy payload lost %q: %s", want, payload)
		}
	}
	if rep, err := st.Check(ctx, nil); err != nil || !rep.OK {
		t.Fatalf("check after import: %+v (err %v)", rep.Errors, err)
	}
}

func TestImportInfersProjectContextFromID(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	path := filepath.Join(src, "lists", "projects", "work", "acme", "demo.md")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	without := strings.Replace(string(b), "- Context: work\n", "", 1)
	if without == string(b) {
		t.Fatal("fixture project has no Context line to remove")
	}
	if err := os.WriteFile(path, []byte(without), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	report, err := st.Import(ctx, importCommand(src), time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if report.Quarantined != 0 {
		t.Fatalf("project without Context was quarantined: %+v", report.Dispositions)
	}
	var scope string
	if err := st.db.QueryRowContext(ctx,
		"SELECT scope_id FROM projects WHERE id = 'work/acme/demo'").Scan(&scope); err != nil {
		t.Fatal(err)
	}
	if scope != "client:acme" {
		t.Fatalf("project scope = %q, want client:acme", scope)
	}
}

func TestImportRequiresLegacyCheck(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cmd := importCommand(fixtureCopy(t))
	cmd.LegacyCheck = ""
	_, err = st.Import(ctx, cmd, time.Now().UTC())
	if !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("err = %v, want invalid_input", err)
	}
}

func TestImportSameSourceReplaysReport(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cmd := importCommand(src)
	first, err := st.Import(ctx, cmd, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	second, err := st.Import(ctx, cmd, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if second.SourceHash != first.SourceHash || second.Imported != first.Imported {
		t.Fatalf("replay differs: %+v vs %+v", second, first)
	}
	var n int
	if err := st.db.QueryRowContext(ctx, "SELECT count(*) FROM legacy_records").Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 19 {
		t.Fatalf("legacy rows after replay = %d, want 19", n)
	}
}

func TestImportRejectsNonEmptyTargetForDifferentSource(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.Import(ctx, importCommand(src), time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	other := fixtureCopy(t)
	if err := os.WriteFile(filepath.Join(other, "inbox.md"), []byte("# Inbox\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err = st.Import(ctx, importCommand(other), time.Now().UTC())
	if !domain.Of(err, domain.DestinationNotEmpty) {
		t.Fatalf("err = %v, want destination_not_empty", err)
	}
}

func TestImportQuarantinesMalformedTask(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	path := filepath.Join(src, "inbox.md")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	b = append(b, []byte("- [ ] T-20261119-009 | bad context | context: unknown\n")...)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	report, err := st.Import(ctx, importCommand(src), time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if report.Quarantined != 1 {
		t.Fatalf("quarantined = %d, want 1", report.Quarantined)
	}
	var reason, original string
	if err := st.db.QueryRowContext(ctx,
		`SELECT reason, payload_json FROM legacy_records
		 WHERE entity_type = 'task' AND entity_id = 'T-20261119-009' AND disposition = 'quarantined'`).
		Scan(&reason, &original); err != nil {
		t.Fatal(err)
	}
	if reason == "" || !strings.Contains(original, "unknown") {
		t.Fatalf("quarantine lost evidence: reason=%q original=%q", reason, original)
	}
}

func TestImportVerifyDetectsChangedSource(t *testing.T) {
	ctx := context.Background()
	src := fixtureCopy(t)
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.Import(ctx, importCommand(src), time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := st.VerifyImport(ctx, importCommand(src)); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(src, "inbox.md"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "inbox.md"), append(b, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := st.VerifyImport(ctx, importCommand(src)); !domain.Of(err, domain.NotFound) {
		t.Fatalf("err = %v, want not_found for changed source", err)
	}
}

func TestImportDoesNotNeedWriteAccessToSource(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	ctx := context.Background()
	src := fixtureCopy(t)
	var dirs []string
	if err := filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			dirs = append(dirs, path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for _, d := range dirs {
		if err := os.Chmod(d, 0o555); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, d := range dirs {
			_ = os.Chmod(d, 0o755)
		}
	})
	st, err := Open(filepath.Join(t.TempDir(), "ztd.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.Import(ctx, importCommand(src), time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
}
