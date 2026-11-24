package integration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type contextData struct {
	ID       string `json:"id"`
	Scope    string `json:"scope"`
	Name     string `json:"name"`
	Revision int64  `json:"revision"`
}

type documentData struct {
	ID       string `json:"id"`
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	Slug     string `json:"slug"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	Status   string `json:"status"`
	Revision int64  `json:"revision"`
}

type projectData struct {
	ID             string `json:"id"`
	Scope          string `json:"scope"`
	DesiredOutcome string `json:"desired_outcome"`
	Status         string `json:"status"`
	RepoURL        string `json:"repo_url"`
	ClonePath      string `json:"clone_path"`
	Revision       int64  `json:"revision"`
}

type bindingsData struct {
	OK      bool           `json:"ok"`
	Binding map[string]any `json:"binding"`
	Scope   string         `json:"scope"`
	Project string         `json:"project"`
}

// TestContextCommands walks context add/list through separate processes,
// including the duplicate no-op and scope isolation.
func TestContextCommands(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	added := decode[contextData](t, run(t, db, "context", "add", "familia").wantOK(t, "context add"))
	if added.ID != "ctx:personal:familia" || added.Revision != 1 || added.Scope != "personal" {
		t.Fatalf("context = %+v, want ctx:personal:familia revision 1 in personal", added)
	}
	// The same name again is a no-op, not an error.
	again := decode[contextData](t, run(t, db, "context", "add", "familia").wantOK(t, "context add"))
	if again.ID != added.ID || again.Revision != 1 {
		t.Fatalf("duplicate context = %+v, want the original back", again)
	}
	run(t, db, "context", "add", "ztd", "--scope", "opensource").wantOK(t, "context add")

	all := decode[[]contextData](t, run(t, db, "context", "list").wantOK(t, "context list"))
	if len(all) != 2 || all[0].Name != "familia" || all[1].Name != "ztd" {
		t.Fatalf("context list = %+v, want familia,ztd in name order", all)
	}
	only := decode[[]contextData](t, run(t, db, "context", "list", "--scope", "opensource").wantOK(t, "context list"))
	if len(only) != 1 || only[0].Name != "ztd" {
		t.Fatalf("opensource contexts = %+v, want only ztd", only)
	}
	run(t, db, "context", "add").wantErr(t, 1, "context", "invalid_input")
}

// TestDocCommands walks doc put/get/list: create, idempotent replay, update
// with --expected, stale guard, filters and cross-scope not_found.
func TestDocCommands(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	created := decode[documentData](t, run(t, db, "doc", "put",
		"--kind", "knowledge", "--slug", "komorebi/setup",
		"--title", "Komorebi setup", "--body", "body one").wantOK(t, "doc put"))
	if created.Revision != 1 || created.Status != "draft" || created.Scope != "personal" {
		t.Fatalf("created doc = %+v, want revision 1 draft in personal", created)
	}
	if created.ID != "doc:personal:knowledge:komorebi/setup" {
		t.Fatalf("doc id = %q", created.ID)
	}

	// Same command again: replay, still revision 1.
	replay := decode[documentData](t, run(t, db, "doc", "put",
		"--kind", "knowledge", "--slug", "komorebi/setup",
		"--title", "Komorebi setup", "--body", "body one").wantOK(t, "doc put"))
	if replay.Revision != 1 {
		t.Fatalf("replay revision = %d, want 1", replay.Revision)
	}

	// Update with the current revision and a file body.
	bodyFile := filepath.Join(t.TempDir(), "body.md")
	if err := os.WriteFile(bodyFile, []byte("body from file"), 0o644); err != nil {
		t.Fatal(err)
	}
	updated := decode[documentData](t, run(t, db, "doc", "put",
		"--kind", "knowledge", "--slug", "komorebi/setup",
		"--title", "Komorebi setup", "--file", bodyFile,
		"--status", "verified", "--expected", "1").wantOK(t, "doc put"))
	if updated.Revision != 2 || updated.Body != "body from file" || updated.Status != "verified" {
		t.Fatalf("updated doc = %+v, want revision 2 verified with the file body", updated)
	}

	// A stale expectation writes nothing. The expected value is fresh (never a
	// successful attempt), so the failure is stale_revision rather than an
	// idempotency conflict on a reused key.
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "komorebi/setup",
		"--body", "nope", "--expected", "5").wantErr(t, 1, "doc", "stale_revision")

	got := decode[documentData](t, run(t, db, "doc", "get",
		"--kind", "knowledge", "--slug", "komorebi/setup").wantOK(t, "doc get"))
	if got.Revision != 2 || got.Body != "body from file" {
		t.Fatalf("doc get = %+v, want the updated document", got)
	}
	// Cross-scope get is not_found, never a leak.
	run(t, db, "doc", "get", "--kind", "knowledge", "--slug", "komorebi/setup",
		"--scope", "opensource").wantErr(t, 1, "doc", "not_found")

	run(t, db, "doc", "put", "--kind", "wiki", "--slug", "x", "--body", "y").
		wantErr(t, 1, "doc", "invalid_input")
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "x y", "--body", "y").
		wantErr(t, 1, "doc", "invalid_input")
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "empty").
		wantErr(t, 1, "doc", "invalid_input")

	// Filters: kind and scope.
	run(t, db, "doc", "put", "--kind", "journal", "--slug", "day/2026-11-20",
		"--body", "note").wantOK(t, "doc put")
	knowledge := decode[[]documentData](t, run(t, db, "doc", "list",
		"--kind", "knowledge").wantOK(t, "doc list"))
	if len(knowledge) != 1 || knowledge[0].Slug != "komorebi/setup" {
		t.Fatalf("knowledge list = %+v, want only komorebi/setup", knowledge)
	}
	all := decode[[]documentData](t, run(t, db, "doc", "list").wantOK(t, "doc list"))
	if len(all) != 2 {
		t.Fatalf("doc list = %d documents, want 2", len(all))
	}
	onlyOS := decode[[]documentData](t, run(t, db, "doc", "list", "--scope", "opensource").wantOK(t, "doc list"))
	if len(onlyOS) != 0 {
		t.Fatalf("opensource docs = %+v, want empty", onlyOS)
	}
	// Unknown kinds are refused on read paths too.
	run(t, db, "doc", "list", "--kind", "wiki").wantErr(t, 1, "doc", "invalid_input")
}

// logEntryData is one `doc log` entry: newest first by seq.
type logEntryData struct {
	Seq      int64  `json:"seq"`
	Event    string `json:"event"`
	Revision int64  `json:"revision"`
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	Slug     string `json:"slug"`
}

type lintFindingData struct {
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	Slug     string `json:"slug"`
	Severity string `json:"severity"`
	Code     string `json:"code"`
	Message  string `json:"message"`
}

type lintReportData struct {
	Errors   []lintFindingData `json:"errors"`
	Warnings []lintFindingData `json:"warnings"`
	Findings []lintFindingData `json:"findings"`
}

// TestDocLogLintArchive walks doc log, doc lint (clean and failing) and doc
// archive through separate processes.
func TestDocLogLintArchive(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	// A clean pair: the card points at the index, the index back at the card.
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "setup",
		"--title", "Setup", "--body", "See [[index|the index]]").wantOK(t, "doc put")
	run(t, db, "doc", "put", "--kind", "knowledge_index", "--slug", "index",
		"--title", "Index", "--body", "[[setup]]").wantOK(t, "doc put")

	// doc log --json: newest first, seq strictly decreasing.
	log := decode[[]logEntryData](t, run(t, db, "doc", "log", "--json").wantOK(t, "doc log"))
	if len(log) < 2 {
		t.Fatalf("doc log = %+v, want at least the two writes", log)
	}
	for i := 1; i < len(log); i++ {
		if log[i].Seq >= log[i-1].Seq {
			t.Fatalf("doc log order = %+v, want decreasing seq", log)
		}
	}
	if log[0].Kind != "knowledge_index" || log[0].Slug != "index" || log[0].Scope != "personal" {
		t.Fatalf("newest entry = %+v, want personal/knowledge_index/index", log[0])
	}
	onlyIndex := decode[[]logEntryData](t, run(t, db, "doc", "log",
		"--kind", "knowledge_index", "--json").wantOK(t, "doc log"))
	if len(onlyIndex) != 1 || onlyIndex[0].Slug != "index" {
		t.Fatalf("kind filter = %+v, want only index", onlyIndex)
	}

	// doc lint --json over the clean pair: no findings at all.
	clean := decode[lintReportData](t, run(t, db, "doc", "lint", "--json").wantOK(t, "doc lint"))
	if len(clean.Errors) != 0 || len(clean.Warnings) != 0 || len(clean.Findings) != 0 {
		t.Fatalf("clean lint = %+v, want no findings", clean)
	}

	// One broken card: the wikilink is an error, and the card is an orphan
	// because the index never references it.
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "broken",
		"--title", "Broken", "--body", "see [[ghost]]").wantOK(t, "doc put")
	failing := run(t, db, "doc", "lint", "--json")
	failing.wantErr(t, 1, "doc", "conflict")
	report := decode[lintReportData](t, failing.env.Data)
	if len(report.Errors) != 1 || report.Errors[0].Code != "unresolved_wikilink" ||
		report.Errors[0].Slug != "broken" {
		t.Fatalf("lint errors = %+v, want one unresolved_wikilink on broken", report.Errors)
	}
	if len(report.Warnings) != 0 {
		t.Fatalf("lint warnings = %+v, want no index requirement", report.Warnings)
	}

	// doc archive stores the answer under answers/<slug>, header included.
	archived := decode[documentData](t, run(t, db, "doc", "archive",
		"--slug", "answers/how-to", "--title", "How to",
		"--question", "How do I do it?", "--body", "Like this.").wantOK(t, "doc archive"))
	if archived.Slug != "answers/how-to" || archived.Kind != "knowledge" ||
		archived.Status != "draft" || archived.Revision != 1 {
		t.Fatalf("archived = %+v, want a new answers/how-to draft", archived)
	}
	for _, part := range []string{"# How to", "Question: How do I do it?", "Archived: ", "Like this."} {
		if !strings.Contains(archived.Body, part) {
			t.Errorf("archived body missing %q:\n%s", part, archived.Body)
		}
	}

	// doc get returns the same document, and the archive left its history.
	got := decode[documentData](t, run(t, db, "doc", "get",
		"--kind", "knowledge", "--slug", "answers/how-to").wantOK(t, "doc get"))
	if got.Body != archived.Body || got.Title != archived.Title {
		t.Fatalf("doc get = %+v, want the archived document", got)
	}
	history := decode[[]logEntryData](t, run(t, db, "doc", "log",
		"--slug", "answers/how-to", "--json").wantOK(t, "doc log"))
	if len(history) != 1 || history[0].Event != "created" || history[0].Slug != "answers/how-to" {
		t.Fatalf("archive history = %+v, want one created event", history)
	}

	// An archive without an answer body still records the question, and a
	// stale expectation writes nothing.
	run(t, db, "doc", "archive", "--slug", "stub", "--question", "Why?").
		wantOK(t, "doc archive")
	run(t, db, "doc", "archive", "--slug", "stub", "--question", "Why?", "--expected", "5").
		wantErr(t, 1, "doc", "stale_revision")
}

// TestProjectCommands walks project add/list/show including the repository
// rules and cross-scope isolation.
func TestProjectCommands(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	added := decode[projectData](t, run(t, db, "project", "add", "opensource/ztd",
		"--desired-outcome", "ship the go rewrite",
		"--repo-url", "https://example.com/ztd.git",
		"--clone-path", "/home/me/workspaces/ztd").wantOK(t, "project add"))
	if added.ID != "opensource/ztd" || added.Revision != 1 || added.Status != "active" {
		t.Fatalf("project = %+v, want active revision 1", added)
	}
	if added.RepoURL != "https://example.com/ztd.git" || added.ClonePath != "/home/me/workspaces/ztd" {
		t.Fatalf("repository metadata = %q/%q", added.RepoURL, added.ClonePath)
	}

	// Identical configuration is a no-op; different configuration conflicts.
	again := decode[projectData](t, run(t, db, "project", "add", "opensource/ztd",
		"--desired-outcome", "ship the go rewrite",
		"--repo-url", "https://example.com/ztd.git",
		"--clone-path", "/home/me/workspaces/ztd").wantOK(t, "project add"))
	if again.Revision != 1 {
		t.Fatalf("duplicate project revision = %d, want 1", again.Revision)
	}
	run(t, db, "project", "add", "opensource/ztd", "--status", "paused").
		wantErr(t, 1, "project", "conflict")

	// Repository rules.
	run(t, db, "project", "add", "p-creds", "--repo-url", "https://user:pass@example.com/x.git").
		wantErr(t, 1, "project", "invalid_input")
	run(t, db, "project", "add", "p-rel", "--clone-path", "relative/path").
		wantErr(t, 1, "project", "invalid_input")
	run(t, db, "project", "add", "p-dotdot", "--clone-path", "/a/../b").
		wantErr(t, 1, "project", "invalid_input")
	run(t, db, "project", "add", "p-badstatus", "--status", "doing").
		wantErr(t, 1, "project", "invalid_input")

	run(t, db, "project", "add", "aaa", "--scope", "opensource").wantOK(t, "project add")
	list := decode[[]projectData](t, run(t, db, "project", "list").wantOK(t, "project list"))
	if len(list) != 2 || list[0].ID != "aaa" || list[1].ID != "opensource/ztd" {
		t.Fatalf("project list = %+v, want aaa then.opensource/ztd", list)
	}
	shown := decode[projectData](t, run(t, db, "project", "show", "opensource/ztd").wantOK(t, "project show"))
	if shown.RepoURL != "https://example.com/ztd.git" {
		t.Fatalf("project show = %+v, want the repository url", shown)
	}
	run(t, db, "project", "show", "ghost").wantErr(t, 1, "project", "not_found")
	run(t, db, "project", "show", "--scope", "opensource", "opensource/ztd").
		wantErr(t, 1, "project", "not_found")
}

// writeBinding drops a .ztd.json into a fresh directory and returns it.
func writeBinding(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if body != "" {
		if err := os.WriteFile(filepath.Join(dir, ".ztd.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// TestCheckBindings covers the routing-hint validation: the valid shape, a
// missing file, malformed JSON, an unknown project and the three scope
// resolution rules.
func TestCheckBindings(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	// Declared scopes: personal, opensource and client:prisamedia. There is no
	// "trabajo" scope, so context=trabajo must fall through to the client.
	run(t, db, "init",
		"--scope", "id=personal,kind=personal",
		"--scope", "id=opensource,kind=opensource",
		"--scope", "id=client:prisamedia,kind=client").wantOK(t, "init")
	run(t, db, "project", "add", "p-os", "--scope", "opensource").wantOK(t, "project add")
	run(t, db, "project", "add", "p-client", "--scope", "client:prisamedia").wantOK(t, "project add")
	run(t, db, "project", "add", "p-personal", "--scope", "personal").wantOK(t, "project add")

	// Valid: the context names a scope directly.
	dir := writeBinding(t, `{"context":"opensource","project":"p-os"}`)
	got := decode[bindingsData](t, runIn(t, t.TempDir(), dir, db, "check", "--bindings").wantOK(t, "check"))
	if !got.OK || got.Scope != "opensource" || got.Project != "p-os" {
		t.Fatalf("bindings = %+v, want ok opensource/p-os", got)
	}
	if got.Binding["context"] != "opensource" {
		t.Fatalf("binding echo = %+v", got.Binding)
	}

	// No matching context scope: fall back to client:<client>.
	dir = writeBinding(t, `{"context":"trabajo","client":"prisamedia","project":"p-client"}`)
	got = decode[bindingsData](t, runIn(t, t.TempDir(), dir, db, "check", "--bindings").wantOK(t, "check"))
	if got.Scope != "client:prisamedia" || got.Project != "p-client" {
		t.Fatalf("scope = %q project = %q, want client:prisamedia/p-client", got.Scope, got.Project)
	}

	// No context, no client: fall back to personal.
	dir = writeBinding(t, `{"context":"familia","project":"p-personal"}`)
	got = decode[bindingsData](t, runIn(t, t.TempDir(), dir, db, "check", "--bindings").wantOK(t, "check"))
	if got.Scope != "personal" || got.Project != "p-personal" {
		t.Fatalf("scope = %q project = %q, want personal/p-personal", got.Scope, got.Project)
	}

	// Missing file.
	dir = writeBinding(t, "")
	runIn(t, t.TempDir(), dir, db, "check", "--bindings").
		wantErr(t, 1, "check", "invalid_input")

	// Malformed JSON.
	dir = writeBinding(t, `{not json`)
	runIn(t, t.TempDir(), dir, db, "check", "--bindings").
		wantErr(t, 1, "check", "invalid_input")

	// Wrong shape: unknown field, missing context, non-string value.
	for _, body := range []string{
		`{"context":"opensource","project":"p-os","extra":1}`,
		`{"project":"p-os"}`,
		`{"context":5,"project":"p-os"}`,
		`{"context":"","project":"p-os"}`,
	} {
		dir = writeBinding(t, body)
		runIn(t, t.TempDir(), dir, db, "check", "--bindings").
			wantErr(t, 1, "check", "invalid_input")
	}

	// Unknown project in the resolved scope.
	dir = writeBinding(t, `{"context":"opensource","project":"ghost"}`)
	runIn(t, t.TempDir(), dir, db, "check", "--bindings").
		wantErr(t, 1, "check", "not_found")

	// No matching scope at all: personal exists after init, so the project
	// lookup inside it fails instead.
	dir = writeBinding(t, `{"context":"nowhere","project":"p-os"}`)
	runIn(t, t.TempDir(), dir, db, "check", "--bindings").
		wantErr(t, 1, "check", "not_found")

	// A database without any declared scope cannot resolve anything, and the
	// command must not create it.
	freshDB := filepath.Join(t.TempDir(), "missing.db")
	dir = writeBinding(t, `{"context":"personal","project":"p"}`)
	runIn(t, t.TempDir(), dir, freshDB, "check", "--bindings").
		wantErr(t, 1, "check", "invalid_input")
	if _, err := os.Stat(freshDB); !os.IsNotExist(err) {
		t.Fatalf("check --bindings created the database (err %v)", err)
	}

	// The plain invariant check still works alongside --bindings.
	run(t, db, "check").wantOK(t, "check")
}

// hitData is one `doc search` hit: the document plus its bm25 rank and the
// highlighted body snippet.
type hitData struct {
	Document documentData `json:"document"`
	Rank     float64      `json:"rank"`
	Snippet  string       `json:"snippet"`
}

// relationsData is one `doc related` result.
type relationsData struct {
	Source    documentData   `json:"source"`
	Outlinks  []documentData `json:"outlinks"`
	Backlinks []documentData `json:"backlinks"`
}

// TestDocSearchRelated walks doc search and doc related through separate
// processes: the required flags, the JSON shapes, the kind filter, the limit
// and the cross-scope not_found.
func TestDocSearchRelated(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "komorebi/setup",
		"--title", "Komorebi setup", "--body", "the clone lives under repos/").wantOK(t, "doc put")
	run(t, db, "doc", "put", "--kind", "knowledge_index", "--slug", "index",
		"--title", "Index", "--body", "[[komorebi/setup]]").wantOK(t, "doc put")
	run(t, db, "doc", "put", "--kind", "journal", "--slug", "day/2026-11-21",
		"--title", "Day", "--body", "today I read the komorebi setup").wantOK(t, "doc put")

	// --query is required.
	run(t, db, "doc", "search").wantErr(t, 1, "doc", "invalid_input")
	run(t, db, "doc", "search", "--kind", "knowledge").wantErr(t, 1, "doc", "invalid_input")

	// Every hit carries the document, a negative rank and a snippet.
	hits := decode[[]hitData](t, run(t, db, "doc", "search",
		"--query", "komorebi", "--json").wantOK(t, "doc search"))
	if len(hits) != 3 {
		t.Fatalf("search hits = %d, want 3", len(hits))
	}
	seen := map[string]bool{}
	for _, h := range hits {
		if h.Rank >= 0 || h.Snippet == "" {
			t.Errorf("%s: rank=%v snippet=%q, want a negative bm25 and a snippet",
				h.Document.Slug, h.Rank, h.Snippet)
		}
		if !strings.Contains(strings.ToLower(h.Document.Title+h.Document.Body), "komorebi") {
			t.Errorf("%s: hit without the query term", h.Document.Slug)
		}
		seen[h.Document.Kind+"/"+h.Document.Slug] = true
	}
	if len(seen) != 3 {
		t.Fatalf("distinct hits = %v, want the three documents", seen)
	}

	// Kind filter and limit.
	knowledge := decode[[]hitData](t, run(t, db, "doc", "search",
		"--query", "komorebi", "--kind", "knowledge", "--json").wantOK(t, "doc search"))
	if len(knowledge) != 1 || knowledge[0].Document.Slug != "komorebi/setup" {
		t.Fatalf("kind filter = %+v, want only komorebi/setup", knowledge)
	}
	limited := decode[[]hitData](t, run(t, db, "doc", "search",
		"--query", "komorebi", "--limit", "1", "--json").wantOK(t, "doc search"))
	if len(limited) != 1 {
		t.Fatalf("limit 1 = %d hits, want 1", len(limited))
	}
	// A query nothing matches is an empty list, not an error.
	if none := decode[[]hitData](t, run(t, db, "doc", "search",
		"--query", "capybara", "--json").wantOK(t, "doc search")); len(none) != 0 {
		t.Fatalf("missing term = %+v, want no hits", none)
	}

	// related requires both --kind and --slug.
	run(t, db, "doc", "related").wantErr(t, 1, "doc", "invalid_input")
	run(t, db, "doc", "related", "--kind", "knowledge").wantErr(t, 1, "doc", "invalid_input")
	run(t, db, "doc", "related", "--kind", "wiki", "--slug", "x").wantErr(t, 1, "doc", "invalid_input")

	rel := decode[relationsData](t, run(t, db, "doc", "related",
		"--kind", "knowledge", "--slug", "komorebi/setup", "--json").wantOK(t, "doc related"))
	if rel.Source.Slug != "komorebi/setup" || rel.Source.Kind != "knowledge" {
		t.Fatalf("source = %+v, want knowledge/komorebi/setup", rel.Source)
	}
	if len(rel.Outlinks) != 0 {
		t.Fatalf("outlinks = %+v, want none: the card links nothing", rel.Outlinks)
	}
	if len(rel.Backlinks) != 1 || rel.Backlinks[0].Slug != "index" ||
		rel.Backlinks[0].Kind != "knowledge_index" {
		t.Fatalf("backlinks = %+v, want the index", rel.Backlinks)
	}
	// The index itself has the card as its outlink and no backlinks.
	idx := decode[relationsData](t, run(t, db, "doc", "related",
		"--kind", "knowledge_index", "--slug", "index", "--json").wantOK(t, "doc related"))
	if len(idx.Outlinks) != 1 || idx.Outlinks[0].Slug != "komorebi/setup" || len(idx.Backlinks) != 0 {
		t.Fatalf("index relation = outlinks %v backlinks %v, want the card and none",
			idx.Outlinks, idx.Backlinks)
	}

	// A foreign scope never sees the card: not_found, no disclosure.
	run(t, db, "doc", "related", "--kind", "knowledge", "--slug", "komorebi/setup",
		"--scope", "opensource").wantErr(t, 1, "doc", "not_found")
	foreignHits := decode[[]hitData](t, run(t, db, "doc", "search", "--scope", "opensource",
		"--query", "komorebi", "--json").wantOK(t, "doc search"))
	if len(foreignHits) != 0 {
		t.Fatalf("opensource search = %+v, want no personal hits", foreignHits)
	}
}
