package mcpserver

import (
	"context"
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
func newTestSession(t *testing.T) *mcp.ClientSession {
	t.Helper()
	ctx := context.Background()
	binding := domain.ScopeBinding{Profile: "personal", Actor: "test", Scopes: []domain.ScopeID{"personal"}}
	server := NewServer(nil, binding, "test")
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

// TestToolCatalog pins the model-facing surface: sixteen tools, including the
// source registry, the reported batch ingestion boundary and the read-only
// document retrieval tools.
func TestToolCatalog(t *testing.T) {
	cs := newTestSession(t)
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
		"doc_search", "doc_get", "doc_related",
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
}

// TestRecordSourceReviewRejectsObserved pins the trust boundary: observed
// coverage fails at the tool with invalid_input before any service or store
// code runs, so a model cannot attest a provider exchange it never made.
func TestRecordSourceReviewRejectsObserved(t *testing.T) {
	cs := newTestSession(t)
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
