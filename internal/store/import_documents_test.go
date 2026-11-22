package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// docFixture writes the legacy copy used by the documents import tests: one
// file per classification rule, the store bookkeeping files that must be
// skipped silently, one unknown path, one invalid UTF-8 body, and project
// cards with Repositories tables in English and Spanish.
func docFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		// Classified documents.
		"knowledge/index.md":               "# Knowledge index\n\nEverything canonical.\n",
		"knowledge/opensource/setup.md":    "# Setup\n\nClone lives under repos/.\n",
		"reading/2026-11-19.md":            "# Reading note\n\n- a book\n",
		"goals/active.md":                  "# Active goals\n\n- ship the Go rewrite\n",
		"goals/archive.md":                 "# Archived goals\n\n- done\n",
		"lists/projects/opensource/ztd.md": "# ZTD\n\n- ID: opensource/ztd\n\n## Repositories\n\n| Name | Remote | Local path | Status |\n| --- | --- | --- | --- |\n| ztd | https://example.com/ztd.git | repos/opensource/ztd | active |\n",
		"lists/projects/familia/casa.md":   "# Casa\n\n## Repositorios\n\n| Nombre | Remoto | Ruta local | Estado |\n| --- | --- | --- | --- |\n| casa | https://example.com/casa.git | ../evil | active |\n",
		"lists/projects/salud/clinica.md":  "# Clinica\n\n## Repositories\n\n| Name | Remote | Local path | Status |\n| --- | --- | --- | --- |\n| clinica | https://example.com/clinica.git | clinicas/clinica | active |\n",
		"lists/projects/index.md":          "# Projects\n\n- opensource/ztd\n",
		"plans/daily/2026-11-19.md":        "# Daily plan\n\n- T-20261119-001\n",
		"plans/weekly/2026-W47.md":         "# Weekly plan\n",
		"reviews/trabajo/2026-W47.md":      "# Weekly review\n",
		"reviews/2026-11-14-weekly.md":     "# Weekly review\n",
		"journal/2026-11-19.md":            "# Journal\n",
		"calendar.md":                      "# Calendar\n",
		"adoption.md":                      "# Adoption\n",
		"passion.md":                       "# Passion\n",
		"routines/daily.md":                "# Daily routines\n",
		"routines/weekly.md":               "# Weekly routines\n",
		// Skipped with a warning: no document kind.
		"stray.md": "no heading, no place to go\n",
		// Skipped silently: store bookkeeping, never documents.
		"README.md":          "# legacy copy\n",
		"config.json":        `{"format": 2}`,
		"contexts.md":        "| Context |\n| --- |\n| familia |\n",
		"inbox.md":           "",
		"lists/next.md":      "",
		"lists/someday.md":   "",
		"routines/state.md":  "",
		".ztd-assets.json":   "{}",
		"ztd.db":             "not really sqlite",
		"templates/skill.md": "# template\n",
		".state/notes.md":    "pending work somewhere\n",
		".git/note.md":       "# not a document\n",
	}
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Classified, but never imported: invalid UTF-8 is refused, never guessed.
	invalid := []byte{'#', ' ', 'B', 'a', 'd', '\n', 0xff, 0xfe, 0x80, '\n'}
	if err := os.WriteFile(filepath.Join(root, "knowledge", "invalid.md"), invalid, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// docTestEnv is a fresh store with the two fixture projects declared: the
// opensource/ztd and familia/casa rows that receive repository fields.
type docTestEnv struct {
	*testEnv
	src       string
	workspace string
}

func newDocTestEnv(t *testing.T) *docTestEnv {
	t.Helper()
	e := newTestEnv(t)
	env := &docTestEnv{testEnv: e, src: docFixture(t), workspace: t.TempDir()}
	opensource := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: scopeIDList([]string{"opensource"})}
	if _, err := e.addProject(app.ProjectCmd{Binding: opensource, ID: "opensource/ztd", Status: "active"}); err != nil {
		t.Fatalf("AddProject(opensource/ztd): %v", err)
	}
	if _, err := e.addProject(app.ProjectCmd{Binding: e.binding, ID: "familia/casa", Status: "active"}); err != nil {
		t.Fatalf("AddProject(familia/casa): %v", err)
	}
	return env
}

func (e *docTestEnv) importDocs(dryRun bool) app.DocumentsImportReport {
	e.t.Helper()
	report, err := e.s.ImportDocuments(e.ctx(), app.ImportDocumentsCmd{
		Source: e.src, Workspace: e.workspace, DryRun: dryRun,
	}, e.now)
	if err != nil {
		e.t.Fatalf("ImportDocuments(dryRun=%v): %v", dryRun, err)
	}
	return report
}

// docBinding reaches every scope the fixture resolves into.
func docBinding() domain.ScopeBinding {
	return domain.ScopeBinding{
		Profile: "personal", Actor: "tester",
		Scopes: scopeIDList([]string{"personal", "opensource", "client:prisamedia", "salud"}),
	}
}

func wantWarnings(t *testing.T, warnings []string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		found := false
		for _, w := range warnings {
			if strings.Contains(w, want) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("warning %q missing from %v", want, warnings)
		}
	}
}

// TestImportDocumentsFixture pins the classification table, scope rules,
// titles, statuses, exact bodies, project repository extraction and the
// post-import check.
func TestImportDocumentsFixture(t *testing.T) {
	e := newDocTestEnv(t)

	report := e.importDocs(false)
	if report.Inserted != 19 || report.Updated != 0 || report.Unchanged != 0 || report.Skipped != 2 {
		t.Fatalf("report = %+v, want inserted=19 skipped=2", report)
	}
	if len(report.Warnings) != 4 {
		t.Fatalf("warnings = %v, want 4", report.Warnings)
	}
	wantWarnings(t, report.Warnings,
		"stray.md: no document kind",
		"knowledge/invalid.md: invalid UTF-8",
		`clone path "../evil" contains a .. segment`,
		"project salud/clinica not found")

	cases := []struct {
		kind, slug, scope, title string
	}{
		{"knowledge_index", "index", "personal", "Knowledge index"},
		{"knowledge", "opensource/setup", "opensource", "Setup"},
		{"knowledge", "reading/2026-11-19", "personal", "Reading note"},
		{"knowledge", "goals/active", "personal", "Active goals"},
		{"knowledge", "goals/archive", "personal", "Archived goals"},
		{"project_note", "opensource/ztd", "opensource", "ZTD"},
		{"project_note", "familia/casa", "personal", "Casa"},
		{"project_note", "salud/clinica", "salud", "Clinica"},
		{"project_note", "index", "personal", "Projects"},
		{"plan_daily", "2026-11-19", "personal", "Daily plan"},
		{"plan_weekly", "2026-W47", "personal", "Weekly plan"},
		{"review", "trabajo/2026-W47", "client:prisamedia", "Weekly review"},
		{"review", "2026-11-14-weekly", "personal", "Weekly review"},
		{"journal", "2026-11-19", "personal", "Journal"},
		{"calendar", "calendar", "personal", "Calendar"},
		{"adoption", "adoption", "personal", "Adoption"},
		{"passion", "passion", "personal", "Passion"},
		{"routine", "daily", "personal", "Daily routines"},
		{"routine", "weekly", "personal", "Weekly routines"},
	}
	for _, tc := range cases {
		d, err := e.s.GetDocument(e.ctx(), docBinding(), domain.DocumentKind(tc.kind), tc.slug)
		if err != nil {
			t.Errorf("GetDocument(%s/%s): %v", tc.kind, tc.slug, err)
			continue
		}
		if d.Scope != tc.scope || d.Title != tc.title {
			t.Errorf("%s/%s = scope %q title %q, want %q / %q",
				tc.kind, tc.slug, d.Scope, d.Title, tc.scope, tc.title)
		}
		if d.Status != domain.DocumentVerified || d.Revision != 1 {
			t.Errorf("%s/%s status %q revision %d, want verified 1", tc.kind, tc.slug, d.Status, d.Revision)
		}
	}

	// The body is the exact file bytes, heading included.
	d, err := e.s.GetDocument(e.ctx(), docBinding(), domain.DocumentKnowledge, "opensource/setup")
	if err != nil {
		t.Fatal(err)
	}
	if d.Body != "# Setup\n\nClone lives under repos/.\n" {
		t.Fatalf("body = %q", d.Body)
	}
	if n := e.count(`SELECT count(*) FROM documents`); n != 19 {
		t.Fatalf("documents = %d, want 19", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'document'`); n != 19 {
		t.Fatalf("document history = %d, want one event per document", n)
	}
	// Every resolved scope exists, so check stays green.
	if n := e.count(`SELECT count(*) FROM scopes`); n != 4 {
		t.Fatalf("scopes = %d, want personal, opensource, client:prisamedia, salud", n)
	}

	// Repository fields: filled from the table, relative path against the
	// workspace, ".." refused, missing project only warned about.
	ztd, err := e.s.GetProject(e.ctx(), docBinding(), "opensource/ztd")
	if err != nil {
		t.Fatal(err)
	}
	if ztd.RepoURL != "https://example.com/ztd.git" {
		t.Errorf("ztd repo_url = %q", ztd.RepoURL)
	}
	if want := filepath.Join(e.workspace, "repos/opensource/ztd"); ztd.ClonePath != want {
		t.Errorf("ztd clone_path = %q, want %q", ztd.ClonePath, want)
	}
	casa, err := e.s.GetProject(e.ctx(), docBinding(), "familia/casa")
	if err != nil {
		t.Fatal(err)
	}
	if casa.RepoURL != "https://example.com/casa.git" || casa.ClonePath != "" {
		t.Errorf("casa = url %q path %q, want the url and no path", casa.RepoURL, casa.ClonePath)
	}
	if _, err := e.s.GetProject(e.ctx(), docBinding(), "salud/clinica"); !domain.Of(err, domain.NotFound) {
		t.Errorf("clinica project err = %v, want not_found", err)
	}

	check, err := e.s.Check(e.ctx(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !check.OK {
		t.Fatalf("check errors: %v", check.Errors)
	}
}

// TestImportDocumentsRerunIdempotent proves a second run over the same copy
// is a no-op: every file unchanged, no new rows, no new history.
func TestImportDocumentsRerunIdempotent(t *testing.T) {
	e := newDocTestEnv(t)
	first := e.importDocs(false)
	if first.Inserted != 19 {
		t.Fatalf("first run inserted = %d, want 19", first.Inserted)
	}
	docs := e.count(`SELECT count(*) FROM documents`)
	history := e.count(`SELECT count(*) FROM history_events`)

	second := e.importDocs(false)
	if second.Inserted != 0 || second.Updated != 0 || second.Unchanged != 19 || second.Skipped != 2 {
		t.Fatalf("second run = %+v, want 19 unchanged", second)
	}
	if len(second.Warnings) != len(first.Warnings) {
		t.Fatalf("second warnings = %v, want the same %v", second.Warnings, first.Warnings)
	}
	if n := e.count(`SELECT count(*) FROM documents`); n != docs {
		t.Fatalf("documents after rerun = %d, want %d (no duplicates)", n, docs)
	}
	if n := e.count(`SELECT count(*) FROM history_events`); n != history {
		t.Fatalf("history after rerun = %d, want %d (no writes)", n, history)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'project'`); n != 4 {
		t.Fatalf("project history = %d, want 2 created + 2 imported updates", n)
	}
}

// TestImportDocumentsChangedBody updates only the file that changed, at the
// current revision, and leaves everything else alone.
func TestImportDocumentsChangedBody(t *testing.T) {
	e := newDocTestEnv(t)
	e.importDocs(false)

	changed := "# Setup\n\nClone lives under repos/, now documented.\n"
	if err := os.WriteFile(filepath.Join(e.src, "knowledge", "opensource", "setup.md"), []byte(changed), 0o644); err != nil {
		t.Fatal(err)
	}

	report := e.importDocs(false)
	if report.Inserted != 0 || report.Updated != 1 || report.Unchanged != 18 || report.Skipped != 2 {
		t.Fatalf("report = %+v, want exactly one update", report)
	}
	d, err := e.s.GetDocument(e.ctx(), docBinding(), domain.DocumentKnowledge, "opensource/setup")
	if err != nil {
		t.Fatal(err)
	}
	if d.Revision != 2 || d.Body != changed {
		t.Fatalf("document revision %d body %q, want revision 2 with the new body", d.Revision, d.Body)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'document'`); n != 20 {
		t.Fatalf("document history = %d, want 19 created + 1 updated", n)
	}
	if n := e.count(`SELECT count(*) FROM documents`); n != 19 {
		t.Fatalf("documents = %d, want 19", n)
	}
	check, err := e.s.Check(e.ctx(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !check.OK {
		t.Fatalf("check errors: %v", check.Errors)
	}
}

// TestImportDocumentsDryRun proves the plan is computed with the same reads
// but writes nothing: no documents, no scopes, no history, no project fields.
func TestImportDocumentsDryRun(t *testing.T) {
	e := newDocTestEnv(t)
	history := e.count(`SELECT count(*) FROM history_events`)
	scopes := e.count(`SELECT count(*) FROM scopes`)

	report := e.importDocs(true)
	if report.Inserted != 19 || report.Updated != 0 || report.Unchanged != 0 || report.Skipped != 2 {
		t.Fatalf("report = %+v, want planned inserted=19 skipped=2", report)
	}
	wantWarnings(t, report.Warnings, "stray.md", "knowledge/invalid.md")

	if n := e.count(`SELECT count(*) FROM documents`); n != 0 {
		t.Fatalf("documents after dry-run = %d, want 0", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events`); n != history {
		t.Fatalf("history after dry-run = %d, want %d", n, history)
	}
	if n := e.count(`SELECT count(*) FROM scopes`); n != scopes {
		t.Fatalf("scopes after dry-run = %d, want %d (no scope created)", n, scopes)
	}
	ztd, err := e.s.GetProject(e.ctx(), docBinding(), "opensource/ztd")
	if err != nil {
		t.Fatal(err)
	}
	if ztd.RepoURL != "" || ztd.ClonePath != "" || ztd.Revision != 1 {
		t.Fatalf("ztd after dry-run = %+v, want untouched revision 1", ztd)
	}
}

// TestImportDocumentsRefusesPendingJournal applies the same quiescence
// precondition as migrate import: a pending legacy journal stops the run
// before any read of the document files.
func TestImportDocumentsRefusesPendingJournal(t *testing.T) {
	e := newDocTestEnv(t)
	pending := filepath.Join(e.src, ".state", "pending.json")
	if err := os.WriteFile(pending, []byte(`{"op":"put"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := e.s.ImportDocuments(e.ctx(), app.ImportDocumentsCmd{Source: e.src, Workspace: e.workspace}, e.now)
	if !domain.Of(err, domain.PendingTransaction) {
		t.Fatalf("err = %v, want pending_transaction", err)
	}
	if n := e.count(`SELECT count(*) FROM documents`); n != 0 {
		t.Fatalf("documents = %d, want 0", n)
	}
}

// TestImportDocumentsMappingOverridesBuiltIn proves rule 1: a --mapping
// context entry wins over the built-in table, and the mapped scope is
// declared for the documents that land in it.
func TestImportDocumentsMappingOverridesBuiltIn(t *testing.T) {
	e := newDocTestEnv(t)
	mapping := filepath.Join(t.TempDir(), "mapping.json")
	body := `{"default_scope":"personal","contexts":{"trabajo":{"scope":"work"}}}`
	if err := os.WriteFile(mapping, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	report, err := e.s.ImportDocuments(e.ctx(), app.ImportDocumentsCmd{
		Source: e.src, MappingPath: mapping, Workspace: e.workspace,
	}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	if report.Inserted != 19 {
		t.Fatalf("inserted = %d, want 19", report.Inserted)
	}
	review, err := e.s.GetDocument(e.ctx(), domain.ScopeBinding{
		Profile: "personal", Actor: "tester",
		Scopes: scopeIDList([]string{"work"}),
	}, domain.DocumentReview, "trabajo/2026-W47")
	if err != nil {
		t.Fatal(err)
	}
	if review.Scope != "work" {
		t.Fatalf("review scope = %q, want work from the mapping", review.Scope)
	}
	// Built-in rules still apply to the keys the mapping does not claim.
	clinica, err := e.s.GetDocument(e.ctx(), docBinding(), domain.DocumentProjectNote, "salud/clinica")
	if err != nil {
		t.Fatal(err)
	}
	if clinica.Scope != "salud" {
		t.Fatalf("clinica scope = %q, want salud", clinica.Scope)
	}
	var kind string
	if err := e.s.db.QueryRow(`SELECT kind FROM scopes WHERE id = 'work'`).Scan(&kind); err != nil {
		t.Fatalf("work scope: %v", err)
	}
	if kind != "work" {
		t.Fatalf("work scope kind = %q, want work", kind)
	}
	check, err := e.s.Check(e.ctx(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !check.OK {
		t.Fatalf("check errors: %v", check.Errors)
	}
}

// TestImportDocumentsKeepsExistingRepoValues proves the fill-empty-only rule:
// a stored repository value that differs from the card is kept and reported,
// while the empty field is still filled.
func TestImportDocumentsKeepsExistingRepoValues(t *testing.T) {
	e := newDocTestEnv(t)
	if _, err := e.s.SetProjectRepo(e.ctx(), "opensource/ztd",
		"https://kept.example/ztd.git", "", e.now); err != nil {
		t.Fatal(err)
	}

	report := e.importDocs(false)
	wantWarnings(t, report.Warnings, "project opensource/ztd already has repo_url https://kept.example/ztd.git; keeping it")

	ztd, err := e.s.GetProject(e.ctx(), docBinding(), "opensource/ztd")
	if err != nil {
		t.Fatal(err)
	}
	if ztd.RepoURL != "https://kept.example/ztd.git" {
		t.Fatalf("repo_url = %q, want the stored value kept", ztd.RepoURL)
	}
	if want := filepath.Join(e.workspace, "repos/opensource/ztd"); ztd.ClonePath != want {
		t.Fatalf("clone_path = %q, want %q (the empty field is filled)", ztd.ClonePath, want)
	}
}

// TestSetProjectRepo covers the standalone write path: fill, idempotent
// replay, keep a different value, and the precondition errors.
func TestSetProjectRepo(t *testing.T) {
	e := newDocTestEnv(t)
	ctx := e.ctx()

	filled, err := e.s.SetProjectRepo(ctx, "familia/casa", "https://example.com/casa.git", "/abs/casa", e.now)
	if err != nil {
		t.Fatalf("SetProjectRepo: %v", err)
	}
	if filled.RepoURL != "https://example.com/casa.git" || filled.ClonePath != "/abs/casa" {
		t.Fatalf("filled = %+v", filled)
	}
	if filled.Revision != 2 {
		t.Fatalf("revision = %d, want 2", filled.Revision)
	}
	history := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'project' AND event = 'updated'`)
	if history != 1 {
		t.Fatalf("updated history = %d, want 1", history)
	}

	// The same values again: no write, no history.
	again, err := e.s.SetProjectRepo(ctx, "familia/casa", "https://example.com/casa.git", "/abs/casa", e.now)
	if err != nil {
		t.Fatalf("SetProjectRepo replay: %v", err)
	}
	if again.Revision != 2 {
		t.Fatalf("replay revision = %d, want 2", again.Revision)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'project' AND event = 'updated'`); n != 1 {
		t.Fatalf("updated history after replay = %d, want 1", n)
	}

	// A different value is kept, never overwritten.
	kept, err := e.s.SetProjectRepo(ctx, "familia/casa", "https://other.example/casa.git", "/other", e.now)
	if err != nil {
		t.Fatalf("SetProjectRepo conflict: %v", err)
	}
	if kept.RepoURL != "https://example.com/casa.git" || kept.ClonePath != "/abs/casa" {
		t.Fatalf("kept = %+v, want the original values", kept)
	}

	if _, err := e.s.SetProjectRepo(ctx, "familia/casa", "no-scheme", "", e.now); !domain.Of(err, domain.InvalidInput) {
		t.Errorf("bad url err = %v, want invalid_input", err)
	}
	if _, err := e.s.SetProjectRepo(ctx, "missing/project", "https://example.com/x.git", "", e.now); !domain.Of(err, domain.NotFound) {
		t.Errorf("missing project err = %v, want not_found", err)
	}
}
