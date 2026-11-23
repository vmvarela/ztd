package integration

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpConnect starts the real ztd binary as an MCP stdio server bound to db.
// HOME and TMPDIR are scrubbed exactly like run so nothing falls back to the
// real user home; --db pins the same database every other command uses. The
// implicit personal profile is resolved without any flag.
func mcpConnect(t *testing.T, db string) *mcp.ClientSession {
	t.Helper()
	return mcpConnectArgs(t, db)
}

func mcpConnectArgs(t *testing.T, db string, args ...string) *mcp.ClientSession {
	t.Helper()
	base := []string{"--db", db, "mcp"}
	cmd := exec.Command(binPath, append(base, args...)...)
	home := t.TempDir()
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + home,
		"USERPROFILE=" + home,
		"TMPDIR=" + t.TempDir(),
		"USER=ztd-test",
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "ztd-integration", Version: "test"}, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cs, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		t.Fatalf("connect mcp over stdio: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// mcpCall issues one tools/call under a bounded context so a wedged server
// fails the test instead of hanging it. Protocol errors (unknown tool, broken
// pipe) are fatal here; tool-level errors arrive as isError results.
func mcpCall(t *testing.T, cs *mcp.ClientSession, name string, args any) *mcp.CallToolResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return res
}

func mcpListTools(t *testing.T, cs *mcp.ClientSession) []*mcp.Tool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	return res.Tools
}

func wantToolOK(t *testing.T, name string, res *mcp.CallToolResult) {
	t.Helper()
	if res.IsError {
		t.Fatalf("%s: isError=true, want success; content: %s", name, toolText(res))
	}
	if res.StructuredContent == nil {
		t.Fatalf("%s: structured content is nil", name)
	}
}

func scBytes(t *testing.T, res *mcp.CallToolResult) []byte {
	t.Helper()
	b, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatalf("marshal structured content: %v", err)
	}
	return b
}

func scJSON(t *testing.T, res *mcp.CallToolResult) string {
	t.Helper()
	return string(scBytes(t, res))
}

func scUnmarshal(t *testing.T, name string, res *mcp.CallToolResult, v any) {
	t.Helper()
	if err := json.Unmarshal(scBytes(t, res), v); err != nil {
		t.Fatalf("%s: decode structured content %s: %v", name, scJSON(t, res), err)
	}
}

// scCapture accepts either a bare capture object or a {capture: ...} envelope,
// because the tool result shape is owned by the mcpserver lane.
func scCapture(t *testing.T, name string, res *mcp.CallToolResult) captureData {
	t.Helper()
	wantToolOK(t, name, res)
	var direct captureData
	scUnmarshal(t, name, res, &direct)
	if direct.ID != "" {
		return direct
	}
	var wrapped struct {
		Capture captureData `json:"capture"`
	}
	scUnmarshal(t, name, res, &wrapped)
	if wrapped.Capture.ID == "" {
		t.Fatalf("%s: no capture in structured content %s", name, scJSON(t, res))
	}
	return wrapped.Capture
}

func scDecodeProcess(t *testing.T, res *mcp.CallToolResult) processData {
	t.Helper()
	wantToolOK(t, "process_capture", res)
	var pr processData
	scUnmarshal(t, "process_capture", res, &pr)
	return pr
}

// scFocus accepts the wrapped {focus, checkpoints} shape or a bare FocusSession.
func scFocus(t *testing.T, res *mcp.CallToolResult) focusData {
	t.Helper()
	var wrapped focusStartData
	scUnmarshal(t, "focus_start", res, &wrapped)
	if wrapped.Focus.ID != "" {
		return focusData{ID: wrapped.Focus.ID, WorkItemID: wrapped.Focus.WorkItemID}
	}
	var flat focusData
	scUnmarshal(t, "focus_start", res, &flat)
	if flat.ID == "" {
		t.Fatalf("focus_start: no focus in structured content %s", scJSON(t, res))
	}
	return flat
}

func toolText(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
			b.WriteString("\n")
		}
	}
	return b.String()
}

// structuredHas walks whatever JSON the server returned so find/read results
// assert on IDs without pinning their container shape.
func structuredHas(t *testing.T, res *mcp.CallToolResult, want string) bool {
	t.Helper()
	var v any
	if err := json.Unmarshal(scBytes(t, res), &v); err != nil {
		t.Fatalf("decode structured content: %v", err)
	}
	return containsString(v, want)
}

func containsString(v any, want string) bool {
	switch x := v.(type) {
	case string:
		return x == want
	case []any:
		for _, e := range x {
			if containsString(e, want) {
				return true
			}
		}
	case map[string]any:
		for _, e := range x {
			if containsString(e, want) {
				return true
			}
		}
	}
	return false
}

var mcpToolNames = []string{
	"capture", "inbox_next", "process_capture", "prepare",
	"commit_plan", "focus_start", "checkpoint", "focus_finish",
	"record_review", "find", "read",
	"sources", "record_source_review",
	"doc_search", "doc_get", "doc_related",
}

// TestMCPStdioJourney drives the real binary as an MCP stdio server: the tool
// listing, the capture-to-review journey, a lost-response replay with the same
// idempotency key, find without a limit, and the read bound of 5 IDs.
func TestMCPStdioJourney(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	period := time.Now().UTC().Format("2006-01-02")
	run(t, db, "init",
		"--scope", "id=personal,kind=personal",
		"--scope", "id=opensource,kind=opensource",
	).wantOK(t, "init")

	cs := mcpConnect(t, db)

	tools := mcpListTools(t, cs)
	if len(tools) != len(mcpToolNames) {
		t.Errorf("listed %d tools, want %d", len(tools), len(mcpToolNames))
	}
	have := make(map[string]bool, len(tools))
	for _, tool := range tools {
		have[tool.Name] = true
	}
	for _, name := range mcpToolNames {
		if !have[name] {
			t.Errorf("tool %q not listed", name)
		}
	}

	// capture: structured content carries the durable identity.
	capText := "write the quarterly report over mcp"
	capKey := "mcp-capture-1"
	capRes := mcpCall(t, cs, "capture", map[string]any{
		"idempotency_key": capKey,
		"text":            capText,
	})
	cap := scCapture(t, "capture", capRes)
	if !captureIDRe.MatchString(cap.ID) {
		t.Fatalf("capture id = %q, want C-YYYYMMDD-NNN", cap.ID)
	}
	if cap.State != "pending" || cap.OriginalText != capText || cap.Scope != "personal" {
		t.Fatalf("capture = %+v, want pending personal capture of %q", cap, capText)
	}

	// inbox_next: same capture, oldest pending first, plus remaining counts.
	nextRes := mcpCall(t, cs, "inbox_next", nil)
	wantToolOK(t, "inbox_next", nextRes)
	var nextEnv struct {
		Capture captureData `json:"capture"`
		Stats   struct {
			Pending   int `json:"pending"`
			Due       int `json:"due"`
			Remaining int `json:"remaining"`
		} `json:"stats"`
	}
	scUnmarshal(t, "inbox_next", nextRes, &nextEnv)
	if nextEnv.Capture.ID != cap.ID {
		t.Fatalf("inbox_next id = %q, want the captured %q", nextEnv.Capture.ID, cap.ID)
	}
	if nextEnv.Stats.Pending != 1 || nextEnv.Stats.Remaining != 1 {
		t.Fatalf("inbox_next stats = %+v, want pending=1 remaining=1", nextEnv.Stats)
	}

	// process_capture: one work item from the pending capture.
	title := "Draft quarterly report"
	pr := scDecodeProcess(t, mcpCall(t, cs, "process_capture", map[string]any{
		"idempotency_key": "mcp-process-1",
		"capture_id":      cap.ID,
		"outcome":         "work_items",
		"titles":          []string{title},
	}))
	if pr.Capture.ID != cap.ID || pr.Capture.State != "processed" {
		t.Fatalf("processed capture = %+v, want %s processed", pr.Capture, cap.ID)
	}
	if len(pr.WorkItems) != 1 {
		t.Fatalf("work items = %d, want 1", len(pr.WorkItems))
	}
	item := pr.WorkItems[0]
	if !workItemIDRe.MatchString(item.ID) || item.Title != title || item.OriginCaptureID != cap.ID {
		t.Fatalf("work item = %+v, want a %s titled %q from %s", item, workItemIDRe, title, cap.ID)
	}

	// prepare: today's brief contains the new next action.
	briefRes := mcpCall(t, cs, "prepare", map[string]any{"date": period})
	wantToolOK(t, "prepare", briefRes)
	var brief prepareData
	scUnmarshal(t, "prepare", briefRes, &brief)
	if brief.Date != period {
		t.Fatalf("prepare date = %q, want %q", brief.Date, period)
	}
	if !containsID(brief.Next, item.ID) {
		t.Fatalf("prepare next = %+v, want %s", brief.Next, item.ID)
	}

	// commit_plan: one MIT for today.
	planRes := mcpCall(t, cs, "commit_plan", map[string]any{
		"idempotency_key": "mcp-plan-1",
		"kind":            "daily",
		"period":          period,
		"items":           []map[string]any{{"work_item_id": item.ID, "role": "mit"}},
	})
	wantToolOK(t, "commit_plan", planRes)
	var plan planData
	scUnmarshal(t, "commit_plan", planRes, &plan)
	if plan.ID != "P-personal-daily-"+period || plan.Status != "committed" || plan.Revision != 1 {
		t.Fatalf("plan = %+v, want committed revision 1 for %s", plan, period)
	}
	if len(plan.Items) != 1 || plan.Items[0].WorkItemID != item.ID || plan.Items[0].Role != "mit" {
		t.Fatalf("plan items = %+v, want [%s mit]", plan.Items, item.ID)
	}

	// focus: start, checkpoint, finish.
	fsRes := mcpCall(t, cs, "focus_start", map[string]any{
		"idempotency_key": "mcp-focus-1",
		"work_item_id":    item.ID,
	})
	wantToolOK(t, "focus_start", fsRes)
	focus := scFocus(t, fsRes)
	if !focusIDRe.MatchString(focus.ID) || focus.WorkItemID != item.ID {
		t.Fatalf("focus start = %+v, want F-YYYYMMDD-NNN on %s", focus, item.ID)
	}

	cpRes := mcpCall(t, cs, "checkpoint", map[string]any{
		"idempotency_key": "mcp-checkpoint-1",
		"work_item_id":    item.ID,
		"result":          "halfway through",
	})
	wantToolOK(t, "checkpoint", cpRes)
	var cp checkpointData
	scUnmarshal(t, "checkpoint", cpRes, &cp)
	if cp.WorkItemID != item.ID || cp.Result != "halfway through" {
		t.Fatalf("checkpoint = %+v, want result on %s", cp, item.ID)
	}

	finRes := mcpCall(t, cs, "focus_finish", map[string]any{
		"idempotency_key": "mcp-finish-1",
		"focus_id":        focus.ID,
		"outcome":         "done for now",
	})
	wantToolOK(t, "focus_finish", finRes)
	var fin focusData
	scUnmarshal(t, "focus_finish", finRes, &fin)
	if fin.ID != focus.ID || fin.EndedAt == nil {
		t.Fatalf("focus finish = %+v, want %s with ended_at", fin, focus.ID)
	}

	// review: complete daily review for today.
	revRes := mcpCall(t, cs, "record_review", map[string]any{
		"idempotency_key": "mcp-review-1",
		"kind":            "daily",
		"period":          period,
		"outcomes":        "captured and planned",
		"coverage":        "inbox+next",
	})
	wantToolOK(t, "record_review", revRes)
	var rev reviewData
	scUnmarshal(t, "record_review", revRes, &rev)
	if rev.Kind != "daily" || rev.CompletionState != "complete" {
		t.Fatalf("review = %+v, want a complete daily review", rev)
	}

	// find without a limit argument: default bound, item is visible.
	findRes := mcpCall(t, cs, "find", map[string]any{"query": "quarterly"})
	wantToolOK(t, "find", findRes)
	if !structuredHas(t, findRes, item.ID) {
		t.Fatalf("find does not return %s: %s", item.ID, scJSON(t, findRes))
	}

	// read within the 5-ID bound.
	readRes := mcpCall(t, cs, "read", map[string]any{"ids": []string{cap.ID, item.ID}})
	wantToolOK(t, "read", readRes)
	for _, id := range []string{cap.ID, item.ID} {
		if !structuredHas(t, readRes, id) {
			t.Errorf("read does not return %s: %s", id, scJSON(t, readRes))
		}
	}

	// Lost-response replay: a fresh server process with the same key and the
	// same text must return the identity stored by the first call.
	if err := cs.Close(); err != nil {
		t.Fatalf("close first session: %v", err)
	}
	cs2 := mcpConnect(t, db)
	replay := scCapture(t, "capture replay", mcpCall(t, cs2, "capture", map[string]any{
		"idempotency_key": capKey,
		"text":            capText,
	}))
	if replay.ID != cap.ID {
		t.Fatalf("replay capture id = %q, want the original %q", replay.ID, cap.ID)
	}
	conflict := mcpCall(t, cs2, "capture", map[string]any{
		"idempotency_key": capKey,
		"text":            capText + " changed",
	})
	if !conflict.IsError || !strings.Contains(toolText(conflict), "idempotency_conflict") {
		t.Fatalf("same key with different text: want idempotency_conflict; content: %s", toolText(conflict))
	}

	// find with no limit still works after reconnect.
	wantToolOK(t, "find", mcpCall(t, cs2, "find", map[string]any{"query": "quarterly"}))

	// read accepts at most 5 IDs; the sixth is invalid_input.
	bigRead := mcpCall(t, cs2, "read", map[string]any{"ids": []string{
		cap.ID, item.ID, plan.ID, focus.ID, rev.ID, cp.ID,
	}})
	if !bigRead.IsError {
		t.Fatalf("read with 6 ids: isError=false, want true; content: %s", toolText(bigRead))
	}
	if text := toolText(bigRead); !strings.Contains(text, "invalid_input") {
		t.Fatalf("read error text = %q, want it to contain invalid_input", text)
	}

	// Scope boundary: a server bound to opensource must not reveal that a
	// personal capture exists, and must not name the foreign scope.
	foreign := mcpConnectArgs(t, db, "--scope", "opensource")
	hidden := mcpCall(t, foreign, "read", map[string]any{"ids": []string{cap.ID}})
	if !hidden.IsError {
		t.Fatalf("read foreign id: isError=false, want not_found; content: %s", toolText(hidden))
	}
	text := toolText(hidden)
	if !strings.Contains(text, "not_found") || strings.Contains(text, "personal") {
		t.Fatalf("read foreign id leaked scope: %q", text)
	}
}

// TestMCPSourceFlow covers the source boundary end to end: the operator
// registers a source through the CLI (registration is not a model tool), the
// model lists it, records a reported batch that becomes a pending capture,
// replays the same key without duplicating the capture, and is refused when it
// tries to claim observed coverage.
func TestMCPSourceFlow(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, "init",
		"--scope", "id=personal,kind=personal",
		"--scope", "id=opensource,kind=opensource",
	).wantOK(t, "init")
	run(t, db, "source", "add",
		"--id", "notes-dir", "--name", "Notes directory",
		"--scope", "personal", "--kind", "capture", "--connector", "directory",
	).wantOK(t, "source add")

	cs := mcpConnect(t, db)

	// sources: registry state for the fixed binding, no provider contents.
	sourcesRes := mcpCall(t, cs, "sources", nil)
	wantToolOK(t, "sources", sourcesRes)
	var sourcesEnv struct {
		Sources []struct {
			ID        string `json:"id"`
			Kind      string `json:"kind"`
			Connector string `json:"connector"`
			Coverage  string `json:"coverage"`
		} `json:"sources"`
	}
	scUnmarshal(t, "sources", sourcesRes, &sourcesEnv)
	if len(sourcesEnv.Sources) != 1 {
		t.Fatalf("sources = %+v, want exactly [notes-dir]", sourcesEnv.Sources)
	}
	src := sourcesEnv.Sources[0]
	if src.ID != "notes-dir" || src.Kind != "capture" || src.Connector != "directory" || src.Coverage != "unknown" {
		t.Fatalf("source = %+v, want notes-dir capture/directory coverage unknown", src)
	}

	// Record one reported item; it becomes a pending capture.
	itemText := "renew the parking permit before the trip"
	batchArgs := map[string]any{
		"source_id":       "notes-dir",
		"batch_id":        "batch-1",
		"idempotency_key": "mcp-source-1",
		"retrieval": map[string]any{
			"window": "2026-11-20", "cursor": "",
			"requested_limit": 50, "provider_returned_limit": 1,
			"complete_window": true, "truncated": false, "failures": []string{},
		},
		"items": []map[string]any{{
			"external_id": "note-001", "external_revision": "1",
			"original_text": itemText, "source_uri": "file:///notes/note-001.md",
			"provider_metadata_summary": "file note, title only",
		}},
	}
	reviewRes := mcpCall(t, cs, "record_source_review", batchArgs)
	wantToolOK(t, "record_source_review", reviewRes)
	var reviewEnv struct {
		Review struct {
			ID         string `json:"id"`
			SourceID   string `json:"source_id"`
			ResultKind string `json:"result_kind"`
			Coverage   string `json:"coverage"`
		} `json:"review"`
		Captures []captureData `json:"captures"`
	}
	scUnmarshal(t, "record_source_review", reviewRes, &reviewEnv)
	if reviewEnv.Review.SourceID != "notes-dir" || reviewEnv.Review.ResultKind != "reported" {
		t.Fatalf("review = %+v, want a reported review for notes-dir", reviewEnv.Review)
	}
	if reviewEnv.Review.Coverage != "unverified" {
		t.Fatalf("coverage = %q, want unverified: a model batch is never trusted", reviewEnv.Review.Coverage)
	}
	if len(reviewEnv.Captures) != 1 {
		t.Fatalf("captures = %+v, want exactly one new capture", reviewEnv.Captures)
	}
	batchCap := reviewEnv.Captures[0]
	if batchCap.OriginalText != itemText || batchCap.State != "pending" {
		t.Fatalf("capture = %+v, want a pending capture of %q", batchCap, itemText)
	}

	// Retry with the same key and payload: the stored result replays, so the
	// capture count in the inbox does not grow.
	retryRes := mcpCall(t, cs, "record_source_review", batchArgs)
	wantToolOK(t, "record_source_review", retryRes)
	var retryEnv struct {
		Review struct {
			ID string `json:"id"`
		} `json:"review"`
		Captures []captureData `json:"captures"`
	}
	scUnmarshal(t, "record_source_review", retryRes, &retryEnv)
	if retryEnv.Review.ID != reviewEnv.Review.ID {
		t.Fatalf("retry review id = %q, want the original %q", retryEnv.Review.ID, reviewEnv.Review.ID)
	}
	if len(retryEnv.Captures) != 1 || retryEnv.Captures[0].ID != batchCap.ID {
		t.Fatalf("retry captures = %+v, want the original %s only", retryEnv.Captures, batchCap.ID)
	}

	// The captured item shows up in the inbox as the oldest pending capture.
	nextRes := mcpCall(t, cs, "inbox_next", nil)
	wantToolOK(t, "inbox_next", nextRes)
	var nextEnv struct {
		Capture captureData `json:"capture"`
		Stats   struct {
			Pending   int `json:"pending"`
			Remaining int `json:"remaining"`
		} `json:"stats"`
	}
	scUnmarshal(t, "inbox_next", nextRes, &nextEnv)
	if nextEnv.Capture.ID != batchCap.ID || nextEnv.Capture.OriginalText != itemText {
		t.Fatalf("inbox_next = %+v, want the batch capture %s", nextEnv.Capture, batchCap.ID)
	}
	if nextEnv.Stats.Pending != 1 || nextEnv.Stats.Remaining != 1 {
		t.Fatalf("inbox stats = %+v, want a single pending capture after the retry", nextEnv.Stats)
	}

	// observed is refused at the model-facing boundary with invalid_input.
	observed := mcpCall(t, cs, "record_source_review", map[string]any{
		"source_id":       "notes-dir",
		"batch_id":        "batch-2",
		"idempotency_key": "mcp-source-observed",
		"result_kind":     "observed",
		"items":           []any{},
	})
	if !observed.IsError {
		t.Fatalf("observed batch: isError=false, want invalid_input; content: %s", toolText(observed))
	}
	if text := toolText(observed); !strings.Contains(text, "invalid_input") {
		t.Fatalf("observed batch error text = %q, want invalid_input", text)
	}
}

// TestMCPDocumentTools covers the read-only document tools over stdio:
// doc_search finds a stored card with rank and snippet, doc_get returns its
// body, doc_related returns its link neighbourhood, and a server bound to
// another scope answers not_found without disclosing the foreign document.
func TestMCPDocumentTools(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, initArgs...).wantOK(t, "init")
	run(t, db, "doc", "put", "--kind", "knowledge", "--slug", "komorebi/setup",
		"--title", "Komorebi setup", "--body", "the clone lives under repos/").wantOK(t, "doc put")
	run(t, db, "doc", "put", "--kind", "knowledge_index", "--slug", "index",
		"--title", "Index", "--body", "[[komorebi/setup]]").wantOK(t, "doc put")

	cs := mcpConnect(t, db)

	// doc_search: hits carry the document, its rank and a snippet.
	searchRes := mcpCall(t, cs, "doc_search", map[string]any{"query": "komorebi"})
	wantToolOK(t, "doc_search", searchRes)
	var searchEnv struct {
		Hits []struct {
			Document struct {
				Kind string `json:"kind"`
				Slug string `json:"slug"`
				Body string `json:"body"`
			} `json:"document"`
			Rank    float64 `json:"rank"`
			Snippet string  `json:"snippet"`
		} `json:"hits"`
	}
	scUnmarshal(t, "doc_search", searchRes, &searchEnv)
	if len(searchEnv.Hits) != 2 {
		t.Fatalf("doc_search hits = %d, want 2; %s", len(searchEnv.Hits), scJSON(t, searchRes))
	}
	var found bool
	for _, h := range searchEnv.Hits {
		if h.Document.Slug == "komorebi/setup" && strings.Contains(h.Document.Body, "repos/") &&
			h.Rank < 0 && h.Snippet != "" {
			found = true
		}
	}
	if !found {
		t.Fatalf("doc_search missed the card: %s", scJSON(t, searchRes))
	}
	// The kind filter narrows the hits.
	kindRes := mcpCall(t, cs, "doc_search", map[string]any{"query": "komorebi", "kind": "journal"})
	wantToolOK(t, "doc_search", kindRes)
	if structuredHas(t, kindRes, "komorebi/setup") {
		t.Fatalf("kind filter returned a knowledge card: %s", scJSON(t, kindRes))
	}

	// doc_get returns the body.
	getRes := mcpCall(t, cs, "doc_get", map[string]any{"kind": "knowledge", "slug": "komorebi/setup"})
	wantToolOK(t, "doc_get", getRes)
	var card struct {
		Kind string `json:"kind"`
		Slug string `json:"slug"`
		Body string `json:"body"`
	}
	scUnmarshal(t, "doc_get", getRes, &card)
	if card.Kind != "knowledge" || card.Slug != "komorebi/setup" ||
		card.Body != "the clone lives under repos/" {
		t.Fatalf("doc_get = %+v, want the stored card", card)
	}

	// doc_related returns the index as the card's backlink.
	relRes := mcpCall(t, cs, "doc_related", map[string]any{"kind": "knowledge", "slug": "komorebi/setup"})
	wantToolOK(t, "doc_related", relRes)
	var rel struct {
		Source    documentData   `json:"source"`
		Outlinks  []documentData `json:"outlinks"`
		Backlinks []documentData `json:"backlinks"`
	}
	scUnmarshal(t, "doc_related", relRes, &rel)
	if rel.Source.Slug != "komorebi/setup" || len(rel.Outlinks) != 0 {
		t.Fatalf("relation source/outlinks = %s, want the card with no outlinks", scJSON(t, relRes))
	}
	if len(rel.Backlinks) != 1 || rel.Backlinks[0].Slug != "index" {
		t.Fatalf("backlinks = %+v, want the index; %s", rel.Backlinks, scJSON(t, relRes))
	}

	// Scope boundary: a server bound to opensource must answer not_found for
	// the personal card without naming the scope, and search must not leak it.
	foreign := mcpConnectArgs(t, db, "--scope", "opensource")
	for _, call := range []struct {
		tool string
		args map[string]any
	}{
		{"doc_get", map[string]any{"kind": "knowledge", "slug": "komorebi/setup"}},
		{"doc_related", map[string]any{"kind": "knowledge", "slug": "komorebi/setup"}},
	} {
		hidden := mcpCall(t, foreign, call.tool, call.args)
		if !hidden.IsError {
			t.Fatalf("%s foreign: isError=false, want not_found; content: %s", call.tool, toolText(hidden))
		}
		text := toolText(hidden)
		if !strings.Contains(text, "not_found") || strings.Contains(text, "personal") {
			t.Fatalf("%s foreign leaked scope: %q", call.tool, text)
		}
	}
	hiddenSearch := mcpCall(t, foreign, "doc_search", map[string]any{"query": "komorebi"})
	wantToolOK(t, "doc_search", hiddenSearch)
	if structuredHas(t, hiddenSearch, "komorebi/setup") {
		t.Fatalf("foreign doc_search leaked the card: %s", scJSON(t, hiddenSearch))
	}
}

// TestMCPDeleteSource drives delete_source over stdio with the explicit
// --allow-delete-source opt-in: an unreferenced source is deleted, a retry with
// the same key replays the stored result, a new key for the now-missing source
// is not_found, and the registry shows no source.
func TestMCPDeleteSource(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, initArgs...).wantOK(t, "init")
	run(t, db, "source", "add",
		"--id", "scratch", "--name", "Scratch",
		"--scope", "personal", "--kind", "capture", "--connector", "manual",
	).wantOK(t, "source add")

	cs := mcpConnectArgs(t, db, "--allow-delete-source")
	del := mcpCall(t, cs, "delete_source", map[string]any{"source_id": "scratch", "idempotency_key": "mcp-del-1"})
	wantToolOK(t, "delete_source", del)
	var delEnv struct {
		Source struct {
			ID string `json:"id"`
		} `json:"source"`
	}
	scUnmarshal(t, "delete_source", del, &delEnv)
	if delEnv.Source.ID != "scratch" {
		t.Fatalf("delete_source = %+v, want scratch", delEnv)
	}

	replay := mcpCall(t, cs, "delete_source", map[string]any{"source_id": "scratch", "idempotency_key": "mcp-del-1"})
	wantToolOK(t, "delete_source replay", replay)

	missing := mcpCall(t, cs, "delete_source", map[string]any{"source_id": "scratch", "idempotency_key": "mcp-del-2"})
	if !missing.IsError || !strings.Contains(toolText(missing), "not_found") {
		t.Fatalf("second delete: isError=%v text=%q, want not_found", missing.IsError, toolText(missing))
	}

	sources := mcpCall(t, cs, "sources", nil)
	wantToolOK(t, "sources", sources)
	var listEnv struct {
		Sources []struct {
			ID string `json:"id"`
		} `json:"sources"`
	}
	scUnmarshal(t, "sources", sources, &listEnv)
	if len(listEnv.Sources) != 0 {
		t.Fatalf("sources after delete = %+v, want none", listEnv.Sources)
	}
}

// TestMCPDeleteSourceHiddenByDefault pins the default: without the opt-in flag
// delete_source is not served, a direct call does not run, and the source
// survives.
func TestMCPDeleteSourceHiddenByDefault(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, initArgs...).wantOK(t, "init")
	run(t, db, "source", "add",
		"--id", "scratch", "--name", "Scratch",
		"--scope", "personal", "--kind", "capture", "--connector", "manual",
	).wantOK(t, "source add")

	cs := mcpConnect(t, db)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name:      "delete_source",
		Arguments: map[string]any{"source_id": "scratch", "idempotency_key": "mcp-hidden-1"},
	})
	if err == nil && !res.IsError {
		t.Fatalf("delete_source ran without the opt-in flag: %s", toolText(res))
	}

	list := decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 1 || list[0].ID != "scratch" {
		t.Fatalf("source list = %+v, want scratch to survive", list)
	}
}

// TestMCPDeleteSourceAnswersMissingAndForeignAlike pins error privacy: a source
// outside the bound scope and a source that does not exist return the same
// not_found wire response, so deletion cannot probe other scopes.
func TestMCPDeleteSourceAnswersMissingAndForeignAlike(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, initArgs...).wantOK(t, "init")
	run(t, db, "source", "add",
		"--id", "vault", "--name", "Vault",
		"--scope", "opensource", "--kind", "capture", "--connector", "manual",
	).wantOK(t, "source add")

	cs := mcpConnectArgs(t, db, "--allow-delete-source", "--scope", "personal")
	foreign := mcpCall(t, cs, "delete_source", map[string]any{"source_id": "vault", "idempotency_key": "mcp-foreign-1"})
	missing := mcpCall(t, cs, "delete_source", map[string]any{"source_id": "ghost", "idempotency_key": "mcp-missing-1"})
	if !foreign.IsError || !missing.IsError {
		t.Fatalf("foreign isError=%v missing isError=%v, want both refused", foreign.IsError, missing.IsError)
	}
	if !strings.Contains(toolText(missing), "not_found") {
		t.Fatalf("missing source text = %q, want not_found", toolText(missing))
	}
	if toolText(foreign) != toolText(missing) {
		t.Fatalf("foreign and missing differ: %q vs %q", toolText(foreign), toolText(missing))
	}
}

// TestMCPCaptureSourceReferenceAnswersAlike pins the capture boundary: a source
// registered in another scope and a source that does not exist produce the
// same wire result, byte for byte, so capture cannot probe the registry.
func TestMCPCaptureSourceReferenceAnswersAlike(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, initArgs...).wantOK(t, "init")
	run(t, db, "source", "add",
		"--id", "vault", "--name", "Vault",
		"--scope", "opensource", "--kind", "capture", "--connector", "manual",
	).wantOK(t, "source add")

	cs := mcpConnectArgs(t, db, "--scope", "personal")
	foreign := mcpCall(t, cs, "capture", map[string]any{"idempotency_key": "cap-foreign", "text": "x", "source_id": "vault"})
	missing := mcpCall(t, cs, "capture", map[string]any{"idempotency_key": "cap-missing", "text": "x", "source_id": "ghost"})
	if !foreign.IsError || !missing.IsError {
		t.Fatalf("foreign isError=%v missing isError=%v, want both refused", foreign.IsError, missing.IsError)
	}
	foreignWire, err := json.Marshal(foreign)
	if err != nil {
		t.Fatalf("marshal foreign result: %v", err)
	}
	missingWire, err := json.Marshal(missing)
	if err != nil {
		t.Fatalf("marshal missing result: %v", err)
	}
	if string(foreignWire) != string(missingWire) {
		t.Fatalf("capture wire results differ:\nforeign: %s\nmissing: %s", foreignWire, missingWire)
	}
	if got := toolText(missing); got != "not_found: not found\n" {
		t.Fatalf("capture missing source text = %q, want not_found: not found", got)
	}
}
