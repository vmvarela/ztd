package app

import (
	"context"
	"ztd/internal/domain"
)

// UpdateTask is a patch: omitted fields preserve their value, empty optional
// references clear it. The read is protected by the same revision on the write.
type TaskUpdate struct {
	ID         domain.WorkItemID `json:"id"`
	Key        string            `json:"idempotency_key"`
	Expected   domain.Revision   `json:"expected_revision"`
	Status     string            `json:"status,omitempty"`
	Title      *string           `json:"title,omitempty"`
	WaitingOn  *string           `json:"waiting_on,omitempty"`
	Resolution *string           `json:"resolution,omitempty"`
	ProjectID  *domain.ProjectID `json:"project_id,omitempty"`
	ContextID  *domain.ContextID `json:"context_id,omitempty"`
	DueAt      *string           `json:"due_at,omitempty"`
}

func (s *Service) UpdateTask(ctx context.Context, b domain.ScopeBinding, in TaskUpdate) (domain.Task, error) {
	if in.Expected <= 0 {
		return domain.Task{}, domain.Invalid("expected_revision must be positive")
	}
	return s.Repo.UpdateTask(ctx, b, in, s.now())
}
