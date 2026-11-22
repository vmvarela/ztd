package domain

import "time"

type Lifecycle string

const (
	Next     Lifecycle = "next"
	Waiting  Lifecycle = "waiting"
	Someday  Lifecycle = "someday"
	Archived Lifecycle = "archived"
)

type ClosureKind string

const (
	Completed   ClosureKind = "completed"
	Cancelled   ClosureKind = "cancelled"
	Unspecified ClosureKind = "unspecified"
)

type WorkItem struct {
	ID              WorkItemID        `json:"id"`
	Scope           ScopeID           `json:"scope"`
	AreaID          *AreaID           `json:"area_id,omitempty"`
	ProjectID       *ProjectID        `json:"project_id,omitempty"`
	ContextID       *ContextID        `json:"context_id,omitempty"`
	Title           string            `json:"title"`
	OriginCaptureID *CaptureID        `json:"origin_capture_id,omitempty"`
	Lifecycle       Lifecycle         `json:"lifecycle"`
	WaitingOn       string            `json:"waiting_on,omitempty"`
	DueAt           *time.Time        `json:"due_at,omitempty"`
	ClosureKind     ClosureKind       `json:"closure_kind,omitempty"`
	ClosedAt        *time.Time        `json:"closed_at,omitempty"`
	Resolution      string            `json:"resolution,omitempty"`
	CustomFields    map[string]string `json:"custom_fields,omitempty"`
	Revision        Revision          `json:"revision"`
	CreatedAt       time.Time         `json:"created_at"`
	UpdatedAt       time.Time         `json:"updated_at"`
}

// IsReservedField reports whether a legacy task field has its own work item
// column. Everything else is preserved as a custom field.
func IsReservedField(key string) bool {
	switch key {
	case "context", "client", "project", "captured_at", "closed_at",
		"waiting_on", "resolution":
		return true
	}
	return false
}

type Context struct {
	ID       ContextID `json:"id"`
	Scope    ScopeID   `json:"scope"`
	Name     string    `json:"name"`
	Revision Revision  `json:"revision"`
}

type Area struct {
	ID       AreaID   `json:"id"`
	Scope    ScopeID  `json:"scope"`
	Name     string   `json:"name"`
	Revision Revision `json:"revision"`
}

type Project struct {
	ID             ProjectID `json:"id"`
	Scope          ScopeID   `json:"scope"`
	AreaID         *AreaID   `json:"area_id,omitempty"`
	DesiredOutcome string    `json:"desired_outcome"`
	Status         string    `json:"status"`
	RepoURL        string    `json:"repo_url,omitempty"`
	ClonePath      string    `json:"clone_path,omitempty"`
	Revision       Revision  `json:"revision"`
}

type Checkpoint struct {
	ID            string     `json:"id"`
	Scope         ScopeID    `json:"scope"`
	WorkItemID    WorkItemID `json:"work_item_id"`
	Result        string     `json:"result"`
	EvidenceRefs  []string   `json:"evidence_refs,omitempty"`
	Uncertainties string     `json:"uncertainties,omitempty"`
	NextAction    string     `json:"next_action,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	Revision      Revision   `json:"revision"`
}

type FocusSession struct {
	ID         FocusID    `json:"id"`
	Profile    ProfileID  `json:"profile"`
	Actor      ActorID    `json:"actor"`
	WorkItemID WorkItemID `json:"work_item_id"`
	StartedAt  time.Time  `json:"started_at"`
	EndedAt    *time.Time `json:"ended_at,omitempty"`
	Outcome    string     `json:"outcome,omitempty"`
}

type Routine struct {
	ID              RoutineID  `json:"id"`
	Scope           ScopeID    `json:"scope"`
	Kind            string     `json:"kind"`
	Cadence         string     `json:"cadence"`
	LastCompletedAt *time.Time `json:"last_completed_at,omitempty"`
	Active          bool       `json:"active"`
	Revision        Revision   `json:"revision"`
}

type Review struct {
	ID              ReviewID  `json:"id"`
	Profile         ProfileID `json:"profile"`
	Kind            string    `json:"kind"`
	Period          string    `json:"period"`
	Outcomes        string    `json:"outcomes"`
	Coverage        string    `json:"coverage"`
	CompletionState string    `json:"completion_state"`
	CreatedAt       time.Time `json:"created_at"`
}

type KnowledgeRecord struct {
	ID          KnowledgeID  `json:"id"`
	Scope       ScopeID      `json:"scope"`
	Kind        string       `json:"kind"`
	Text        string       `json:"text"`
	State       string       `json:"state"`
	ReviewState string       `json:"review_state"`
	SourceRefs  []string     `json:"source_refs,omitempty"`
	ValidFrom   *time.Time   `json:"valid_from,omitempty"`
	ReviewedAt  *time.Time   `json:"reviewed_at,omitempty"`
	Supersedes  *KnowledgeID `json:"supersedes_id,omitempty"`
	Revision    Revision     `json:"revision"`
	CreatedAt   time.Time    `json:"created_at"`
}
