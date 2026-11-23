package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

type testEnv struct {
	t       *testing.T
	s       *Store
	binding domain.ScopeBinding
	now     time.Time
}

func openTestStore(t *testing.T, path string) *Store {
	t.Helper()
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open(%q): %v", path, err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// newTestEnv opens a fresh database, seeds the default personal profile and
// fixes "now" so every generated id is deterministic.
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	if err := s.SeedDefaults(context.Background(), "tester"); err != nil {
		t.Fatalf("SeedDefaults: %v", err)
	}
	return &testEnv{
		t:       t,
		s:       s,
		binding: domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal", "opensource"}},
		now:     time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC),
	}
}

func (e *testEnv) ctx() context.Context { return context.Background() }

func (e *testEnv) capture(text, key string) domain.Capture {
	e.t.Helper()
	c, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: key, Text: text}, e.now)
	if err != nil {
		e.t.Fatalf("Capture(%q): %v", text, err)
	}
	return c
}

func (e *testEnv) process(id domain.CaptureID, key string, rev domain.Revision, o domain.Outcome, now time.Time) (app.ProcessResult, error) {
	return e.s.Process(e.ctx(), app.ProcessCmd{
		Binding: e.binding, Key: key, ID: id, Expected: rev, Outcome: o,
	}, now)
}

func (e *testEnv) mustProcess(id domain.CaptureID, key string, rev domain.Revision, titles ...string) app.ProcessResult {
	e.t.Helper()
	res, err := e.process(id, key, rev, domain.Outcome{Kind: domain.OutcomeWorkItems, Titles: titles}, e.now)
	if err != nil {
		e.t.Fatalf("Process(%s): %v", id, err)
	}
	return res
}

// workItems is the common arrange step: one capture turned into n work items.
func (e *testEnv) workItems(n int, key string) []domain.WorkItem {
	e.t.Helper()
	titles := make([]string, n)
	for i := range titles {
		titles[i] = "task " + string(rune('a'+i))
	}
	return e.mustProcess(e.capture("seed "+key, key+"-cap").ID, key, 1, titles...).WorkItems
}

func (e *testEnv) mustExec(query string, args ...any) {
	e.t.Helper()
	if _, err := e.s.db.ExecContext(e.ctx(), query, args...); err != nil {
		e.t.Fatalf("exec %q: %v", query, err)
	}
}

func (e *testEnv) count(query string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.s.db.QueryRowContext(e.ctx(), query, args...).Scan(&n); err != nil {
		e.t.Fatalf("count %q: %v", query, err)
	}
	return n
}

// counts snapshots every table a failed mutation could touch.
func (e *testEnv) counts() [8]int {
	e.t.Helper()
	var c [8]int
	err := e.s.db.QueryRowContext(e.ctx(),
		`SELECT (SELECT count(*) FROM captures),
		        (SELECT count(*) FROM work_items),
		        (SELECT count(*) FROM plans),
		        (SELECT count(*) FROM plan_items),
		        (SELECT count(*) FROM history_events),
		        (SELECT count(*) FROM idempotency_records),
		        (SELECT count(*) FROM sources),
		        (SELECT count(*) FROM source_reviews)`).Scan(&c[0], &c[1], &c[2], &c[3], &c[4], &c[5], &c[6], &c[7])
	if err != nil {
		e.t.Fatalf("counts: %v", err)
	}
	return c
}

func wantFamily(t *testing.T, err error, want domain.Family) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error of family %s, got nil", want)
	}
	if !domain.Of(err, want) {
		t.Fatalf("expected family %s, got: %v", want, err)
	}
}

func TestOpenAppliesMigrationsIdempotently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ztd.db")
	s := openTestStore(t, path)
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if version != 7 {
		t.Fatalf("user_version = %d, want 7", version)
	}
	var tables int
	if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table'
		AND name IN ('scopes','profiles','captures','work_items','plans','plan_items','focus_sessions','checkpoints','reviews','goals','history_events','idempotency_records','sources','source_reviews')`).
		Scan(&tables); err != nil {
		t.Fatalf("count tables: %v", err)
	}
	if tables != 14 {
		t.Fatalf("found %d core tables, want 14", tables)
	}
	if err := s.SeedDefaults(context.Background(), "tester"); err != nil {
		t.Fatalf("SeedDefaults: %v", err)
	}

	// Reopening runs the migration loop again and must be a no-op.
	s.Close()
	s2 := openTestStore(t, path)
	if err := s2.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 7 {
		t.Fatalf("after reopen user_version = %d (err %v), want 7", version, err)
	}
	if n := countRows(t, s2, "scopes"); n != 2 {
		t.Fatalf("after reopen scopes = %d, want 2", n)
	}
}

// TestMigration0005UpgradesExistingRows builds a version 4 database that
// already holds a work item, then reopens it so migration 0005 runs: the new
// column must exist, user_version must reach 7 and the old row must read back
// with an empty custom_fields object.
func TestMigration0005UpgradesExistingRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v4.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"0001_core.sql", "0002_journey.sql", "0003_goals.sql", "0004_sources.sql"} {
		body, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := raw.Exec(string(body)); err != nil {
			t.Fatalf("apply %s: %v", name, err)
		}
	}
	if _, err := raw.Exec("PRAGMA user_version = 4"); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`INSERT INTO scopes (id, name, kind, created_at)
		VALUES ('personal', 'personal', 'personal', '2026-11-19T00:00:00Z')`); err != nil {
		t.Fatalf("seed scope: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO work_items (id, scope_id, title, lifecycle, revision, created_at, updated_at)
		VALUES ('T-20261119-001', 'personal', 'written before 0005', 'next', 1,
		        '2026-11-19T00:00:00Z', '2026-11-19T00:00:00Z')`); err != nil {
		t.Fatalf("seed work item: %v", err)
	}
	raw.Close()

	s := openTestStore(t, path)
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if version != 7 {
		t.Fatalf("user_version = %d, want 7 after 0005 through 0007", version)
	}
	var fields string
	if err := s.db.QueryRow(`SELECT custom_fields FROM work_items WHERE id = 'T-20261119-001'`).
		Scan(&fields); err != nil {
		t.Fatalf("read custom_fields: %v", err)
	}
	if fields != "{}" {
		t.Fatalf("custom_fields = %q, want the default {}", fields)
	}
	b := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	got, err := s.GetWorkItem(context.Background(), b, "T-20261119-001")
	if err != nil || got.Title != "written before 0005" || len(got.CustomFields) != 0 {
		t.Fatalf("upgraded work item = %+v (err %v)", got, err)
	}
}

func countRows(t *testing.T, s *Store, table string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow("SELECT count(*) FROM " + table).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

func TestOpenRejectsUnknownDatabases(t *testing.T) {
	dir := t.TempDir()

	t.Run("non-sqlite nonempty file", func(t *testing.T) {
		path := filepath.Join(dir, "garbage.db")
		if err := os.WriteFile(path, []byte("this is not a sqlite database"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, err := Open(path)
		wantFamily(t, err, domain.DBIncompatible)
	})

	t.Run("sqlite file with tables but no version", func(t *testing.T) {
		path := filepath.Join(dir, "foreign.db")
		raw, err := sql.Open("sqlite", path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := raw.Exec("CREATE TABLE dummy (x)"); err != nil {
			t.Fatal(err)
		}
		raw.Close()
		_, err = Open(path)
		wantFamily(t, err, domain.DBIncompatible)
	})

	t.Run("newer user_version", func(t *testing.T) {
		path := filepath.Join(dir, "future.db")
		s, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.db.Exec("PRAGMA user_version = 99"); err != nil {
			t.Fatal(err)
		}
		s.Close()
		_, err = Open(path)
		wantFamily(t, err, domain.DBIncompatible)
	})

	t.Run("zero byte file is a fresh database", func(t *testing.T) {
		path := filepath.Join(dir, "empty.db")
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		s, err := Open(path)
		if err != nil {
			t.Fatalf("Open zero-byte file: %v", err)
		}
		// Close before TempDir cleanup: Windows cannot delete an open file.
		s.Close()
	})

	t.Run("memory database migrates normally", func(t *testing.T) {
		s, err := Open(":memory:")
		if err != nil {
			t.Fatalf("Open :memory:: %v", err)
		}
		defer s.Close()
		var version int
		if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil || version != 7 {
			t.Fatalf("memory user_version = %d (err %v), want 7", version, err)
		}
		if err := s.SeedDefaults(context.Background(), "tester"); err != nil {
			t.Fatalf("SeedDefaults on memory: %v", err)
		}
	})
}

func TestSeedDefaultsTwiceCreatesNoDuplicates(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	for i := 0; i < 2; i++ {
		if err := s.SeedDefaults(context.Background(), "alice"); err != nil {
			t.Fatalf("SeedDefaults run %d: %v", i+1, err)
		}
	}
	if n := countRows(t, s, "scopes"); n != 2 {
		t.Fatalf("scopes = %d, want 2", n)
	}
	if n := countRows(t, s, "profiles"); n != 1 {
		t.Fatalf("profiles = %d, want 1", n)
	}
	if n := countRows(t, s, "profile_scopes"); n != 2 {
		t.Fatalf("profile_scopes = %d, want 2", n)
	}
	var kind, owner, tz, status string
	err := s.db.QueryRow(`SELECT kind, owner_actor_id, timezone, status FROM profiles WHERE id = 'personal'`).
		Scan(&kind, &owner, &tz, &status)
	if err != nil {
		t.Fatal(err)
	}
	if kind != "personal" || owner != "alice" || tz == "" || status != "active" {
		t.Fatalf("profile row = kind %q owner %q tz %q status %q", kind, owner, tz, status)
	}
	// A later run with a different actor must not rewrite an existing profile.
	if err := s.SeedDefaults(context.Background(), "bob"); err != nil {
		t.Fatalf("SeedDefaults with other actor: %v", err)
	}
	owner = ""
	if err := s.db.QueryRow(`SELECT owner_actor_id FROM profiles WHERE id = 'personal'`).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	if owner != "alice" {
		t.Fatalf("owner changed to %q, want alice", owner)
	}
	for _, sc := range []string{"personal", "opensource"} {
		var n int
		if err := s.db.QueryRow(`SELECT count(*) FROM profile_scopes WHERE profile_id='personal' AND scope_id=?`, sc).Scan(&n); err != nil || n != 1 {
			t.Fatalf("profile_scopes %s = %d (err %v), want 1", sc, n, err)
		}
	}
}

func TestCaptureIdempotencyConflictsAndExternalIdentity(t *testing.T) {
	e := newTestEnv(t)
	ctx := e.ctx()

	c1, err := e.s.Capture(ctx, app.CaptureCmd{Binding: e.binding, Key: "k1", Text: "hola"}, e.now)
	if err != nil {
		t.Fatalf("first capture: %v", err)
	}
	if c1.ID != "C-20261119-001" {
		t.Fatalf("capture id = %s, want C-20261119-001", c1.ID)
	}
	if c1.SourceID != domain.ImplicitSourceID || c1.ExternalID != nil || c1.State != domain.Pending || c1.Revision != 1 {
		t.Fatalf("unexpected capture defaults: %+v", c1)
	}
	if c1.ContentHash != sha256hex("hola") {
		t.Fatalf("content hash = %s, want sha256 of the original text", c1.ContentHash)
	}

	// Same key + same payload replays the stored result, even "later".
	later := e.now.Add(time.Hour)
	replay, err := e.s.Capture(ctx, app.CaptureCmd{Binding: e.binding, Key: "k1", Text: "hola"}, later)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	a, _ := json.Marshal(c1)
	b, _ := json.Marshal(replay)
	if string(a) != string(b) {
		t.Fatalf("replay differs:\n%s\n%s", a, b)
	}
	legacyReplay, err := e.s.Capture(ctx, app.CaptureCmd{
		Binding: e.binding, Key: "k1", Text: "hola", SourceID: "manual",
	}, later)
	if err != nil {
		t.Fatalf("replay with the pre-upgrade manual source default: %v", err)
	}
	if legacyReplay.ID != c1.ID {
		t.Fatalf("pre-upgrade replay ID = %s, want %s", legacyReplay.ID, c1.ID)
	}
	if n := e.count(`SELECT count(*) FROM captures`); n != 1 {
		t.Fatalf("captures after replay = %d, want 1", n)
	}

	// Same key + different payload fails and writes nothing.
	_, err = e.s.Capture(ctx, app.CaptureCmd{Binding: e.binding, Key: "k1", Text: "otra cosa"}, e.now)
	wantFamily(t, err, domain.IdempotencyConflict)
	if n := e.count(`SELECT count(*) FROM captures`); n != 1 {
		t.Fatalf("captures after conflict = %d, want 1", n)
	}
	if n := e.count(`SELECT count(*) FROM idempotency_records`); n != 1 {
		t.Fatalf("idempotency_records after conflict = %d, want 1", n)
	}

	// Manual duplicate text with a different key is legitimate.
	c2, err := e.s.Capture(ctx, app.CaptureCmd{Binding: e.binding, Key: "k2", Text: "hola"}, e.now)
	if err != nil {
		t.Fatalf("duplicate manual text: %v", err)
	}
	if c2.ID != "C-20261119-002" {
		t.Fatalf("second capture id = %s, want C-20261119-002", c2.ID)
	}

	// External identity: first insert wins, exact duplicate triple conflicts.
	e.mustAddSource("github", "personal")
	eid, erev := "gh-42", "3"
	ext, err := e.s.Capture(ctx, app.CaptureCmd{
		Binding: e.binding, Key: "k3", Text: "issue triage",
		SourceID: "github", ExternalID: &eid, ExternalRev: &erev,
	}, e.now)
	if err != nil {
		t.Fatalf("external capture: %v", err)
	}
	if ext.SourceID != "github" || ext.ExternalID == nil || *ext.ExternalID != "gh-42" {
		t.Fatalf("unexpected external capture: %+v", ext)
	}
	_, err = e.s.Capture(ctx, app.CaptureCmd{
		Binding: e.binding, Key: "k4", Text: "different text, same identity",
		SourceID: "github", ExternalID: &eid, ExternalRev: &erev,
	}, e.now)
	wantFamily(t, err, domain.Conflict)
	if n := e.count(`SELECT count(*) FROM captures`); n != 3 {
		t.Fatalf("captures after duplicate external identity = %d, want 3", n)
	}
}

// TestTwoHandleIdempotency exercises the contract across two independent
// handles on the same file: a concurrent race and a later sequential replay
// must both converge on the single stored capture.
func TestTwoHandleIdempotency(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ztd.db")
	a := openTestStore(t, path)
	if err := a.SeedDefaults(context.Background(), "tester"); err != nil {
		t.Fatal(err)
	}
	b := openTestStore(t, path)
	binding := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal", "opensource"}}
	now := time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC)
	cmd := app.CaptureCmd{Binding: binding, Key: "race-1", Text: "same payload"}

	var wg sync.WaitGroup
	got := make([]domain.Capture, 2)
	errs := make([]error, 2)
	start := make(chan struct{})
	for i, st := range []*Store{a, b} {
		wg.Add(1)
		go func(i int, st *Store) {
			defer wg.Done()
			<-start
			got[i], errs[i] = st.Capture(context.Background(), cmd, now)
		}(i, st)
	}
	close(start)
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("handle %d: %v", i, err)
		}
	}
	if got[0].ID != got[1].ID {
		t.Fatalf("concurrent captures disagree: %s vs %s", got[0].ID, got[1].ID)
	}
	// A sequential replay through either handle returns the same identity.
	replay, err := b.Capture(context.Background(), cmd, now.Add(2*time.Hour))
	if err != nil {
		t.Fatalf("sequential replay on second handle: %v", err)
	}
	if replay.ID != got[0].ID {
		t.Fatalf("replay id = %s, want %s", replay.ID, got[0].ID)
	}
	var n int
	if err := a.db.QueryRow(`SELECT count(*) FROM captures`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("captures = %d, want exactly 1", n)
	}
}

func TestScopeIsolation(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("private note", "k1")
	items := e.mustProcess(c.ID, "p1", 1, "findable secret task").WorkItems
	if len(items) != 1 {
		t.Fatalf("got %d work items", len(items))
	}
	outside := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	onlyPersonal := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}

	if _, err := e.s.GetCapture(e.ctx(), outside, c.ID); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("cross-scope GetCapture: got %v, want scope_denied", err)
	}
	if _, err := e.s.GetCapture(e.ctx(), outside, "C-20261119-999"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("missing GetCapture: got %v, want not_found", err)
	}
	if got, err := e.s.GetCapture(e.ctx(), onlyPersonal, c.ID); err != nil || got.ID != c.ID {
		t.Fatalf("same-scope GetCapture: %v", err)
	}
	if _, err := e.s.InboxNext(e.ctx(), outside, e.now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("cross-scope InboxNext: got %v, want not_found", err)
	}
	if _, err := e.s.GetWorkItem(e.ctx(), outside, items[0].ID); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("cross-scope GetWorkItem: got %v, want scope_denied", err)
	}
	if got, err := e.s.ListWorkItems(e.ctx(), outside, ""); err != nil || len(got) != 0 {
		t.Fatalf("cross-scope ListWorkItems leaked %d rows (err %v)", len(got), err)
	}
	if got, err := e.s.ListWorkItems(e.ctx(), e.binding, ""); err != nil || len(got) != 1 {
		t.Fatalf("same-scope ListWorkItems = %d rows (err %v), want 1", len(got), err)
	}
	if got, err := e.s.Find(e.ctx(), outside, "secret", 0); err != nil || len(got) != 0 {
		t.Fatalf("cross-scope Find leaked %d rows (err %v)", len(got), err)
	}
	if got, err := e.s.Find(e.ctx(), e.binding, "secret", 0); err != nil || len(got) != 1 {
		t.Fatalf("same-scope Find = %d rows (err %v), want 1", len(got), err)
	}
	// A binding without scopes is rejected before any SQL runs.
	if _, err := e.s.GetCapture(e.ctx(), domain.ScopeBinding{Profile: "personal", Actor: "tester"}, c.ID); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("empty-scope binding: got %v, want invalid_input", err)
	}
}
