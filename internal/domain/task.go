package domain

import "time"

type Task struct {
	ID         WorkItemID `json:"id"`
	Scope      ScopeID    `json:"scope"`
	ProjectID  *ProjectID `json:"project_id,omitempty"`
	ContextID  *ContextID `json:"context_id,omitempty"`
	CaptureID  *CaptureID `json:"capture_id,omitempty"`
	Title      string     `json:"title"`
	Status     string     `json:"status"`
	WaitingOn  string     `json:"waiting_on,omitempty"`
	DueAt      *time.Time `json:"due_at,omitempty"`
	ClosedAt   *time.Time `json:"closed_at,omitempty"`
	Resolution string     `json:"resolution,omitempty"`
	Revision   Revision   `json:"revision"`
}

func (w WorkItem) Task() Task {
	status := string(w.Lifecycle)
	if w.Lifecycle == Archived {
		status = string(w.ClosureKind)
		if status == "" || status == "unspecified" {
			status = "closed_unknown"
		}
	}
	return Task{w.ID, w.Scope, w.ProjectID, w.ContextID, w.OriginCaptureID, w.Title, status, w.WaitingOn, w.DueAt, w.ClosedAt, w.Resolution, w.Revision}
}
