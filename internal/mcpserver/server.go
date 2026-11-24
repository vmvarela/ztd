// Package mcpserver exposes the ZTD application service over MCP stdio.
//
// The ScopeBinding is frozen when the process starts. Document tools may select
// only a scope inside that binding; no tool accepts a profile, actor, SQL or
// arbitrary update, so the model cannot widen access.
package mcpserver

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const (
	defaultFindLimit = 8
	maxFindLimit     = 20
	maxReadIDs       = 5
	maxDocPutBytes   = 512 << 10
)

// NewServer builds the typed tool and prompt catalog for one fixed binding.
// delete_source is registered only when allowDeleteSource is set: it is the one
// destructive tool, so the host must opt in at startup.
func NewServer(svc *app.Service, binding domain.ScopeBinding, version string, allowDeleteSource bool) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "ztd", Version: version}, nil)
	scopeNames := make([]string, len(binding.Scopes))
	for i, scope := range binding.Scopes {
		scopeNames[i] = string(scope)
	}
	boundScopes := strings.Join(scopeNames, ", ")
	addTools(s, svc, binding, boundScopes)
	addKnowledgeTools(s, svc, binding)
	addPlanningTools(s, svc, binding)
	if allowDeleteSource {
		addDeleteSourceTool(s, svc, binding)
	}
	addPrompts(s, boundScopes)
	return s
}

// Serve runs the server on stdin/stdout until the context ends.
func Serve(ctx context.Context, svc *app.Service, binding domain.ScopeBinding, version string, allowDeleteSource bool) error {
	return NewServer(svc, binding, version, allowDeleteSource).Run(ctx, &mcp.StdioTransport{})
}

type captureIn struct {
	IdempotencyKey string `json:"idempotency_key" jsonschema:"caller-supplied key; reuse it when retrying the same capture"`
	Text           string `json:"text" jsonschema:"captured text, preserved verbatim"`
	SourceID       string `json:"source_id,omitempty" jsonschema:"registered source identifier of this scope; empty means the manual entry point"`
}

type processIn struct {
	Document       *knowledgeSave `json:"document,omitempty" jsonschema:"knowledge page to save atomically with a reference outcome; same scope as capture"`
	DocumentID     string         `json:"document_id,omitempty"`
	IdempotencyKey string         `json:"idempotency_key"`
	CaptureID      string         `json:"capture_id"`
	Outcome        string         `json:"outcome" jsonschema:"work_items, reference, immediate, discard or defer"`
	Titles         []string       `json:"titles,omitempty" jsonschema:"one title per work item; required for work_items"`
	ProjectID      string         `json:"project_id,omitempty"`
	AreaID         string         `json:"area_id,omitempty"`
	ContextID      string         `json:"context_id,omitempty"`
	WaitingOn      string         `json:"waiting_on,omitempty"`
	ReviewAfter    string         `json:"review_after,omitempty" jsonschema:"YYYY-MM-DD; required for defer"`
	Reason         string         `json:"reason,omitempty"`
	ResultEvidence string         `json:"result_evidence,omitempty"`
	Expected       int64          `json:"expected_revision,omitempty" jsonschema:"0 means no revision check"`
}

type prepareIn struct {
	Date string `json:"date,omitempty" jsonschema:"YYYY-MM-DD; defaults to today"`
}

type planItemIn struct {
	WorkItemID string `json:"work_item_id"`
	Role       string `json:"role,omitempty" jsonschema:"optional legacy role; defaults to mit for daily and big_rock for weekly"`
}

type commitPlanIn struct {
	IdempotencyKey  string       `json:"idempotency_key"`
	Kind            string       `json:"kind" jsonschema:"daily or weekly"`
	Period          string       `json:"period" jsonschema:"YYYY-MM-DD or YYYY-Www"`
	Expected        int64        `json:"expected_revision,omitempty"`
	ExceptionReason string       `json:"exception_reason,omitempty"`
	OverrideID      string       `json:"override_id,omitempty" jsonschema:"recorded daily limit override"`
	Items           []planItemIn `json:"items"`
}

type focusStartIn struct {
	IdempotencyKey string `json:"idempotency_key"`
	WorkItemID     string `json:"work_item_id"`
}

type focusStartOut struct {
	Focus       domain.FocusSession `json:"focus"`
	Checkpoints []domain.Checkpoint `json:"checkpoints,omitempty"`
}

type checkpointIn struct {
	IdempotencyKey string   `json:"idempotency_key"`
	WorkItemID     string   `json:"work_item_id"`
	Result         string   `json:"result"`
	Evidence       []string `json:"evidence,omitempty"`
	Uncertainties  string   `json:"uncertainties,omitempty"`
	NextAction     string   `json:"next_action,omitempty"`
}

type focusFinishIn struct {
	IdempotencyKey string `json:"idempotency_key"`
	FocusID        string `json:"focus_id"`
	Outcome        string `json:"outcome"`
}

type reviewIn struct {
	Scope          string `json:"scope,omitempty"`
	IdempotencyKey string `json:"idempotency_key"`
	Kind           string `json:"kind" jsonschema:"daily, weekly, monthly or yearly"`
	Period         string `json:"period"`
	Outcomes       string `json:"outcomes"`
	Coverage       string `json:"coverage"`
	Complete       *bool  `json:"complete,omitempty" jsonschema:"defaults to true"`
}

type findIn struct {
	Query string `json:"query"`
	Limit int    `json:"limit,omitempty" jsonschema:"defaults to 8, maximum 20"`
}
type findOut struct {
	Items []domain.WorkItem `json:"items"`
}

type inboxNextOut struct {
	Capture domain.Capture `json:"capture"`
	Stats   app.InboxStats `json:"stats"`
}

type readIn struct {
	IDs []string `json:"ids" jsonschema:"capture or work item IDs, at most 5"`
}

type readOut struct {
	Captures    []domain.Capture              `json:"captures,omitempty"`
	WorkItems   []domain.WorkItem             `json:"work_items,omitempty"`
	Checkpoints map[string]*domain.Checkpoint `json:"checkpoints,omitempty"`
}

type docSearchIn struct {
	Query string `json:"query" jsonschema:"words to search for; every word must appear"`
	Kind  string `json:"kind,omitempty" jsonschema:"optional document kind filter"`
	Limit int    `json:"limit,omitempty" jsonschema:"defaults to 10, maximum 50"`
}

type docSearchOut struct {
	Hits []app.DocumentSearchHit `json:"hits"`
}

type docRefIn struct {
	Kind  string  `json:"kind" jsonschema:"document kind, for example knowledge"`
	Slug  string  `json:"slug"`
	Scope *string `json:"scope,omitempty" jsonschema:"optional bound scope; required to disambiguate a slug present in multiple scopes"`
}

type docPutIn struct {
	Slug             string `json:"slug"`
	Title            string `json:"title"`
	Body             string `json:"body"`
	Scope            string `json:"scope" jsonschema:"destination scope selected from the session's bound scopes"`
	ExpectedRevision int64  `json:"expected_revision" jsonschema:"0 to create only when no document exists, otherwise the current revision to update"`
}

// sourcesOut carries registry state only: identities, coverage and cursors,
// never provider contents.
type sourcesOut struct {
	Sources []domain.Source `json:"sources"`
}

type recordSourceReviewIn struct {
	SourceID       string                 `json:"source_id"`
	BatchID        string                 `json:"batch_id"`
	IdempotencyKey string                 `json:"idempotency_key"`
	ResultKind     string                 `json:"result_kind,omitempty" jsonschema:"reported only; observed is rejected here and reserved for a trusted host adapter"`
	Retrieval      domain.SourceRetrieval `json:"retrieval,omitempty"`
	Items          []domain.SourceItem    `json:"items"`
}

type recordSourceReviewOut struct {
	Review   domain.SourceReview `json:"review"`
	Captures []domain.Capture    `json:"captures"`
}

type deleteSourceIn struct {
	SourceID       string `json:"source_id"`
	IdempotencyKey string `json:"idempotency_key" jsonschema:"required; a retry with the same key replays the deletion"`
}

type deleteSourceOut struct {
	Source domain.Source `json:"source"`
}

func addTools(s *mcp.Server, svc *app.Service, b domain.ScopeBinding, boundScopes string) {
	mcp.AddTool(s, &mcp.Tool{
		Name:        "capture",
		Description: "Capture one item into the inbox. Never filters or classifies it.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in captureIn) (*mcp.CallToolResult, domain.Capture, error) {
		out, err := svc.Capture(ctx, app.CaptureCmd{
			Binding: b, Key: in.IdempotencyKey, Text: in.Text, SourceID: in.SourceID,
		})
		if in.SourceID != "" {
			err = sourceRefError(err)
		}
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "inbox_next",
		Description: "Return the oldest pending or due deferred capture. Read-only.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, inboxNextOut, error) {
		capture, err := svc.InboxNext(ctx, b)
		if err != nil {
			return nil, inboxNextOut{}, toolError(err)
		}
		stats, err := svc.InboxStats(ctx, b)
		return nil, inboxNextOut{Capture: capture, Stats: stats}, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "process_capture",
		Description: "Apply one typed outcome to a capture, creating zero or more work items atomically.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in processIn) (*mcp.CallToolResult, app.ProcessResult, error) {
		outcome, err := outcomeFrom(in)
		if err != nil {
			return nil, app.ProcessResult{}, err
		}
		var document *app.DocumentCmd
		if in.Document != nil {
			d := in.Document.command(b)
			document = &d
		}
		outcome.DocumentID = in.DocumentID
		out, err := svc.Process(ctx, app.ProcessCmd{
			Binding: b, Key: in.IdempotencyKey, ID: domain.CaptureID(in.CaptureID),
			Expected: domain.Revision(in.Expected), Outcome: outcome, Document: document,
		})
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "prepare",
		Description: "Read-only daily brief: active primary goal, committed MITs, candidate next and waiting items, latest checkpoints, and source coverage when sources exist (unverified or partial coverage is surfaced, never hidden). It never chooses MITs.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in prepareIn) (*mcp.CallToolResult, app.PlanBrief, error) {
		out, err := svc.Prepare(ctx, b, in.Date)
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "commit_plan",
		Description: "Record a human plan decision. Enforces one to three MITs per actor and day unless an override exists.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in commitPlanIn) (*mcp.CallToolResult, domain.Plan, error) {
		items := make([]domain.PlanItem, 0, len(in.Items))
		for i, it := range in.Items {
			items = append(items, domain.PlanItem{
				WorkItemID: domain.WorkItemID(it.WorkItemID),
				Role:       domain.PlanRole(it.Role),
				Position:   i,
			})
		}
		out, err := svc.CommitPlan(ctx, app.CommitPlanCmd{
			Binding: b, Key: in.IdempotencyKey, Kind: domain.PlanKind(in.Kind),
			Period: in.Period, Expected: domain.Revision(in.Expected),
			Items: items, OverrideID: in.OverrideID, ExceptionReason: in.ExceptionReason,
		})
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "focus_start",
		Description: "Open the single focus session for this actor across scopes. Never closes an existing focus.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in focusStartIn) (*mcp.CallToolResult, focusStartOut, error) {
		focus, cps, err := svc.StartFocus(ctx, app.FocusStartCmd{
			Binding: b, Key: in.IdempotencyKey, Item: domain.WorkItemID(in.WorkItemID),
		})
		return nil, focusStartOut{Focus: focus, Checkpoints: cps}, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "checkpoint",
		Description: "Record progress on the open focus without changing the work item revision.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in checkpointIn) (*mcp.CallToolResult, domain.Checkpoint, error) {
		out, err := svc.Checkpoint(ctx, app.CheckpointCmd{
			Binding: b, Key: in.IdempotencyKey, Item: domain.WorkItemID(in.WorkItemID),
			Result: in.Result, Evidence: in.Evidence, Uncertain: in.Uncertainties, NextAction: in.NextAction,
		})
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "focus_finish",
		Description: "Close the caller's open focus session with an outcome.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in focusFinishIn) (*mcp.CallToolResult, domain.FocusSession, error) {
		out, err := svc.FinishFocus(ctx, app.FocusFinishCmd{
			Binding: b, Key: in.IdempotencyKey, Focus: domain.FocusID(in.FocusID), Outcome: in.Outcome,
		})
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "record_review",
		Description: "Record a daily, weekly, monthly or yearly review. It cannot claim source coverage that was not configured.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in reviewIn) (*mcp.CallToolResult, domain.Review, error) {
		complete := true
		if in.Complete != nil {
			complete = *in.Complete
		}
		selected, err := selectScope(b, in.Scope)
		if err != nil {
			return nil, domain.Review{}, err
		}
		out, err := svc.Repo.RecordReview(ctx, app.ReviewCmd{
			Binding: selected, Key: in.IdempotencyKey, Kind: in.Kind, Period: in.Period,
			Outcomes: in.Outcomes, Coverage: in.Coverage, Complete: complete,
		}, svc.Now())
		return nil, out, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "sources",
		Description: "List the sources configured for this binding: identity, kind, connector, coverage and cursor. Read-only; returns no provider contents.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, sourcesOut, error) {
		sources, err := svc.ListSources(ctx, b)
		if sources == nil {
			sources = []domain.Source{}
		}
		return nil, sourcesOut{Sources: sources}, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "record_source_review",
		Description: "Ingest one reported retrieval batch for a source as pending captures. result_kind is reported only; observed is rejected here because only a trusted host adapter may attest it. Each item text is capped at 64 KiB and a batch at 500 items. Omitting retrieval means the window is unknown.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in recordSourceReviewIn) (*mcp.CallToolResult, recordSourceReviewOut, error) {
		kind := in.ResultKind
		if kind == "" {
			kind = "reported"
		}
		if kind != "reported" {
			// Fail at the model-facing boundary: observed coverage needs a
			// trusted host adapter that this tool is not.
			return nil, recordSourceReviewOut{}, domain.Invalid("observed coverage requires a trusted host adapter; only reported is accepted here")
		}
		review, captures, err := svc.RecordSourceReview(ctx, app.SourceReviewCmd{
			Binding: b, SourceID: in.SourceID, BatchID: in.BatchID, Key: in.IdempotencyKey,
			ResultKind: kind, Retrieval: in.Retrieval, Items: in.Items,
		})
		if captures == nil {
			captures = []domain.Capture{}
		}
		return nil, recordSourceReviewOut{Review: review, Captures: captures}, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "find",
		Description: "Find a few work items by title. Returns at most 20, default 8.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in findIn) (*mcp.CallToolResult, findOut, error) {
		limit := in.Limit
		if limit <= 0 {
			limit = defaultFindLimit
		}
		if limit > maxFindLimit {
			limit = maxFindLimit
		}
		items, err := svc.Repo.Find(ctx, b, in.Query, limit)
		return nil, findOut{Items: items}, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "read",
		Description: "Read up to five captures or work items by ID; work items include their latest checkpoint, if any. Out-of-scope IDs are not found.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in readIn) (*mcp.CallToolResult, readOut, error) {
		if len(in.IDs) == 0 {
			return nil, readOut{}, domain.Invalid("ids is required")
		}
		if len(in.IDs) > maxReadIDs {
			return nil, readOut{}, domain.Invalid("at most %d ids", maxReadIDs)
		}
		var out readOut
		for _, id := range in.IDs {
			switch {
			case strings.HasPrefix(id, "C-"):
				c, err := svc.Repo.GetCapture(ctx, b, domain.CaptureID(id))
				if err != nil {
					return nil, readOut{}, readError(err)
				}
				out.Captures = append(out.Captures, c)
			case strings.HasPrefix(id, "T-"):
				w, checkpoint, err := svc.Repo.GetWorkItemWithCheckpoint(ctx, b, domain.WorkItemID(id))
				if err != nil {
					return nil, readOut{}, readError(err)
				}
				out.WorkItems = append(out.WorkItems, w)
				if out.Checkpoints == nil {
					out.Checkpoints = make(map[string]*domain.Checkpoint)
				}
				out.Checkpoints[id] = checkpoint
			default:
				return nil, readOut{}, domain.Invalid("unknown id %q", id)
			}
		}
		return nil, out, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "doc_search",
		Description: "Full-text search over the bound scopes' documents. Returns hits with the document, its rank and a body snippet, best match first. Read-only.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in docSearchIn) (*mcp.CallToolResult, docSearchOut, error) {
		hits, err := svc.SearchDocuments(ctx, b, in.Query, domain.DocumentKind(in.Kind), in.Limit)
		if err != nil {
			return nil, docSearchOut{}, toolError(err)
		}
		if hits == nil {
			hits = []app.DocumentSearchHit{}
		}
		return nil, docSearchOut{Hits: hits}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "doc_get",
		Description: "Read one document by kind and slug, body included. Supply scope when the slug may exist in multiple bound scopes; omitted scope is ambiguous in that case. A document outside the fixed binding is not_found.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in docRefIn) (*mcp.CallToolResult, domain.Document, error) {
		var scope []domain.ScopeID
		if in.Scope != nil {
			if strings.TrimSpace(*in.Scope) == "" {
				return nil, domain.Document{}, domain.Invalid("scope must not be blank")
			}
			scope = append(scope, domain.ScopeID(*in.Scope))
		}
		doc, err := svc.GetDocument(ctx, b, domain.DocumentKind(in.Kind), in.Slug, scope...)
		return nil, doc, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "doc_related",
		Description: "Return the document's link neighbourhood: the documents it links to and the ones that link back, resolved inside its own scope. Supply scope when the slug may exist in multiple bound scopes. Read-only.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in docRefIn) (*mcp.CallToolResult, app.DocumentRelations, error) {
		var scope []domain.ScopeID
		if in.Scope != nil {
			if strings.TrimSpace(*in.Scope) == "" {
				return nil, app.DocumentRelations{}, domain.Invalid("scope must not be blank")
			}
			scope = append(scope, domain.ScopeID(*in.Scope))
		}
		rel, err := svc.RelatedDocuments(ctx, b, domain.DocumentKind(in.Kind), in.Slug, scope...)
		return nil, rel, toolError(err)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "doc_put",
		Description: fmt.Sprintf("Create or update one knowledge draft. Choose the destination scope by interpreting the document's content; it may differ from the capture's source scope, but must be one of the session's bound scopes: %s. Scope is required; kind and status are fixed to knowledge and draft. Combined slug, title and body are limited to 512 KiB. expected_revision=0 creates only when no document exists; a positive value updates only the current draft at that revision. Use before process_capture with outcome reference, so a capture is only marked processed after the draft write succeeds.", boundScopes),
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in docPutIn) (*mcp.CallToolResult, domain.Document, error) {
		if strings.TrimSpace(in.Scope) == "" {
			return nil, domain.Document{}, domain.Invalid("scope is required")
		}
		if len(in.Slug)+len(in.Title)+len(in.Body) > maxDocPutBytes {
			return nil, domain.Document{}, domain.Invalid("combined slug, title and body exceed %d bytes", maxDocPutBytes)
		}
		out, err := svc.PutDocument(ctx, app.DocumentCmd{
			Binding: b, Scope: domain.ScopeID(in.Scope), Kind: domain.DocumentKnowledge, Slug: in.Slug,
			Title: in.Title, Body: in.Body, Status: domain.DocumentDraft,
			Expected: domain.Revision(in.ExpectedRevision), DraftOnly: true,
		})
		return nil, out, toolError(err)
	})
}

// addDeleteSourceTool registers the opt-in destructive tool. A missing source
// and a source outside the binding both answer the same not_found, so a
// model cannot probe other scopes through deletion.
func addDeleteSourceTool(s *mcp.Server, svc *app.Service, b domain.ScopeBinding) {
	mcp.AddTool(s, &mcp.Tool{
		Name:        "delete_source",
		Description: "Delete one registered source of this binding. Refused with conflict while a capture of its scope or any review still refers to it; registration itself stays an operator command. idempotency_key is required.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in deleteSourceIn) (*mcp.CallToolResult, deleteSourceOut, error) {
		if strings.TrimSpace(in.IdempotencyKey) == "" {
			return nil, deleteSourceOut{}, domain.Invalid("idempotency key is required")
		}
		src, err := svc.DeleteSource(ctx, app.SourceDeleteCmd{Binding: b, ID: in.SourceID, Key: in.IdempotencyKey})
		if family := domain.FamilyOf(err); family == domain.NotFound || family == domain.ScopeDenied {
			err = domain.NewError(domain.NotFound, "not found")
		}
		return nil, deleteSourceOut{Source: src}, toolError(err)
	})
}

func outcomeFrom(in processIn) (domain.Outcome, error) {
	o := domain.Outcome{
		Kind: domain.OutcomeKind(in.Outcome), Titles: in.Titles,
		WaitingOn: in.WaitingOn, Reason: in.Reason, ResultEvidence: in.ResultEvidence,
	}
	if in.ProjectID != "" {
		v := domain.ProjectID(in.ProjectID)
		o.ProjectID = &v
	}
	if in.AreaID != "" {
		v := domain.AreaID(in.AreaID)
		o.AreaID = &v
	}
	if in.ContextID != "" {
		v := domain.ContextID(in.ContextID)
		o.ContextID = &v
	}
	if in.ReviewAfter != "" {
		t, err := time.Parse("2006-01-02", in.ReviewAfter)
		if err != nil {
			return domain.Outcome{}, domain.Invalid("review_after must be YYYY-MM-DD")
		}
		t = t.UTC()
		o.ReviewAfter = &t
	}
	return o, nil
}

// toolError hides foreign entity existence at the model-facing boundary.
func toolError(err error) error {
	if err == nil {
		return nil
	}
	var e *domain.Error
	if errors.As(err, &e) && e.Family == domain.ScopeDenied {
		return domain.NewError(domain.NotFound, "not found")
	}
	return err
}

// readError makes missing and out-of-scope IDs indistinguishable to read.
func readError(err error) error {
	if domain.FamilyOf(err) == domain.NotFound {
		return domain.NewError(domain.NotFound, "not found")
	}
	return toolError(err)
}

// sourceRefError answers a missing explicit source and a source owned by
// another scope with the same not_found, so capture cannot probe the registry.
func sourceRefError(err error) error {
	if err == nil {
		return nil
	}
	if family := domain.FamilyOf(err); family == domain.NotFound || family == domain.ScopeDenied {
		return domain.NewError(domain.NotFound, "not found")
	}
	return err
}

func addPrompts(s *mcp.Server, boundScopes string) {
	addPrompt(s, "Collect", "Capture without filtering; empty the inbox later.",
		"Capture every commitment, idea or interruption in one line, verbatim. Do not classify, prioritize or drop anything. Use capture. Return when the inbox holds what the user said.")
	addPrompt(s, "Process", "Decide one inbox item at a time, top to bottom.",
		fmt.Sprintf("Take the oldest item with inbox_next. Offer exactly one decision: discard, delegate or wait, do it if it takes two minutes, defer with a review date, or turn it into one or more work items. For a knowledge reference, use ztd-knowledge to interpret the lesson and choose a destination from the session's bound scopes (%s); the document's meaning determines the destination, not the capture's source scope. Pass that scope to doc_put. If updating an existing card, use doc_get with the same scope to read its current revision. Write the card first with doc_put as a draft, then call process_capture with outcome reference and the doc_put result's document ID in reason. If doc_put fails, keep the capture pending; if process_capture's response is lost, retry the identical request with the same idempotency key and payload; if it fails, keep the draft and retry the reference later — there is no atomic combined operation. Use process_capture. Do not batch decisions.", boundScopes))
	addPrompt(s, "Plan", "Choose one to three MITs from real state.",
		"Call prepare. Propose one to three MITs for the person and day across scopes, using the committed plan, candidates and checkpoints. State why each one matters. Never claim a plan exists before commit_plan succeeds.")
	addPrompt(s, "Do", "One focus, one next action.",
		"Pick one actionable work item. Start it with focus_start. Work only on its next action. Record progress with checkpoint and close with focus_finish. Capture interruptions instead of switching.")
	addPrompt(s, "Review", "Review what happened and what is next.",
		"Review the day or week: completed work, waiting items, inbox state and the next period. Record it with record_review. Source coverage is unavailable until sources are configured; never imply the inbox was fully reviewed.")
	addPrompt(s, "Simplify", "Remove what does not serve the current goal.",
		"Identify tasks, projects and sources that no longer serve the active goal. Propose what to cancel, archive or stop. Do not delete or archive without explicit human confirmation.")
	addPrompt(s, "Routines", "Keep recurring work visible.",
		"List due routines, complete only those actually done, and propose adjustments. Routines are not tasks; never mark one complete because it was discussed.")
	addPrompt(s, "Passion", "Explore direction without inventing commitments.",
		"Ask what the user wants more of, what drains them and what they would try for a month. Capture conclusions as notes or candidate experiments. Do not create goals or plans without explicit confirmation.")
}

func addPrompt(s *mcp.Server, name, description, text string) {
	s.AddPrompt(&mcp.Prompt{Name: name, Description: description},
		func(context.Context, *mcp.GetPromptRequest) (*mcp.GetPromptResult, error) {
			return &mcp.GetPromptResult{
				Description: description,
				Messages: []*mcp.PromptMessage{{
					Role:    "user",
					Content: &mcp.TextContent{Text: text},
				}},
			}, nil
		})
}
