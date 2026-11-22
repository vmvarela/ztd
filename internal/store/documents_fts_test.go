package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// applyRawMigrations writes the named embedded migrations straight into raw,
// so a test can pin an older schema version before reopening.
func applyRawMigrations(t *testing.T, raw *sql.DB, names ...string) {
	t.Helper()
	for _, name := range names {
		body, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := raw.Exec(string(body)); err != nil {
			t.Fatalf("apply %s: %v", name, err)
		}
	}
}

// seedV6Documents builds a version 6 database — everything before 0007 — that
// already holds two documents and one scope, then closes the raw handle.
func seedV6Documents(t *testing.T, path string) {
	t.Helper()
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	applyRawMigrations(t, raw,
		"0001_core.sql", "0002_journey.sql", "0003_goals.sql",
		"0004_sources.sql", "0005_work_item_fields.sql", "0006_documents.sql")
	if _, err := raw.Exec("PRAGMA user_version = 6"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO scopes (id, name, kind, created_at)
		VALUES ('personal', 'personal', 'personal', '2026-11-19T00:00:00Z')`); err != nil {
		t.Fatalf("seed scope: %v", err)
	}
	for _, d := range []struct{ id, kind, slug, title, body string }{
		{"doc:personal:knowledge:setup", "knowledge", "setup", "Setup", "the lumenator lives here"},
		{"doc:personal:journal:day/2026-11-21", "journal", "day/2026-11-21", "Day", "bought a lumenator bulb"},
	} {
		if _, err := raw.Exec(`INSERT INTO documents (id, scope_id, kind, slug, title, body,
			status, revision, created_at, updated_at)
			VALUES (?, 'personal', ?, ?, ?, ?, 'draft', 1,
			        '2026-11-19T00:00:00Z', '2026-11-19T00:00:00Z')`,
			d.id, d.kind, d.slug, d.title, d.body); err != nil {
			t.Fatalf("seed document %s: %v", d.id, err)
		}
	}
}

// TestMigration0007DocumentsFTS pins the retrieval schema: reopening a
// version 6 database reaches version 7, the documents stored before 0007 are
// searchable right after the backfill, and the triggers follow a later
// update and delete instead of leaving stale rows behind.
func TestMigration0007DocumentsFTS(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v6.db")
	seedV6Documents(t, path)
	s := openTestStore(t, path)

	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if version != 7 {
		t.Fatalf("user_version = %d, want 7", version)
	}
	binding := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}

	// Backfill: both pre-0007 documents are searchable, kind and all.
	hits, err := s.SearchDocuments(context.Background(), binding, "lumenator", "", 10)
	if err != nil {
		t.Fatalf("SearchDocuments after 0007: %v", err)
	}
	if len(hits) != 2 {
		t.Fatalf("hits = %d (%+v), want the two seeded documents", len(hits), hits)
	}
	for _, h := range hits {
		if !strings.Contains(h.Snippet, "[lumenator]") {
			t.Errorf("snippet for %s = %q, want the term highlighted", h.Document.Slug, h.Snippet)
		}
	}

	// Update trigger: the old term disappears, the new one appears.
	if _, err := s.PutDocument(context.Background(), app.DocumentCmd{
		Binding: binding, Kind: domain.DocumentKnowledge, Slug: "setup",
		Title: "Setup", Body: "the chronometer lives here", Status: domain.DocumentDraft,
		Expected: 1,
	}, domain.NowUTC()); err != nil {
		t.Fatalf("update document: %v", err)
	}
	if got := searchSlugs(t, s, binding, "lumenator"); len(got) != 1 || got[0] != "day/2026-11-21" {
		t.Fatalf("after update lumenator hits = %v, want only day/2026-11-21", got)
	}
	if got := searchSlugs(t, s, binding, "chronometer"); len(got) != 1 || got[0] != "setup" {
		t.Fatalf("after update chronometer hits = %v, want only setup", got)
	}

	// Delete trigger: the FTS row goes with the document.
	if _, err := s.db.Exec(`DELETE FROM documents WHERE id = 'doc:personal:journal:day/2026-11-21'`); err != nil {
		t.Fatalf("delete document: %v", err)
	}
	if got := searchSlugs(t, s, binding, "lumenator"); len(got) != 0 {
		t.Fatalf("after delete lumenator hits = %v, want none", got)
	}
	var ftsRows int
	if err := s.db.QueryRow(`SELECT count(*) FROM documents_fts`).Scan(&ftsRows); err != nil {
		t.Fatalf("count documents_fts: %v", err)
	}
	var docRows int
	if err := s.db.QueryRow(`SELECT count(*) FROM documents`).Scan(&docRows); err != nil {
		t.Fatalf("count documents: %v", err)
	}
	if ftsRows != docRows {
		t.Fatalf("documents_fts has %d rows, documents has %d", ftsRows, docRows)
	}
}

// searchSlugs returns the slugs matching one query, in rank order.
func searchSlugs(t *testing.T, s *Store, b domain.ScopeBinding, query string) []string {
	t.Helper()
	hits, err := s.SearchDocuments(context.Background(), b, query, "", 10)
	if err != nil {
		t.Fatalf("SearchDocuments(%q): %v", query, err)
	}
	out := make([]string, 0, len(hits))
	for _, h := range hits {
		out = append(out, h.Document.Slug)
	}
	return out
}

// TestSearchDocuments covers the retrieval query: matches in the title and
// the body, the kind filter, scope isolation, bm25 ordering, the limit and
// the sanitization of FTS syntax out of user input.
func TestSearchDocuments(t *testing.T) {
	e := newTestEnv(t)
	ctx := context.Background()

	e.mustPutDoc("knowledge", "komorebi/setup", "Komorebi pins windows to a grid", 0)
	e.mustPutDoc("knowledge", "komorebi/rules", "a grid of rules for the komorebi window manager", 0)
	e.mustPutDoc("journal", "day/2026-11-21", "today I configured komorebi again", 0)
	e.mustPutDoc("knowledge", "foreign", "komorebi lives in the other scope", 0, "opensource")

	personal := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}

	// Title and body both match, best bm25 first.
	knowledge, err := e.s.SearchDocuments(ctx, personal, "komorebi", "", 10)
	if err != nil {
		t.Fatalf("SearchDocuments: %v", err)
	}
	slugs := make([]string, 0, len(knowledge))
	for _, h := range knowledge {
		slugs = append(slugs, h.Document.Kind+"/"+h.Document.Slug)
	}
	if strings.Join(slugs, ",") != "knowledge/komorebi/setup,knowledge/komorebi/rules,journal/day/2026-11-21" {
		t.Fatalf("rank order = %v, want bm25 ascending: setup, rules, then the journal", slugs)
	}
	for _, h := range knowledge {
		if h.Rank >= 0 {
			t.Errorf("%s: rank = %v, want a negative bm25 score", h.Document.Slug, h.Rank)
		}
		if !strings.Contains(strings.ToLower(h.Document.Title+h.Document.Body), "komorebi") {
			t.Errorf("%s: hit without the query term", h.Document.Slug)
		}
		if h.Document.Scope != "personal" {
			t.Fatalf("cross-scope leak: %+v", h.Document)
		}
		if h.Snippet == "" {
			t.Errorf("%s: empty snippet", h.Document.Slug)
		}
	}

	// Scope isolation: the opensource document only shows up for its scope,
	// and the widest binding returns every scope's hits.
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	foreign, err := e.s.SearchDocuments(ctx, onlyOS, "komorebi", "", 10)
	if err != nil || len(foreign) != 1 || foreign[0].Document.Slug != "foreign" {
		t.Fatalf("opensource search = %+v (err %v), want only foreign", foreign, err)
	}
	all, err := e.s.SearchDocuments(ctx, e.binding, "komorebi", "", 10)
	if err != nil || len(all) != 4 {
		t.Fatalf("both scopes = %d hits (err %v), want 4", len(all), err)
	}

	// Kind filter.
	journals, err := e.s.SearchDocuments(ctx, personal, "komorebi", "journal", 10)
	if err != nil || len(journals) != 1 || journals[0].Document.Slug != "day/2026-11-21" {
		t.Fatalf("kind filter = %+v (err %v), want only the journal", journals, err)
	}
	if _, err := e.s.SearchDocuments(ctx, personal, "komorebi", "wiki", 10); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("unknown kind = %v, want invalid_input", err)
	}

	// Limit: 0 picks the default of 10, 1 keeps the best hit.
	if hits, err := e.s.SearchDocuments(ctx, personal, "komorebi", "", 0); err != nil || len(hits) != 3 {
		t.Fatalf("default limit = %d hits (err %v), want 3", len(hits), err)
	}
	if hits, err := e.s.SearchDocuments(ctx, personal, "komorebi", "", 1); err != nil || len(hits) != 1 ||
		hits[0].Document.Slug != "komorebi/setup" {
		t.Fatalf("limit 1 = %+v (err %v), want the best hit", hits, err)
	}

	// An empty query is refused before any SQL runs; FTS syntax in the query
	// is neutralized into literal tokens instead of failing or matching
	// everything: "komorebi OR" must not behave like the OR operator.
	if _, err := e.s.SearchDocuments(ctx, personal, "   ", "", 10); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("blank query = %v, want invalid_input", err)
	}
	for _, q := range []string{`NEAR("a" "b") OR *`, `komorebi OR`, `komorebi" OR "nothing`} {
		if hits, err := e.s.SearchDocuments(ctx, personal, q, "", 10); err != nil {
			t.Errorf("query %q = %v, want a literal search", q, err)
		} else if len(hits) != 0 {
			t.Errorf("query %q = %d hits, want 0: operators must be literal", q, len(hits))
		}
	}
	// Every token must appear: both words together match one document.
	if hits, err := e.s.SearchDocuments(ctx, personal, "komorebi setup", "", 10); err != nil || len(hits) != 1 ||
		hits[0].Document.Slug != "komorebi/setup" {
		t.Fatalf("two-token query = %+v (err %v), want only komorebi/setup", hits, err)
	}
	if hits, err := e.s.SearchDocuments(ctx, personal, "nothing", "", 10); err != nil || len(hits) != 0 {
		t.Fatalf("missing term = %d hits (err %v), want an empty list", len(hits), err)
	}

	// The 50-hit cap: raw inserts (indexed by the insert trigger) past the
	// cap never come back whole, whatever the caller asks for.
	for i := 0; i < 52; i++ {
		slug := fmt.Sprintf("cap/%02d", i)
		e.mustExec(`INSERT INTO documents (id, scope_id, kind, slug, title, body,
			status, revision, created_at, updated_at)
			VALUES (?, 'personal', 'journal', ?, ?, 'capybara note', 'draft', 1, ?, ?)`,
			"doc:personal:journal:"+slug, slug, slug, fmtTime(e.now), fmtTime(e.now))
	}
	if hits, err := e.s.SearchDocuments(ctx, personal, "capybara", "", 999); err != nil || len(hits) != 50 {
		t.Fatalf("capped limit = %d hits (err %v), want 50", len(hits), err)
	}
	if hits, err := e.s.SearchDocuments(ctx, personal, "capybara", "", 10); err != nil || len(hits) != 10 {
		t.Fatalf("default limit over 52 matches = %d hits (err %v), want 10", len(hits), err)
	}
}

// TestRestoreRebuildsDocumentsFTS pins the derived-index rule: documents_fts
// is not part of the export format, and a restore rebuilds it from the
// documents rows through the triggers.
func TestRestoreRebuildsDocumentsFTS(t *testing.T) {
	src := newTestEnv(t)
	src.mustPutDoc("knowledge", "komorebi/setup", "the body of the card", 0)
	path := filepath.Join(t.TempDir(), "export.json")
	if err := src.s.Export(src.ctx(), path); err != nil {
		t.Fatalf("Export: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "documents_fts") {
		t.Fatal("export carries documents_fts; it is a derived index, not data")
	}

	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))
	if _, err := dst.Restore(src.ctx(), path); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	var ftsRows int
	if err := dst.db.QueryRow(`SELECT count(*) FROM documents_fts`).Scan(&ftsRows); err != nil {
		t.Fatalf("count documents_fts: %v", err)
	}
	if ftsRows != 1 {
		t.Fatalf("documents_fts rows after restore = %d, want 1 rebuilt by the triggers", ftsRows)
	}
	hits, err := dst.SearchDocuments(src.ctx(), src.binding, "body", "", 10)
	if err != nil || len(hits) != 1 || hits[0].Document.Slug != "komorebi/setup" {
		t.Fatalf("search on restored store = %+v (err %v), want the rebuilt index", hits, err)
	}
}
