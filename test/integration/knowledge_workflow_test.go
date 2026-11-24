package integration

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestKnowledgeAgentWorkflow(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)
	cs := mcpConnect(t, db)
	cap := scCapture(t, "capture", mcpCall(t, cs, "capture", map[string]any{"idempotency_key": "wiki-capture", "text": "Remember the cedar procedure"}))
	request := map[string]any{
		"idempotency_key": "wiki-process", "capture_id": cap.ID, "outcome": "reference",
		"document": map[string]any{"scope": "personal", "slug": "cedar", "title": "Cedar procedure", "body": "Read the cedar evidence first.", "sources": []string{"https://example.org/evidence"}, "expected_revision": 0},
	}
	first := mcpCall(t, cs, "process_capture", request)
	wantToolOK(t, "process_capture", first)
	retry := mcpCall(t, cs, "process_capture", request)
	wantToolOK(t, "process_capture", retry)
	if scJSON(t, first) != scJSON(t, retry) {
		t.Fatal("reference replay changed result")
	}
	read := mcpCall(t, cs, "knowledge_read", map[string]any{"scope": "personal", "slug": "cedar"})
	wantToolOK(t, "knowledge_read", read)
	var page documentData
	scUnmarshal(t, "knowledge_read", read, &page)
	if page.Revision != 1 || page.Status != "draft" {
		t.Fatalf("page = %+v", page)
	}
	found := mcpCall(t, cs, "knowledge_search", map[string]any{"scope": "personal", "query": "cedar"})
	wantToolOK(t, "knowledge_search", found)
	if !strings.Contains(scJSON(t, found), page.ID) {
		t.Fatalf("missing search hit: %s", scJSON(t, found))
	}
	save := map[string]any{"scope": "personal", "slug": "cedar", "title": "Cedar procedure", "body": "Revised cedar evidence.", "expected_revision": 1}
	wantToolOK(t, "knowledge_save", mcpCall(t, cs, "knowledge_save", save))
	save["expected_revision"] = 0
	if !mcpCall(t, cs, "knowledge_save", save).IsError {
		t.Fatal("create-only overwrote page")
	}
	if !mcpCall(t, cs, "knowledge_read", map[string]any{"scope": "client:private", "slug": "cedar"}).IsError {
		t.Fatal("read escaped binding")
	}
	wantToolOK(t, "knowledge_related", mcpCall(t, cs, "knowledge_related", map[string]any{"scope": "personal", "slug": "cedar"}))
	cliPage := decode[documentData](t, run(t, db, "knowledge", "read", "--scope", "personal", "--slug", "cedar").wantOK(t, "knowledge read"))
	if cliPage.Revision != 2 || cliPage.Body != "Revised cedar evidence." {
		t.Fatalf("CLI page = %+v", cliPage)
	}

	taskCap := scCapture(t, "capture", mcpCall(t, cs, "capture", map[string]any{"idempotency_key": "wiki-task", "text": "Apply cedar"}))
	processed := scDecodeProcess(t, mcpCall(t, cs, "process_capture", map[string]any{"idempotency_key": "wiki-task-process", "capture_id": taskCap.ID, "outcome": "work_items", "titles": []string{"Apply cedar"}}))
	task := processed.WorkItems[0]
	wantToolOK(t, "commit_plan", mcpCall(t, cs, "commit_plan", map[string]any{"idempotency_key": "wiki-plan", "kind": "weekly", "period": "2026-W48", "items": []map[string]any{{"work_item_id": task.ID}}}))
	wantToolOK(t, "plan_show", mcpCall(t, cs, "plan_show", map[string]any{"kind": "weekly", "period": "2026-W48"}))
	done := mcpCall(t, cs, "task_update", map[string]any{"idempotency_key": "wiki-done", "id": task.ID, "expected_revision": 1, "status": "completed", "resolution": "Applied"})
	wantToolOK(t, "task_update", done)
	if !strings.Contains(scJSON(t, done), `"status":"completed"`) {
		t.Fatalf("task: %s", scJSON(t, done))
	}
	run(t, db, "review", "save", "--scope", "personal", "--kind", "weekly", "--period", "2026-W48", "--outcomes", "Applied cedar", "--coverage", "local").wantOK(t, "review save")
	wantToolOK(t, "review_show", mcpCall(t, cs, "review_show", map[string]any{"scope": "personal", "kind": "weekly", "period": "2026-W48"}))
}
