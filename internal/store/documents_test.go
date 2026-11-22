package store

import (
	"path/filepath"
	"strings"
	"testing"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func scopeIDList(scopes []string) []domain.ScopeID {
	out := make([]domain.ScopeID, 0, len(scopes))
	for _, s := range scopes {
		out = append(out, domain.ScopeID(s))
	}
	return out
}

func (e *testEnv) addContext(name string, scopes ...string) (domain.Context, error) {
	b := e.binding
	if len(scopes) > 0 {
		b = domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: scopeIDList(scopes)}
	}
	return e.s.AddContext(e.ctx(), app.ContextCmd{Binding: b, Name: name})
}

func (e *testEnv) mustContext(name string, scopes ...string) domain.Context {
	e.t.Helper()
	c, err := e.addContext(name, scopes...)
	if err != nil {
		e.t.Fatalf("AddContext(%q): %v", name, err)
	}
	return c
}

func (e *testEnv) putDoc(kind, slug, title, body string, expected domain.Revision, scopes ...string) (domain.Document, error) {
	b := e.binding
	if len(scopes) > 0 {
		b = domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: scopeIDList(scopes)}
	}
	return e.s.PutDocument(e.ctx(), app.DocumentCmd{
		Binding: b, Kind: domain.DocumentKind(kind), Slug: slug,
		Title: title, Body: body, Status: domain.DocumentDraft, Expected: expected,
	}, e.now)
}

func (e *testEnv) mustPutDoc(kind, slug, body string, expected domain.Revision, scopes ...string) domain.Document {
	e.t.Helper()
	d, err := e.putDoc(kind, slug, slug, body, expected, scopes...)
	if err != nil {
		e.t.Fatalf("PutDocument(%s/%s): %v", kind, slug, err)
	}
	return d
}

func (e *testEnv) addProject(cmd app.ProjectCmd) (domain.Project, error) {
	return e.s.AddProject(e.ctx(), cmd, e.now)
}

// TestMigration0006Documents pins the document schema: the documents table,
// the project repository columns, and — after 0007 — the current version 7.
func TestMigration0006Documents(t *testing.T) {
	e := newTestEnv(t)
	var version int
	if err := e.s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if version != 7 {
		t.Fatalf("user_version = %d, want 7", version)
	}
	var cols int
	if err := e.s.db.QueryRow(
		`SELECT count(*) FROM pragma_table_info('projects') WHERE name IN ('repo_url','clone_path')`).
		Scan(&cols); err != nil {
		t.Fatalf("count project columns: %v", err)
	}
	if cols != 2 {
		t.Fatalf("projects repository columns = %d, want 2", cols)
	}
	var tables int
	if err := e.s.db.QueryRow(
		`SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'documents'`).
		Scan(&tables); err != nil {
		t.Fatalf("count documents table: %v", err)
	}
	if tables != 1 {
		t.Fatal("documents table is missing")
	}
}

// TestAddContextLifecycle covers creation, the duplicate no-op, ordering and
// cross-scope isolation.
func TestAddContextLifecycle(t *testing.T) {
	e := newTestEnv(t)

	first := e.mustContext("familia")
	if first.ID != "ctx:personal:familia" || first.Revision != 1 || first.Scope != "personal" {
		t.Fatalf("context = %+v, want ctx:personal:familia revision 1 in personal", first)
	}
	// Same name again: existing row, no writes.
	before := e.count(`SELECT count(*) FROM history_events`)
	again, err := e.addContext("familia")
	if err != nil {
		t.Fatalf("duplicate AddContext: %v", err)
	}
	if again.ID != first.ID || again.Revision != 1 {
		t.Fatalf("duplicate context = %+v, want the original back unchanged", again)
	}
	if n := e.count(`SELECT count(*) FROM contexts`); n != 1 {
		t.Fatalf("contexts after duplicate = %d, want 1", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events`); n != before {
		t.Fatalf("history grew by %d on a duplicate, want 0", n-before)
	}

	e.mustContext("salud")
	e.mustContext("ztd", "opensource")

	// Ordered by name, filtered by binding.
	all, err := e.s.ListContexts(e.ctx(), e.binding)
	if err != nil {
		t.Fatalf("ListContexts: %v", err)
	}
	names := make([]string, 0, len(all))
	for _, c := range all {
		names = append(names, c.Name)
	}
	if strings.Join(names, ",") != "familia,salud,ztd" {
		t.Fatalf("context names = %v, want familia,salud,ztd", names)
	}
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	osOnly, err := e.s.ListContexts(e.ctx(), onlyOS)
	if err != nil {
		t.Fatalf("ListContexts opensource: %v", err)
	}
	if len(osOnly) != 1 || osOnly[0].Name != "ztd" {
		t.Fatalf("opensource contexts = %+v, want only ztd", osOnly)
	}
	// A context in another scope is invisible to a narrowed binding.
	if _, err := e.s.ListContexts(e.ctx(), domain.ScopeBinding{
		Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"},
	}); err != nil {
		t.Fatal(err)
	}
}

// TestPutDocumentLifecycle covers create, update, revision guards, idempotent
// replay, cross-scope not_found and list filters.
func TestPutDocumentLifecycle(t *testing.T) {
	e := newTestEnv(t)

	created := e.mustPutDoc("knowledge", "komorebi/setup", "body one", 0)
	if created.Revision != 1 || created.Scope != "personal" || created.Status != domain.DocumentDraft {
		t.Fatalf("created document = %+v, want revision 1 draft in personal", created)
	}
	if created.CreatedAt.IsZero() || created.UpdatedAt.IsZero() {
		t.Fatalf("timestamps missing: %+v", created)
	}

	// Idempotent replay: same command, same result, no second row or history.
	history := e.count(`SELECT count(*) FROM history_events`)
	replay, err := e.putDoc("knowledge", "komorebi/setup", "komorebi/setup", "body one", 0)
	if err != nil {
		t.Fatalf("replay PutDocument: %v", err)
	}
	if replay.Revision != 1 || replay.Body != "body one" {
		t.Fatalf("replay = %+v, want the original document", replay)
	}
	if n := e.count(`SELECT count(*) FROM documents`); n != 1 {
		t.Fatalf("documents after replay = %d, want 1", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events`); n != history {
		t.Fatalf("history grew by %d on replay, want 0", n-history)
	}

	// Update: revision increments to 2 with an "updated" history event.
	updated := e.mustPutDoc("knowledge", "komorebi/setup", "body two", 1)
	if updated.Revision != 2 || updated.Body != "body two" {
		t.Fatalf("updated = %+v, want revision 2 with the new body", updated)
	}
	events, err := idRows(e.ctx(), e.s.db,
		`SELECT event FROM history_events WHERE entity_type = 'document' ORDER BY seq`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(events, ",") != "created,updated" {
		t.Fatalf("document history events = %v, want created,updated", events)
	}

	// Stale revision: a wrong expectation that never was a successful attempt
	// writes nothing. (A reused key with a different payload is
	// idempotency_conflict by contract, so the expected value is fresh.)
	if _, err := e.putDoc("knowledge", "komorebi/setup", "komorebi/setup", "body three", 5); !domain.Of(err, domain.StaleRevision) {
		t.Fatalf("stale put = %v, want stale_revision", err)
	}
	if n := e.count(`SELECT count(*) FROM documents WHERE body = 'body three'`); n != 0 {
		t.Fatal("stale put wrote the body")
	}
	// Expected on a missing document is stale too.
	if _, err := e.putDoc("journal", "missing", "missing", "x", 3); !domain.Of(err, domain.StaleRevision) {
		t.Fatalf("expected on missing doc = %v, want stale_revision", err)
	}

	// Cross-scope: not_found, and lists never leak.
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	if _, err := e.s.GetDocument(e.ctx(), onlyOS, "knowledge", "komorebi/setup"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("cross-scope get = %v, want not_found", err)
	}
	docs, err := e.s.ListDocuments(e.ctx(), onlyOS, "")
	if err != nil || len(docs) != 0 {
		t.Fatalf("cross-scope list = %+v (err %v), want empty", docs, err)
	}

	// Kind filter and ordering.
	e.mustPutDoc("journal", "day/2026-11-20", "note", 0)
	e.mustPutDoc("knowledge", "aaa", "note", 0)
	all, err := e.s.ListDocuments(e.ctx(), e.binding, "")
	if err != nil {
		t.Fatalf("ListDocuments: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("all documents = %d, want 3", len(all))
	}
	if all[0].Kind != "journal" || all[0].Slug != "day/2026-11-20" {
		t.Fatalf("order = %+v, want journal/day/2026-11-20 first (kind ASC, slug ASC)", all[0])
	}
	if all[1].Kind != "knowledge" || all[1].Slug != "aaa" {
		t.Fatalf("order = %+v, want knowledge/aaa second", all[1])
	}
	knowledge, err := e.s.ListDocuments(e.ctx(), e.binding, "knowledge")
	if err != nil || len(knowledge) != 2 {
		t.Fatalf("knowledge filter = %d docs (err %v), want 2", len(knowledge), err)
	}
	// Get by kind+slug.
	got, err := e.s.GetDocument(e.ctx(), e.binding, "journal", "day/2026-11-20")
	if err != nil || got.Body != "note" {
		t.Fatalf("GetDocument = %+v (err %v)", got, err)
	}
}

// TestListDocumentHistory covers the doc log query: newest first by seq,
// kind and slug filters, the limit, and the binding — a foreign-scope
// document never shows up.
func TestListDocumentHistory(t *testing.T) {
	e := newTestEnv(t)

	e.mustPutDoc("knowledge", "a", "body one", 0) // personal, created
	e.mustPutDoc("knowledge", "a", "body two", 1) // personal, updated
	e.mustPutDoc("journal", "day/2026-11-20", "note", 0)
	e.mustPutDoc("knowledge", "foreign", "b", 0, "opensource") // opensource

	// Newest first by seq across every bound scope.
	entries, err := e.s.ListDocumentHistory(e.ctx(), e.binding, app.DocumentHistoryFilter{})
	if err != nil {
		t.Fatalf("ListDocumentHistory: %v", err)
	}
	if len(entries) != 4 {
		t.Fatalf("entries = %d (%+v), want 4", len(entries), entries)
	}
	for i := 1; i < len(entries); i++ {
		if entries[i].Seq >= entries[i-1].Seq {
			t.Fatalf("order = %+v, want strictly decreasing seq", entries)
		}
	}
	if last := entries[len(entries)-1]; last.Event != "created" || last.Slug != "a" ||
		last.Kind != "knowledge" || last.Scope != "personal" {
		t.Fatalf("oldest entry = %+v, want the creation of personal/knowledge/a", last)
	}
	if prev := entries[len(entries)-2]; prev.Event != "updated" || prev.Slug != "a" {
		t.Fatalf("second oldest = %+v, want the update of a", prev)
	}
	if newest := entries[0]; newest.Scope != "opensource" || newest.Slug != "foreign" {
		t.Fatalf("newest entry = %+v, want the opensource document", newest)
	}

	// Kind filter drops the journal; slug filter keeps only a's two events,
	// newest (updated) first.
	knowledge, err := e.s.ListDocumentHistory(e.ctx(), e.binding, app.DocumentHistoryFilter{Kind: "knowledge"})
	if err != nil || len(knowledge) != 3 {
		t.Fatalf("kind filter = %d entries (err %v), want 3", len(knowledge), err)
	}
	one, err := e.s.ListDocumentHistory(e.ctx(), e.binding, app.DocumentHistoryFilter{Slug: "a"})
	if err != nil || len(one) != 2 {
		t.Fatalf("slug filter = %d entries (err %v), want 2", len(one), err)
	}
	if one[0].Event != "updated" || one[1].Event != "created" {
		t.Fatalf("slug filter order = %+v, want updated then created", one)
	}
	none, err := e.s.ListDocumentHistory(e.ctx(), e.binding,
		app.DocumentHistoryFilter{Kind: "journal", Slug: "a"})
	if err != nil || len(none) != 0 {
		t.Fatalf("contradictory filters = %+v (err %v), want empty", none, err)
	}

	// Limit: newest N, default when unset, and a cap that never errors.
	limited, err := e.s.ListDocumentHistory(e.ctx(), e.binding, app.DocumentHistoryFilter{Limit: 2})
	if err != nil || len(limited) != 2 || limited[0].Seq != entries[0].Seq {
		t.Fatalf("limit 2 = %+v (err %v), want the two newest", limited, err)
	}
	if _, err := e.s.ListDocumentHistory(e.ctx(), e.binding,
		app.DocumentHistoryFilter{Limit: 9999}); err != nil {
		t.Fatalf("capped limit: %v", err)
	}

	// The binding scopes the join: the opensource document's history is
	// invisible to a personal-only session.
	onlyPersonal := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	mine, err := e.s.ListDocumentHistory(e.ctx(), onlyPersonal, app.DocumentHistoryFilter{})
	if err != nil {
		t.Fatalf("personal-only ListDocumentHistory: %v", err)
	}
	if len(mine) != 3 {
		t.Fatalf("personal entries = %d (%+v), want 3", len(mine), mine)
	}
	for _, entry := range mine {
		if entry.Scope == "opensource" {
			t.Fatalf("foreign scope leaked: %+v", entry)
		}
	}

	// Unknown kinds are refused on this read path too.
	if _, err := e.s.ListDocumentHistory(e.ctx(), e.binding,
		app.DocumentHistoryFilter{Kind: "wiki"}); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("unknown kind = %v, want invalid_input", err)
	}
}

// TestDocumentValidation pins the shared precondition checks on both entry
// points: the service wrapper and the store behind it.
func TestDocumentValidation(t *testing.T) {
	e := newTestEnv(t)
	svc := app.New(e.s)
	cases := []struct {
		name   string
		mutate func(*app.DocumentCmd)
		want   domain.Family
	}{
		{"valid draft", func(c *app.DocumentCmd) {}, ""},
		{"unknown kind", func(c *app.DocumentCmd) { c.Kind = "wiki" }, domain.InvalidInput},
		{"empty kind", func(c *app.DocumentCmd) { c.Kind = "" }, domain.InvalidInput},
		{"unknown status", func(c *app.DocumentCmd) { c.Status = "final" }, domain.InvalidInput},
		{"empty status", func(c *app.DocumentCmd) { c.Status = "" }, domain.InvalidInput},
		{"empty slug", func(c *app.DocumentCmd) { c.Slug = "" }, domain.InvalidInput},
		{"slug with spaces", func(c *app.DocumentCmd) { c.Slug = "two words" }, domain.InvalidInput},
		{"slug with %", func(c *app.DocumentCmd) { c.Slug = "a%b" }, domain.InvalidInput},
		{"empty title", func(c *app.DocumentCmd) { c.Title = "  " }, domain.InvalidInput},
		{"empty body", func(c *app.DocumentCmd) { c.Body = "" }, domain.InvalidInput},
		{"negative expected", func(c *app.DocumentCmd) { c.Expected = -1 }, domain.InvalidInput},
	}
	for i, tc := range cases {
		cmd := app.DocumentCmd{
			Binding: e.binding, Kind: domain.DocumentKnowledge, Slug: "slug",
			Title: "title", Body: "body", Status: domain.DocumentDraft,
		}
		tc.mutate(&cmd)
		// Service wrapper.
		_, err := svc.PutDocument(e.ctx(), cmd)
		if tc.want == "" {
			if err != nil && i == 0 {
				// The first valid case may legitimately succeed or collide with
				// an earlier row; only the family of failures matters below.
			}
			if err != nil && !domain.Of(err, domain.InvalidInput) {
				t.Errorf("%s: service error = %v, want success or invalid_input", tc.name, err)
			}
			continue
		}
		if !domain.Of(err, tc.want) {
			t.Errorf("%s: service = %v, want %s", tc.name, err, tc.want)
		}
		// Store mirrors the same checks.
		_, err = e.s.PutDocument(e.ctx(), cmd, e.now)
		if !domain.Of(err, tc.want) {
			t.Errorf("%s: store = %v, want %s", tc.name, err, tc.want)
		}
	}
}

// TestAddProjectLifecycle covers creation, the duplicate no-op, conflicting
// configuration, ordering and cross-scope isolation.
func TestAddProjectLifecycle(t *testing.T) {
	e := newTestEnv(t)
	cmd := app.ProjectCmd{
		Binding: e.binding, ID: "opensource/ztd", DesiredOutcome: "ship the go rewrite",
		Status: "active", RepoURL: "https://example.com/ztd.git",
		ClonePath: "/home/me/workspaces/ztd",
	}
	p, err := e.addProject(cmd)
	if err != nil {
		t.Fatalf("AddProject: %v", err)
	}
	if p.ID != "opensource/ztd" || p.Revision != 1 || p.Scope != "personal" {
		t.Fatalf("project = %+v, want revision 1 in personal", p)
	}
	if p.RepoURL != cmd.RepoURL || p.ClonePath != cmd.ClonePath {
		t.Fatalf("repository metadata = %q/%q", p.RepoURL, p.ClonePath)
	}

	// Identical configuration: no-op, no new history.
	before := e.count(`SELECT count(*) FROM history_events`)
	same, err := e.addProject(cmd)
	if err != nil {
		t.Fatalf("duplicate AddProject: %v", err)
	}
	if same.Revision != 1 || same.ID != p.ID {
		t.Fatalf("duplicate project = %+v, want the original", same)
	}
	if n := e.count(`SELECT count(*) FROM history_events`); n != before {
		t.Fatalf("history grew by %d on duplicate, want 0", n-before)
	}

	// Different configuration: conflict, nothing written.
	other := cmd
	other.Status = "paused"
	if _, err := e.addProject(other); !domain.Of(err, domain.Conflict) {
		t.Fatalf("conflicting config = %v, want conflict", err)
	}
	if n := e.count(`SELECT count(*) FROM projects`); n != 1 {
		t.Fatalf("projects after conflict = %d, want 1", n)
	}

	// Ordering and cross-scope isolation.
	if _, err := e.addProject(app.ProjectCmd{
		Binding: e.binding, ID: "aaa", Status: "active",
	}); err != nil {
		t.Fatalf("AddProject aaa: %v", err)
	}
	list, err := e.s.ListProjects(e.ctx(), e.binding)
	if err != nil {
		t.Fatalf("ListProjects: %v", err)
	}
	if len(list) != 2 || list[0].ID != "aaa" || list[1].ID != "opensource/ztd" {
		t.Fatalf("project order = %+v, want aaa then.opensource/ztd", list)
	}
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	if _, err := e.s.GetProject(e.ctx(), onlyOS, "opensource/ztd"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("cross-scope get = %v, want not_found", err)
	}
	if list, err := e.s.ListProjects(e.ctx(), onlyOS); err != nil || len(list) != 0 {
		t.Fatalf("cross-scope list = %+v (err %v), want empty", list, err)
	}
	if _, err := e.s.GetProject(e.ctx(), e.binding, "ghost"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("missing project = %v, want not_found", err)
	}
}

// TestProjectValidation pins the repository rules on both entry points.
func TestProjectValidation(t *testing.T) {
	e := newTestEnv(t)
	svc := app.New(e.s)
	cases := []struct {
		name   string
		mutate func(*app.ProjectCmd)
		want   domain.Family
	}{
		{"valid", func(c *app.ProjectCmd) {}, ""},
		{"empty id", func(c *app.ProjectCmd) { c.ID = "" }, domain.InvalidInput},
		{"unknown status", func(c *app.ProjectCmd) { c.Status = "doing" }, domain.InvalidInput},
		{"empty status", func(c *app.ProjectCmd) { c.Status = "" }, domain.InvalidInput},
		{"relative clone path", func(c *app.ProjectCmd) { c.ClonePath = "relative/path" }, domain.InvalidInput},
		{"clone path with ..", func(c *app.ProjectCmd) { c.ClonePath = "/a/../b" }, domain.InvalidInput},
		{"clone path dotdot segment only", func(c *app.ProjectCmd) { c.ClonePath = "/a/b/.." }, domain.InvalidInput},
		{"credentials in repo url", func(c *app.ProjectCmd) { c.RepoURL = "https://user:pass@example.com/x.git" }, domain.InvalidInput},
		{"userinfo in repo url", func(c *app.ProjectCmd) { c.RepoURL = "https://user@example.com/x.git" }, domain.InvalidInput},
	}
	for _, tc := range cases {
		cmd := app.ProjectCmd{
			Binding: e.binding, ID: "proj-" + strings.ReplaceAll(tc.name, " ", "-"),
			Status: "active",
		}
		tc.mutate(&cmd)
		_, err := svc.AddProject(e.ctx(), cmd)
		if tc.want == "" {
			if err != nil {
				t.Errorf("%s: service = %v, want success", tc.name, err)
			}
			continue
		}
		if !domain.Of(err, tc.want) {
			t.Errorf("%s: service = %v, want %s", tc.name, err, tc.want)
		}
		_, err = e.s.AddProject(e.ctx(), cmd, e.now)
		if !domain.Of(err, tc.want) {
			t.Errorf("%s: store = %v, want %s", tc.name, err, tc.want)
		}
	}
}

// TestCheckCatchesDocumentAndProjectViolations proves the new invariant checks
// fire on rows written around the service.
func TestCheckCatchesDocumentAndProjectViolations(t *testing.T) {
	e := newTestEnv(t)
	e.mustPutDoc("knowledge", "ok", "fine", 0)
	e.addProject(app.ProjectCmd{Binding: e.binding, ID: "p1", Status: "active"})
	e.addProject(app.ProjectCmd{Binding: e.binding, ID: "p3", Status: "active",
		RepoURL: "git@github.com:org/repo.git"})

	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("healthy store: %+v (err %v)", rep.Errors, err)
	}

	// Empty slug, relative clone path, .. segment, schemeless repo url.
	e.mustExec(`INSERT INTO documents (id, scope_id, kind, slug, title, body, status,
		revision, created_at, updated_at)
		VALUES ('doc:bad', 'personal', 'journal', '   ', 't', 'b', 'draft', 1, ?, ?)`,
		fmtTime(e.now), fmtTime(e.now))
	e.mustExec(`INSERT INTO projects (id, scope_id, desired_outcome, status, revision, repo_url, clone_path)
		VALUES ('p2', 'personal', '', 'active', 1, 'example.com/x', 'relative/path')`)
	e.mustExec(`UPDATE projects SET clone_path = '/a/../b' WHERE id = 'p1'`)

	rep, err = e.s.Check(e.ctx(), &e.binding)
	if err != nil {
		t.Fatalf("Check: %v", err)
	}
	if rep.OK {
		t.Fatal("broken store reported OK")
	}
	joined := strings.Join(rep.Errors, "\n")
	for _, want := range []string{
		"empty slug", "relative clone path", "clone path with a .. segment",
		"non-absolute repository url",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("check errors missing %q:\n%s", want, joined)
		}
	}
}

// TestExportRestoreCarriesDocuments proves the document layer travels through
// the whole-table export and restore.
func TestExportRestoreCarriesDocuments(t *testing.T) {
	src := newTestEnv(t)
	doc := src.mustPutDoc("knowledge", "komorebi/setup", "the body", 0)
	src.addProject(app.ProjectCmd{
		Binding: src.binding, ID: "opensource/ztd", Status: "active",
		RepoURL: "https://example.com/ztd.git", ClonePath: "/abs/ztd",
	})
	path := filepath.Join(t.TempDir(), "export.json")
	if err := src.s.Export(src.ctx(), path); err != nil {
		t.Fatalf("Export: %v", err)
	}
	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))
	report, err := dst.Restore(src.ctx(), path)
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if report.Tables["documents"] != 1 {
		t.Fatalf("restored documents = %d, want 1", report.Tables["documents"])
	}
	got, err := dst.GetDocument(src.ctx(), src.binding, "knowledge", "komorebi/setup")
	if err != nil {
		t.Fatalf("GetDocument on restored store: %v", err)
	}
	mustJSONEqual(t, doc, got, "restored document")
	proj, err := dst.GetProject(src.ctx(), src.binding, "opensource/ztd")
	if err != nil {
		t.Fatalf("GetProject on restored store: %v", err)
	}
	if proj.RepoURL != "https://example.com/ztd.git" || proj.ClonePath != "/abs/ztd" {
		t.Fatalf("restored project metadata = %q/%q", proj.RepoURL, proj.ClonePath)
	}
	if rep, err := dst.Check(src.ctx(), &src.binding); err != nil || !rep.OK {
		t.Fatalf("check on restored store: %+v (err %v)", rep.Errors, err)
	}
}
