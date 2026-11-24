package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func TestReferenceIsAtomicReadableAndRetryable(t *testing.T) {
	e := newTestEnv(t)
	c := e.capture("registry locking research", "capture")
	page := app.DocumentCmd{Kind: domain.DocumentKnowledge, Slug: "locking", Title: "Registry locking", Body: "Use compare-and-swap.", Status: domain.DocumentDraft, Sources: []string{"https://example.org/spec"}}
	cmd := app.ProcessCmd{Binding: e.binding, ID: c.ID, Expected: c.Revision, Key: "reference", Outcome: domain.Outcome{Kind: domain.OutcomeReference, Reason: "reusable finding"}, Document: &page}
	out, err := e.s.Process(e.ctx(), cmd, e.now)
	if err != nil {
		t.Fatal(err)
	}
	again, err := e.s.Process(e.ctx(), cmd, e.now.Add(time.Hour))
	if err != nil || again.Capture.Outcome.DocumentID != out.Capture.Outcome.DocumentID {
		t.Fatalf("replay: %+v %v", again, err)
	}
	read, err := e.s.GetCapture(e.ctx(), e.binding, c.ID)
	if err != nil || read.Outcome.Reason != "reusable finding" || read.Outcome.DocumentID == "" {
		t.Fatalf("outcome lost: %+v %v", read, err)
	}
	doc, err := e.s.GetDocument(e.ctx(), e.binding, domain.DocumentKnowledge, "locking")
	if err != nil || len(doc.Sources) != 1 {
		t.Fatalf("page: %+v %v", doc, err)
	}
	if e.count("SELECT count(*) FROM documents") != 1 {
		t.Fatal("duplicate page")
	}
	// A stale page update must roll back capture processing as well.
	c2 := e.capture("follow up", "capture2")
	cmd.ID = c2.ID
	cmd.Key = "reference2"
	cmd.Document = &page
	page.Expected = 99
	before := e.counts()
	_, err = e.s.Process(e.ctx(), cmd, e.now)
	wantFamily(t, err, domain.StaleRevision)
	if e.counts() != before {
		t.Fatal("failed processing wrote state")
	}
	still, err := e.s.GetCapture(e.ctx(), e.binding, c2.ID)
	if err != nil || still.State != domain.Pending {
		t.Fatalf("capture changed: %+v %v", still, err)
	}
}

func TestKnowledgeScopeProjectAndCreateOnly(t *testing.T) {
	e := newTestEnv(t)
	svc := app.New(e.s)
	_, err := e.s.AddProject(e.ctx(), app.ProjectCmd{Binding: e.binding, ID: "p", Status: "active", DesiredOutcome: "Ship"}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	project := domain.ProjectID("p")
	cmd := app.DocumentCmd{Binding: e.binding, Scope: "personal", Slug: "facts", Title: "Facts", Body: "registry facts", Sources: []string{"source"}, ProjectID: &project}
	d, err := svc.SaveKnowledge(e.ctx(), cmd)
	if err != nil {
		t.Fatal(err)
	}
	hits, err := svc.SearchKnowledge(e.ctx(), e.binding, app.KnowledgeQuery{Query: "registry", Project: "p"})
	if err != nil || len(hits) != 1 {
		t.Fatalf("search: %+v %v", hits, err)
	}
	hits, err = svc.SearchKnowledge(e.ctx(), e.binding, app.KnowledgeQuery{Query: "registry", Project: "other"})
	if err != nil || len(hits) != 0 {
		t.Fatalf("project filter: %+v %v", hits, err)
	}
	restricted := e.binding
	restricted.Scopes = []domain.ScopeID{"opensource"}
	_, err = svc.ReadKnowledge(e.ctx(), restricted, "personal", "facts")
	wantFamily(t, err, domain.ScopeDenied)
	cmd.Binding = restricted
	_, err = svc.SaveKnowledge(e.ctx(), cmd)
	wantFamily(t, err, domain.ScopeDenied)
	cmd.Binding = e.binding
	cmd.Body = "changed"
	_, err = svc.SaveKnowledge(e.ctx(), cmd)
	if err == nil {
		t.Fatal("revision 0 overwrote existing page")
	}
	cmd.Expected = d.Revision
	updated, err := svc.SaveKnowledge(e.ctx(), cmd)
	if err != nil || updated.Revision != 2 {
		t.Fatalf("update: %+v %v", updated, err)
	}
	// A project in another scope cannot be attached to a page.
	cmd.Scope = "opensource"
	cmd.Expected = 0
	_, err = svc.SaveKnowledge(e.ctx(), cmd)
	wantFamily(t, err, domain.ScopeDenied)
}

func TestPartialPlanPreservesHiddenTasksAndReason(t *testing.T) {
	e := newTestEnv(t)
	personal := e.workItems(2, "personal")
	other := e.binding
	other.Scopes = []domain.ScopeID{"opensource"}
	c, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: other, Key: "other-cap", Text: "hidden"}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	res, err := e.s.Process(e.ctx(), app.ProcessCmd{Binding: other, Key: "other-process", ID: c.ID, Outcome: domain.Outcome{Kind: domain.OutcomeWorkItems, Titles: []string{"private task"}}}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	hidden := res.WorkItems[0].ID
	plan, err := e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{Binding: e.binding, Key: "plan", Kind: domain.DailyPlan, Period: "2026-11-19", ExceptionReason: "private context", Items: []domain.PlanItem{{WorkItemID: personal[0].ID, Role: domain.MITRole}, {WorkItemID: hidden, Role: domain.MITRole}}}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	narrow := e.binding
	narrow.Scopes = []domain.ScopeID{"personal"}
	visible, err := e.s.ReadPlan(e.ctx(), narrow, domain.DailyPlan, "2026-11-19")
	if err != nil || len(visible.Items) != 1 || visible.ExceptionReason != "" {
		t.Fatalf("partial read: %+v %v", visible, err)
	}
	brief, err := e.s.Prepare(e.ctx(), narrow, "2026-11-19")
	if err != nil || len(brief.Plan.Items) != 1 || brief.Plan.ExceptionReason != "" {
		t.Fatalf("brief: %+v %v", brief, err)
	}
	_, err = e.s.CommitPlan(e.ctx(), app.CommitPlanCmd{Binding: narrow, Key: "patch", Kind: domain.DailyPlan, Period: "2026-11-19", Expected: plan.Revision, Items: []domain.PlanItem{{WorkItemID: personal[1].ID, Role: domain.MITRole}}}, e.now)
	if err != nil {
		t.Fatal(err)
	}
	full, err := e.s.ReadPlan(e.ctx(), e.binding, domain.DailyPlan, "2026-11-19")
	if err != nil || len(full.Items) != 2 || full.ExceptionReason != "private context" {
		t.Fatalf("preserved: %+v %v", full, err)
	}
	if full.Items[1].WorkItemID != hidden {
		t.Fatal("hidden task lost")
	}
}

func TestTaskPatchRetryAfterFurtherEdits(t *testing.T) {
	e := newTestEnv(t)
	w := e.workItems(1, "task")[0]
	svc := app.New(e.s)
	title := "renamed"
	first := app.TaskUpdate{ID: w.ID, Key: "rename", Expected: w.Revision, Title: &title}
	out, err := svc.UpdateTask(e.ctx(), e.binding, first)
	if err != nil {
		t.Fatal(err)
	}
	resolution := "verified result"
	closed, err := svc.UpdateTask(e.ctx(), e.binding, app.TaskUpdate{ID: w.ID, Key: "done", Expected: out.Revision, Status: "completed", Resolution: &resolution})
	if err != nil {
		t.Fatal(err)
	}
	replay, err := svc.UpdateTask(e.ctx(), e.binding, first)
	if err != nil || replay.Revision != out.Revision {
		t.Fatalf("original retry: %+v %v", replay, err)
	}
	current, err := e.s.GetWorkItem(e.ctx(), e.binding, w.ID)
	if err != nil || current.Task().Status != "completed" || current.Revision != closed.Revision {
		t.Fatalf("retry changed newer state: %+v %v", current, err)
	}
	var status string
	if err := e.s.db.QueryRow("SELECT status FROM work_items WHERE id=?", w.ID).Scan(&status); err != nil || status != "completed" {
		t.Fatalf("stored state: %s %v", status, err)
	}
}

func legacySchema(t *testing.T, path string) *Store {
	t.Helper()
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	ms, err := loadMigrations()
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range ms {
		if m.version > 7 {
			break
		}
		if err := s.applyMigration(context.Background(), m); err != nil {
			t.Fatal(err)
		}
	}
	return s
}
func seedLegacyModel(t *testing.T, s *Store) {
	t.Helper()
	_, err := s.db.Exec(`
 INSERT INTO scopes VALUES('personal','Personal','personal','2026-11-19T09:00:00Z'),('client:acme','Acme','client','2026-11-19T09:00:00Z');
 INSERT INTO profiles VALUES('personal','Personal','personal','alice','Europe/Madrid','active');
 INSERT INTO profile_scopes VALUES('personal','personal'),('personal','client:acme');
 INSERT INTO knowledge_records VALUES('K1','personal','fact','registry one','current','verified','["source"]',NULL,NULL,NULL,1,'2026-11-19T09:00:00Z');
 INSERT INTO knowledge_records VALUES('K2','personal','decision','registry two','current','draft','[]',NULL,NULL,'K1',1,'2026-11-19T09:00:00Z');
 INSERT INTO reviews VALUES('R1','personal','daily','2026-11-19','mixed private content','partial','partial','2026-11-19T09:00:00Z',1);
 INSERT INTO documents VALUES('D1','personal','knowledge','same','First','alpha registry','draft',1,'2026-11-19T09:00:00Z','2026-11-19T09:00:00Z');
 INSERT INTO documents VALUES('D2','personal','journal','same','Second','beta registry','verified',1,'2026-11-19T09:00:00Z','2026-11-19T09:00:00Z');
 INSERT INTO work_items(id,scope_id,title,lifecycle,closure_kind,closed_at,resolution,revision,created_at,updated_at) VALUES('T-20261119-001','personal','old closure','archived','unspecified','2026-11-19T09:00:00Z','unknown historical result',1,'2026-11-19T09:00:00Z','2026-11-19T09:00:00Z');
 INSERT INTO history_events(entity_type,entity_id,scope_id,event,revision,payload_json,created_at) VALUES('work_item','T-20261119-001','personal','imported',1,'{}','2026-11-19T09:00:00Z');
 `)
	if err != nil {
		t.Fatal(err)
	}
}
func TestUpgradePreservesKnowledgeAndAmbiguousHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	old := legacySchema(t, path)
	seedLegacyModel(t, old)
	old.Close()
	s := openTestStore(t, path)
	b := domain.ScopeBinding{Profile: "personal", Actor: "alice", Scopes: []domain.ScopeID{"personal"}}
	docs, err := s.ListDocuments(context.Background(), b, "")
	if err != nil || len(docs) != 4 {
		t.Fatalf("documents: %d %v", len(docs), err)
	}
	d, err := s.GetDocument(context.Background(), b, domain.DocumentJournal, "same")
	if err != nil || d.ID != "D2" || d.Slug == "same" {
		t.Fatalf("collision alias: %+v %v", d, err)
	}
	w, err := s.GetWorkItem(context.Background(), b, "T-20261119-001")
	if err != nil || w.Task().Status != "closed_unknown" {
		t.Fatalf("closure: %+v %v", w, err)
	}
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM legacy_records WHERE entity_type='review' AND disposition='quarantined'").Scan(&count); err != nil || count != 1 {
		t.Fatalf("ambiguous review: %d %v", count, err)
	}
	snapshots, err := filepath.Glob(path + ".before-v13-*.db")
	if err != nil || len(snapshots) != 1 {
		t.Fatalf("snapshot: %v %v", snapshots, err)
	}
	check, err := s.Check(context.Background(), nil)
	if err != nil || !check.OK {
		t.Fatalf("integrity: %+v %v", check, err)
	}
	export := filepath.Join(t.TempDir(), "export.json")
	if err := s.Export(context.Background(), export); err != nil {
		t.Fatal(err)
	}
	dst := openTestStore(t, filepath.Join(t.TempDir(), "restore.db"))
	if _, err := dst.Restore(context.Background(), export); err != nil {
		t.Fatal(err)
	}
	hits, err := dst.SearchDocuments(context.Background(), b, "registry", "", 10)
	if err != nil || len(hits) != 4 {
		t.Fatalf("restored search: %d %v", len(hits), err)
	}
}

func TestRestoreVersionOneExport(t *testing.T) {
	old := legacySchema(t, filepath.Join(t.TempDir(), "v1.db"))
	defer old.Close()
	seedLegacyModel(t, old)
	doc := exportDoc{Format: "ztd-export", Version: 1, Tables: map[string][]map[string]any{}}
	names := strings.Fields("scopes profiles profile_scopes contexts areas projects documents captures sources source_reviews work_items plans plan_items routines knowledge_records daily_limit_overrides calendar_review_assertions focus_sessions checkpoints reviews history_events idempotency_records import_runs legacy_records")
	for _, name := range names {
		rows, err := old.db.Query("SELECT * FROM " + name)
		if err != nil {
			t.Fatal(err)
		}
		cols, err := rows.Columns()
		if err != nil {
			t.Fatal(err)
		}
		doc.Tables[name] = []map[string]any{}
		for rows.Next() {
			values := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range values {
				ptrs[i] = &values[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				t.Fatal(err)
			}
			row := map[string]any{}
			for i, col := range cols {
				row[col] = jsonValue(values[i])
			}
			doc.Tables[name] = append(doc.Tables[name], row)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "old.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	dst := openTestStore(t, filepath.Join(t.TempDir(), "restored.db"))
	if _, err := dst.Restore(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	check, err := dst.Check(context.Background(), nil)
	if err != nil || !check.OK {
		t.Fatalf("legacy restore check: %+v %v", check, err)
	}
}

func TestUpgradeDoesNotChooseBetweenActiveGoals(t *testing.T) {
	path := filepath.Join(t.TempDir(), "goals.db")
	old := legacySchema(t, path)
	seedLegacyModel(t, old)
	_, err := old.db.Exec(`
 INSERT INTO profiles VALUES('second','Second','work_client','alice','UTC','active');
 INSERT INTO profile_scopes VALUES('second','personal');
 INSERT INTO goals VALUES('G1','personal','primary','2026-11-19',NULL,'First direction','active','2026-11-19T09:00:00Z','2026-11-19T09:00:00Z');
 INSERT INTO goals VALUES('G2','second','primary','2026-11-19',NULL,'Second direction','active','2026-11-19T09:00:00Z','2026-11-19T09:00:00Z');
 `)
	if err != nil {
		t.Fatal(err)
	}
	old.Close()
	s := openTestStore(t, path)
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM goals WHERE scope_id IS NULL AND status='active'").Scan(&count); err != nil || count != 2 {
		t.Fatalf("unassigned goals: %d %v", count, err)
	}
	check, err := s.Check(context.Background(), nil)
	if err != nil || !check.OK || len(check.Warnings) < 2 {
		t.Fatalf("check: %+v %v", check, err)
	}
}
