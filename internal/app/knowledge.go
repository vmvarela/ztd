package app

import (
	"context"
	"strings"
	"ztd/internal/domain"
)

// KnowledgeSearch returns compact results. Read a page only after selecting it.
type KnowledgeQuery struct {
	Scope   domain.ScopeID   `json:"scope,omitempty"`
	Project domain.ProjectID `json:"project_id,omitempty"`
	Query   string           `json:"query"`
	Limit   int              `json:"limit,omitempty"`
}
type KnowledgeHit struct {
	ID       string                `json:"id"`
	Scope    string                `json:"scope"`
	Slug     string                `json:"slug"`
	Title    string                `json:"title"`
	Status   domain.DocumentStatus `json:"status"`
	Revision domain.Revision       `json:"revision"`
	Snippet  string                `json:"snippet"`
}

func knowledgeBinding(b domain.ScopeBinding, scope domain.ScopeID) (domain.ScopeBinding, error) {
	if err := b.Validate(); err != nil {
		return b, err
	}
	if scope != "" {
		if !b.Allows(scope) {
			return b, domain.NewError(domain.ScopeDenied, "scope is outside the session binding")
		}
		b.Scopes = []domain.ScopeID{scope}
	}
	return b, nil
}
func (s *Service) SearchKnowledge(ctx context.Context, b domain.ScopeBinding, q KnowledgeQuery) ([]KnowledgeHit, error) {
	b, err := knowledgeBinding(b, q.Scope)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(q.Query) == "" {
		return nil, domain.Invalid("query is required")
	}
	hits, err := s.Repo.SearchDocuments(ctx, b, q.Query, domain.DocumentKnowledge, q.Limit, q.Project)
	if err != nil {
		return nil, err
	}
	out := make([]KnowledgeHit, 0, len(hits))
	for _, h := range hits {
		d := h.Document
		out = append(out, KnowledgeHit{d.ID, d.Scope, d.Slug, d.Title, d.Status, d.Revision, h.Snippet})
	}
	return out, nil
}
func (s *Service) ReadKnowledge(ctx context.Context, b domain.ScopeBinding, scope domain.ScopeID, slug string) (domain.Document, error) {
	b, err := knowledgeBinding(b, scope)
	if err != nil {
		return domain.Document{}, err
	}
	return s.GetDocument(ctx, b, domain.DocumentKnowledge, slug)
}
func (s *Service) SaveKnowledge(ctx context.Context, cmd DocumentCmd) (domain.Document, error) {
	cmd.Kind = domain.DocumentKnowledge
	if cmd.Status == "" {
		cmd.Status = domain.DocumentDraft
	}
	return s.PutDocument(ctx, cmd)
}

// Relations contain summaries only, so following links does not flood context.
type KnowledgeRelations struct {
	Source    KnowledgeHit   `json:"source"`
	Outlinks  []KnowledgeHit `json:"outlinks"`
	Backlinks []KnowledgeHit `json:"backlinks"`
	Truncated bool           `json:"truncated"`
}

func knowledgeSummary(d domain.Document) KnowledgeHit {
	return KnowledgeHit{ID: d.ID, Scope: d.Scope, Slug: d.Slug, Title: d.Title, Status: d.Status, Revision: d.Revision}
}
func (s *Service) RelatedKnowledge(ctx context.Context, b domain.ScopeBinding, scope domain.ScopeID, slug string) (KnowledgeRelations, error) {
	b, err := knowledgeBinding(b, scope)
	if err != nil {
		return KnowledgeRelations{}, err
	}
	rel, err := s.RelatedDocuments(ctx, b, domain.DocumentKnowledge, slug)
	if err != nil {
		return KnowledgeRelations{}, err
	}
	out := KnowledgeRelations{Source: knowledgeSummary(rel.Source), Outlinks: []KnowledgeHit{}, Backlinks: []KnowledgeHit{}}
	for i, d := range rel.Outlinks {
		if i >= 20 {
			out.Truncated = true
			break
		}
		out.Outlinks = append(out.Outlinks, knowledgeSummary(d))
	}
	for i, d := range rel.Backlinks {
		if i >= 20 {
			out.Truncated = true
			break
		}
		out.Backlinks = append(out.Backlinks, knowledgeSummary(d))
	}
	return out, nil
}
