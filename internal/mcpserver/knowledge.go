package mcpserver

import (
	"context"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"ztd/internal/app"
	"ztd/internal/domain"
)

type knowledgeRef struct {
	Scope string `json:"scope,omitempty"`
	Slug  string `json:"slug"`
}
type knowledgeSave struct {
	Scope     string            `json:"scope"`
	Slug      string            `json:"slug"`
	Title     string            `json:"title"`
	Body      string            `json:"body"`
	Sources   []string          `json:"sources,omitempty"`
	ProjectID *domain.ProjectID `json:"project_id,omitempty"`
	Expected  domain.Revision   `json:"expected_revision"`
}

func (in knowledgeSave) command(b domain.ScopeBinding) app.DocumentCmd {
	return app.DocumentCmd{Binding: b, Scope: domain.ScopeID(in.Scope), Kind: domain.DocumentKnowledge, Slug: in.Slug, Title: in.Title, Body: in.Body, Sources: in.Sources, ProjectID: in.ProjectID, Expected: in.Expected, Status: domain.DocumentDraft, DraftOnly: true}
}
func addKnowledgeTools(s *mcp.Server, svc *app.Service, b domain.ScopeBinding) {
	mcp.AddTool(s, &mcp.Tool{Name: "knowledge_search", Description: "Find knowledge in allowed scopes, optionally by project. Returns compact snippets and revisions; use knowledge_read for the body. No index maintenance required."}, func(ctx context.Context, _ *mcp.CallToolRequest, in app.KnowledgeQuery) (*mcp.CallToolResult, []app.KnowledgeHit, error) {
		out, err := svc.SearchKnowledge(ctx, b, in)
		return nil, out, toolError(err)
	})
	mcp.AddTool(s, &mcp.Tool{Name: "knowledge_read", Description: "Read a knowledge page with sources and revision. Supply scope to disambiguate a slug."}, func(ctx context.Context, _ *mcp.CallToolRequest, in knowledgeRef) (*mcp.CallToolResult, domain.Document, error) {
		out, err := svc.ReadKnowledge(ctx, b, domain.ScopeID(in.Scope), in.Slug)
		return nil, out, toolError(err)
	})
	mcp.AddTool(s, &mcp.Tool{Name: "knowledge_save", Description: "Save one knowledge draft with sources and optional project. Revision 0 creates; a positive revision updates that exact draft. Use process_capture.document to resolve a capture atomically."}, func(ctx context.Context, _ *mcp.CallToolRequest, in knowledgeSave) (*mcp.CallToolResult, domain.Document, error) {
		if in.Scope == "" {
			return nil, domain.Document{}, domain.Invalid("scope is required")
		}
		out, err := svc.SaveKnowledge(ctx, in.command(b))
		return nil, out, toolError(err)
	})
	mcp.AddTool(s, &mcp.Tool{Name: "knowledge_related", Description: "Read links and backlinks of a page inside its scope."}, func(ctx context.Context, _ *mcp.CallToolRequest, in knowledgeRef) (*mcp.CallToolResult, app.KnowledgeRelations, error) {
		out, err := svc.RelatedKnowledge(ctx, b, domain.ScopeID(in.Scope), in.Slug)
		return nil, out, toolError(err)
	})
}
