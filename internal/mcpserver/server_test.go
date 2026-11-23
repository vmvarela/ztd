package mcpserver

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"ztd/internal/domain"
)

func TestToolErrorHidesForeignScope(t *testing.T) {
	err := domain.NewError(domain.ScopeDenied, "capture belongs to scope personal")
	got := toolError(err)
	if got == nil {
		t.Fatal("toolError returned nil")
	}
	if family := domain.FamilyOf(got); family != domain.NotFound {
		t.Fatalf("family = %q, want not_found", family)
	}
	if strings.Contains(got.Error(), "personal") {
		t.Fatalf("error leaks foreign scope: %q", got)
	}
}

func TestToolErrorPassesOtherFamilies(t *testing.T) {
	err := domain.Invalid("bad input")
	got := toolError(err)
	if got == nil || domain.FamilyOf(got) != domain.InvalidInput {
		t.Fatalf("family = %q, want invalid_input", domain.FamilyOf(got))
	}
	if toolError(nil) != nil {
		t.Fatal("toolError(nil) != nil")
	}
}

// newTestSession serves the catalog over in-memory transports. svc stays nil:
// every path exercised here rejects before reaching the service.
func newTestSession(t *testing.T, allowDeleteSource bool) *mcp.ClientSession {
	t.Helper()
	return newTestSessionBinding(t, domain.ScopeBinding{
		Profile: "personal", Actor: "test", Scopes: []domain.ScopeID{"personal"},
	}, allowDeleteSource)
}

func newTestSessionBinding(t *testing.T, binding domain.ScopeBinding, allowDeleteSource bool) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	server := NewServer(nil, binding, "test", allowDeleteSource)
	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("connect server: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "ztd-test", Version: "test"}, nil)
	clientSession, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("connect client: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })
	return clientSession
}

// TestDocPutAdvertisesBoundScopes pins the dynamic description: the agent
// chooses a destination scope from the fixed binding based on document content.
func TestDocPutAdvertisesBoundScopes(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		scopes []domain.ScopeID
		want   []string
		absent string
	}{
		{[]domain.ScopeID{"personal"}, []string{"personal", "destination scope"}, "opensource"},
		{[]domain.ScopeID{"opensource", "salud"}, []string{"opensource", "salud"}, "work"},
	}
	for _, tc := range cases {
		cs := newTestSessionBinding(t, domain.ScopeBinding{
			Profile: "personal", Actor: "test", Scopes: tc.scopes,
		}, false)
		res, err := cs.ListTools(ctx, nil)
		if err != nil {
			t.Fatalf("list tools: %v", err)
		}
		var desc string
		for _, tool := range res.Tools {
			if tool.Name == "doc_put" {
				desc = tool.Description
			}
		}
		if desc == "" {
			t.Fatal("doc_put not listed")
		}
		for _, want := range tc.want {
			if !strings.Contains(desc, want) {
				t.Errorf("doc_put description missing %q: %s", want, desc)
			}
		}
		if strings.Contains(desc, tc.absent) {
			t.Errorf("doc_put description must not name non-primary %s: %s", tc.absent, desc)
		}
		if !strings.Contains(desc, "may differ from the capture's source scope") {
			t.Errorf("doc_put description missing independent destination guidance: %s", desc)
		}
	}
}

// TestToolCatalog pins the model-facing surface: seventeen tools, including the
// source registry, the reported batch ingestion boundary, the read-only
// document retrieval tools and the draft-only document write.
func TestToolCatalog(t *testing.T) {
	cs := newTestSession(t, false)
	ctx := context.Background()
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := []string{
		"capture", "inbox_next", "process_capture", "prepare",
		"commit_plan", "focus_start", "checkpoint", "focus_finish",
		"record_review", "find", "read",
		"sources", "record_source_review",
		"doc_search", "doc_get", "doc_related", "doc_put",
	}
	if len(res.Tools) != len(want) {
		t.Errorf("listed %d tools, want %d", len(res.Tools), len(want))
	}
	have := make(map[string]bool, len(res.Tools))
	for _, tool := range res.Tools {
		have[tool.Name] = true
	}
	for _, name := range want {
		if !have[name] {
			t.Errorf("tool %q not listed", name)
		}
	}
	if have["delete_source"] {
		t.Error("delete_source listed without the opt-in flag")
	}
}

// TestDeleteSourceHiddenWithoutOptIn pins the default: without the startup
// opt-in the tool is absent from the catalog and a direct call is refused by
// the protocol, so nothing runs.
func TestDeleteSourceHiddenWithoutOptIn(t *testing.T) {
	cs := newTestSession(t, false)
	ctx := context.Background()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name:      "delete_source",
		Arguments: map[string]any{"source_id": "notes", "idempotency_key": "k-1"},
	})
	if err == nil && (res == nil || !res.IsError) {
		t.Fatalf("delete_source without opt-in succeeded: %v", res)
	}
}

// TestDeleteSourceListedWithOptIn pins the explicit opt-in: the flag adds
// exactly one tool to the default catalog.
func TestDeleteSourceListedWithOptIn(t *testing.T) {
	cs := newTestSession(t, true)
	ctx := context.Background()
	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	if len(res.Tools) != 18 {
		t.Errorf("listed %d tools with opt-in, want 18", len(res.Tools))
	}
	for _, tool := range res.Tools {
		if tool.Name == "delete_source" {
			return
		}
	}
	t.Error("delete_source not listed with the opt-in flag")
}

// TestDocPutSchemaPinsWritableFields pins doc_put's surface: only slug, title,
// body, scope and expected_revision are accepted. Kind and status must not
// appear, so the model cannot widen the write beyond a knowledge draft.
func TestDocPutSchemaPinsWritableFields(t *testing.T) {
	cs := newTestSession(t, false)
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	var tool *mcp.Tool
	for _, t := range res.Tools {
		if t.Name == "doc_put" {
			tool = t
		}
	}
	if tool == nil {
		t.Fatal("doc_put not listed")
	}
	raw, err := json.Marshal(tool.InputSchema)
	if err != nil {
		t.Fatalf("marshal input schema: %v", err)
	}
	var schema struct {
		Properties           map[string]json.RawMessage `json:"properties"`
		Required             []string                   `json:"required"`
		AdditionalProperties json.RawMessage            `json:"additionalProperties"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode input schema: %v", err)
	}
	want := []string{"body", "expected_revision", "scope", "slug", "title"}
	sort.Strings(want)
	got := make([]string, 0, len(schema.Properties))
	for name := range schema.Properties {
		got = append(got, name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("properties = %v, want exactly %v", got, want)
	}
	sort.Strings(schema.Required)
	if strings.Join(schema.Required, ",") != strings.Join(want, ",") {
		t.Errorf("required = %v, want %v", schema.Required, want)
	}
	// The SDK encodes "no extra properties" as {"not":{}}; anything permissive
	// (omitted or true) would let the model pass status/kind/scope through.
	if string(schema.AdditionalProperties) == "" || string(schema.AdditionalProperties) == "true" {
		t.Errorf("additionalProperties = %s, want a rejecting schema", schema.AdditionalProperties)
	}
}

// TestDocPutRejectsProhibitedArgs pins the guard at the protocol boundary:
// extra status/kind arguments and missing scope fail schema validation before
// the handler runs (svc is nil here), so no service or store code is reached.
func TestDocPutRejectsProhibitedArgs(t *testing.T) {
	cs := newTestSession(t, false)
	ctx := context.Background()
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"status", map[string]any{
			"slug": "k/test.md", "title": "T", "body": "B", "scope": "personal",
			"expected_revision": 0, "status": "verified",
		}, "validating"},
		{"kind", map[string]any{
			"slug": "k/test.md", "title": "T", "body": "B", "scope": "personal",
			"expected_revision": 0, "kind": "project_note",
		}, "validating"},
		{"missing expected_revision", map[string]any{
			"slug": "k/test.md", "title": "T", "body": "B", "scope": "personal",
		}, "validating"},
		{"missing scope", map[string]any{
			"slug": "k/test.md", "title": "T", "body": "B",
			"expected_revision": 0,
		}, "validating"},
		{"blank scope", map[string]any{
			"slug": "k/test.md", "title": "T", "body": "B", "scope": "  ",
			"expected_revision": 0,
		}, "invalid_input"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, err := cs.CallTool(ctx, &mcp.CallToolParams{
				Name: "doc_put", Arguments: tc.args,
			})
			if err != nil {
				t.Fatalf("call tool: %v", err)
			}
			if !res.IsError {
				t.Fatalf("isError = false, want true; content: %v", res.Content)
			}
			var text strings.Builder
			for _, item := range res.Content {
				if txt, ok := item.(*mcp.TextContent); ok {
					text.WriteString(txt.Text)
				}
			}
			if !strings.Contains(text.String(), tc.want) {
				t.Errorf("error text = %q, want %q", text.String(), tc.want)
			}
		})
	}
}

// TestRecordSourceReviewRejectsObserved pins the trust boundary: observed
// coverage fails at the tool with invalid_input before any service or store
// code runs, so a model cannot attest a provider exchange it never made.
func TestRecordSourceReviewRejectsObserved(t *testing.T) {
	cs := newTestSession(t, false)
	ctx := context.Background()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name: "record_source_review",
		Arguments: map[string]any{
			"source_id":       "notes",
			"batch_id":        "batch-1",
			"idempotency_key": "k-1",
			"result_kind":     "observed",
			"items":           []any{},
		},
	})
	if err != nil {
		t.Fatalf("call tool: %v", err)
	}
	if !res.IsError {
		t.Fatalf("observed batch: isError=false, want true; content: %v", res.Content)
	}
	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	if !strings.Contains(text.String(), "invalid_input") {
		t.Fatalf("error text = %q, want invalid_input", text.String())
	}
}

// TestDeleteSourceRequiresIdempotencyKey pins the mutation rule: a blank key
// fails with invalid_input before any service or store code runs. A missing
// key is refused earlier by the schema, since the field is required.
func TestDeleteSourceRequiresIdempotencyKey(t *testing.T) {
	cs := newTestSession(t, true)
	ctx := context.Background()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name:      "delete_source",
		Arguments: map[string]any{"source_id": "notes", "idempotency_key": "  "},
	})
	if err != nil {
		t.Fatalf("call tool: %v", err)
	}
	if !res.IsError {
		t.Fatalf("delete without key: isError=false, want true; content: %v", res.Content)
	}
	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	if !strings.Contains(text.String(), "invalid_input") {
		t.Fatalf("error text = %q, want invalid_input", text.String())
	}
}
