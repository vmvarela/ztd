package mcpserver

import (
	"context"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"ztd/internal/app"
	"ztd/internal/domain"
)

type periodIn struct {
	Kind   string `json:"kind"`
	Period string `json:"period"`
	Scope  string `json:"scope,omitempty"`
}

func selectScope(b domain.ScopeBinding, scope string) (domain.ScopeBinding, error) {
	if scope != "" {
		if !b.Allows(domain.ScopeID(scope)) {
			return b, domain.NewError(domain.NotFound, "scope not found")
		}
		b.Scopes = []domain.ScopeID{domain.ScopeID(scope)}
	}
	return b, nil
}
func addPlanningTools(s *mcp.Server, svc *app.Service, b domain.ScopeBinding) {
	mcp.AddTool(s, &mcp.Tool{Name: "plan_show", Description: "Read the daily or weekly plan, only including visible task IDs."}, func(ctx context.Context, _ *mcp.CallToolRequest, in periodIn) (*mcp.CallToolResult, domain.Plan, error) {
		selected, err := selectScope(b, in.Scope)
		if err != nil {
			return nil, domain.Plan{}, err
		}
		out, err := svc.Repo.ReadPlan(ctx, selected, domain.PlanKind(in.Kind), in.Period)
		return nil, out, toolError(err)
	})
	mcp.AddTool(s, &mcp.Tool{Name: "review_show", Description: "Read a scoped review document by kind and period."}, func(ctx context.Context, _ *mcp.CallToolRequest, in periodIn) (*mcp.CallToolResult, domain.Document, error) {
		selected, err := selectScope(b, in.Scope)
		if err != nil {
			return nil, domain.Document{}, err
		}
		out, err := svc.Repo.ReadReview(ctx, selected, in.Kind, in.Period)
		return nil, out, toolError(err)
	})
	mcp.AddTool(s, &mcp.Tool{Name: "task_update", Description: "Patch a task with its current revision. Status: next, waiting, someday, completed, cancelled. Empty project/context/due_at clears it. Retry with the same key and payload."}, func(ctx context.Context, _ *mcp.CallToolRequest, in app.TaskUpdate) (*mcp.CallToolResult, domain.Task, error) {
		out, err := svc.UpdateTask(ctx, b, in)
		return nil, out, toolError(err)
	})
}
