package app

import (
	"context"
	"time"

	"ztd/internal/domain"
)

type Clock interface{ Now() time.Time }

type Repo interface {
	Settings(ctx context.Context) (domain.Settings, error)
	SetTimezone(ctx context.Context, zone string) (domain.Settings, error)
	// Captures and processing.
	Capture(ctx context.Context, cmd CaptureCmd, now time.Time) (domain.Capture, error)
	InboxNext(ctx context.Context, b domain.ScopeBinding, now time.Time) (domain.Capture, error)
	ListInbox(ctx context.Context, b domain.ScopeBinding, now time.Time) ([]domain.Capture, error)
	InboxStats(ctx context.Context, b domain.ScopeBinding, now time.Time) (InboxStats, error)
	Process(ctx context.Context, cmd ProcessCmd, now time.Time) (ProcessResult, error)
	GetCapture(ctx context.Context, b domain.ScopeBinding, id domain.CaptureID) (domain.Capture, error)

	// Work and planning.
	UpdateTask(ctx context.Context, b domain.ScopeBinding, in TaskUpdate, now time.Time) (domain.Task, error)
	GetWorkItem(ctx context.Context, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, error)
	GetWorkItemWithCheckpoint(ctx context.Context, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, *domain.Checkpoint, error)
	ListWorkItems(ctx context.Context, b domain.ScopeBinding, lifecycle domain.Lifecycle) ([]domain.WorkItem, error)
	ListWorkItemsFiltered(ctx context.Context, b domain.ScopeBinding, filter ListWorkItemsFilter) ([]domain.WorkItem, error)
	MoveWorkItem(ctx context.Context, cmd MoveWorkItemCmd, now time.Time) (domain.WorkItem, error)
	Prepare(ctx context.Context, b domain.ScopeBinding, date string) (PlanBrief, error)
	ReadPlan(ctx context.Context, b domain.ScopeBinding, kind domain.PlanKind, period string) (domain.Plan, error)
	CommitPlan(ctx context.Context, cmd CommitPlanCmd, now time.Time) (domain.Plan, error)
	Find(ctx context.Context, b domain.ScopeBinding, query string, limit int) ([]domain.WorkItem, error)
	SetGoal(ctx context.Context, cmd GoalCmd, now time.Time) (domain.Goal, error)
	ActiveGoal(ctx context.Context, b domain.ScopeBinding) (*domain.Goal, error)
	SetGoalStatus(ctx context.Context, b domain.ScopeBinding, status string, now time.Time) (domain.Goal, error)

	// Focus, checkpoints, reviews and routines.
	StartFocus(ctx context.Context, cmd FocusStartCmd, now time.Time) (domain.FocusSession, []domain.Checkpoint, error)
	Checkpoint(ctx context.Context, cmd CheckpointCmd, now time.Time) (domain.Checkpoint, error)
	FinishFocus(ctx context.Context, cmd FocusFinishCmd, now time.Time) (domain.FocusSession, error)
	ReadReview(ctx context.Context, b domain.ScopeBinding, kind, period string) (domain.Document, error)
	RecordReview(ctx context.Context, cmd ReviewCmd, now time.Time) (domain.Review, error)
	DueRoutines(ctx context.Context, b domain.ScopeBinding, date string) ([]domain.Routine, error)
	CompleteRoutine(ctx context.Context, b domain.ScopeBinding, id domain.RoutineID, date string) (domain.Routine, error)
	AddRoutine(ctx context.Context, cmd RoutineAddCmd) (domain.Routine, error)

	// Scopes and profiles: user configuration, never product constants.
	AddScope(ctx context.Context, cmd ScopeCmd, now time.Time) (domain.Scope, error)
	ListScopes(ctx context.Context) ([]domain.Scope, error)
	AddProfile(ctx context.Context, cmd ProfileCmd, now time.Time) (domain.Profile, error)
	SetProfileScopes(ctx context.Context, id domain.ProfileID, scopes []domain.ScopeID, now time.Time) (domain.Profile, error)
	ListProfiles(ctx context.Context) ([]domain.Profile, error)
	ApplyConfig(ctx context.Context, scopes []ScopeCmd, profiles []ProfileCmd, now time.Time) (ConfigResult, error)
	ProfileScopes(ctx context.Context, profile domain.ProfileID) ([]domain.ScopeID, error)

	// Sources and reported batches.
	AddSource(ctx context.Context, cmd SourceCmd, now time.Time) (domain.Source, error)
	ApplySources(ctx context.Context, cmds []SourceCmd, now time.Time) ([]domain.Source, error)
	ListSources(ctx context.Context, b domain.ScopeBinding) ([]domain.Source, error)
	DeleteSource(ctx context.Context, cmd SourceDeleteCmd, now time.Time) (domain.Source, error)
	RecordSourceReview(ctx context.Context, cmd SourceReviewCmd, now time.Time) (domain.SourceReview, []domain.Capture, error)

	// Contexts, documents and projects: the document layer.
	AddContext(ctx context.Context, cmd ContextCmd) (domain.Context, error)
	ListContexts(ctx context.Context, b domain.ScopeBinding) ([]domain.Context, error)
	PutDocument(ctx context.Context, cmd DocumentCmd, now time.Time) (domain.Document, error)
	GetDocument(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind, slug string, scope ...domain.ScopeID) (domain.Document, error)
	ListDocuments(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind) ([]domain.Document, error)
	SearchDocuments(ctx context.Context, b domain.ScopeBinding, query string, kind domain.DocumentKind, limit int, project ...domain.ProjectID) ([]DocumentSearchHit, error)
	ListDocumentHistory(ctx context.Context, b domain.ScopeBinding, filter DocumentHistoryFilter) ([]DocumentLogEntry, error)
	AddProject(ctx context.Context, cmd ProjectCmd, now time.Time) (domain.Project, error)
	SetProjectRepo(ctx context.Context, projectID domain.ProjectID, repoURL, clonePath string, now time.Time) (domain.Project, error)
	ListProjects(ctx context.Context, b domain.ScopeBinding) ([]domain.Project, error)
	GetProject(ctx context.Context, b domain.ScopeBinding, id domain.ProjectID) (domain.Project, error)

	// Migration and durability.
	Import(ctx context.Context, cmd ImportCmd, now time.Time) (MigrationReport, error)
	ImportDocuments(ctx context.Context, cmd ImportDocumentsCmd, now time.Time) (DocumentsImportReport, error)
	VerifyImport(ctx context.Context, cmd ImportCmd) (MigrationReport, error)
	Export(ctx context.Context, out string) error
	Restore(ctx context.Context, from string) (RestoreReport, error)
	Snapshot(ctx context.Context, out string) error
	Check(ctx context.Context, b *domain.ScopeBinding) (CheckReport, error)
}

// ScopeCmd declares one scope. An empty Name means "use the id".
type ScopeCmd struct {
	ID   string
	Name string
	Kind string
}

// ProfileCmd declares one planning profile over scopes that exist, or that
// are declared in the same batch. Actor becomes profiles.owner_actor_id.
type ProfileCmd struct {
	ID     string
	Name   string
	Kind   string
	Actor  string
	Scopes []string
}

// ConfigEntry reports whether one declaration already existed, so init can
// say what it created and what it left untouched.
type ConfigEntry struct {
	ID      string `json:"id"`
	Existed bool   `json:"existed"`
}

// ConfigResult is the outcome of one atomic scope/profile batch.
type ConfigResult struct {
	Scopes   []ConfigEntry `json:"scopes"`
	Profiles []ConfigEntry `json:"profiles"`
}

type CaptureCmd struct {
	Binding     domain.ScopeBinding
	Key         string
	Text        string
	SourceID    string
	ExternalID  *string
	ExternalRev *string
	SourceURI   *string
	OccurredAt  *time.Time
}

type InboxStats struct {
	Pending   int `json:"pending"`
	Due       int `json:"due"`
	Remaining int `json:"remaining"`
}

type ProcessCmd struct {
	Binding  domain.ScopeBinding
	Key      string
	ID       domain.CaptureID
	Expected domain.Revision
	Outcome  domain.Outcome
	Document *DocumentCmd `json:",omitempty"`
}

// ListWorkItemsFilter narrows a work item listing inside the binding scopes.
// An empty Lifecycle lists every lifecycle; Context matches contexts.name and
// Project matches project_id; Scope further narrows to one bound scope.
type ListWorkItemsFilter struct {
	Lifecycle domain.Lifecycle
	Context   string
	Project   domain.ProjectID
	Scope     domain.ScopeID
}

// MoveWorkItemCmd moves one work item between lifecycles, optionally renaming
// it and merging custom fields. Text, WaitingOn and Resolution are pointers so
// "not provided" differs from "set to empty".
type MoveWorkItemCmd struct {
	Binding     domain.ScopeBinding
	Key         string
	ID          domain.WorkItemID
	Target      domain.Lifecycle
	Text        *string
	WaitingOn   *string
	Resolution  *string
	ClosureKind domain.ClosureKind
	ProjectID   *domain.ProjectID `json:",omitempty"`
	ContextID   *domain.ContextID `json:",omitempty"`
	DueAt       *string           `json:",omitempty"`
	Fields      map[string]string
	Expected    domain.Revision
}

type ProcessResult struct {
	Capture   domain.Capture    `json:"capture"`
	WorkItems []domain.WorkItem `json:"work_items,omitempty"`
}

type CommitPlanCmd struct {
	Binding         domain.ScopeBinding
	Key             string
	Kind            domain.PlanKind
	Period          string
	Expected        domain.Revision
	Items           []domain.PlanItem
	ExceptionReason string `json:",omitempty"`
	OverrideID      string
}

type GoalCmd struct {
	Binding   domain.ScopeBinding
	Key       string
	Kind      string
	StartOn   string
	EndOn     string
	Statement string
}

// RoutineAddCmd registers one routine row in the binding's primary scope.
// Last is the optional YYYY-MM-DD of the last run; empty means due now.
type RoutineAddCmd struct {
	Binding domain.ScopeBinding
	ID      string
	Cadence string
	Last    string
}

type PlanBrief struct {
	Profile     domain.ProfileID    `json:"profile"`
	Date        string              `json:"date"`
	Goal        *domain.Goal        `json:"goal,omitempty"`
	MITs        []domain.WorkItem   `json:"mits"`
	Next        []domain.WorkItem   `json:"next"`
	Waiting     []domain.WorkItem   `json:"waiting"`
	Sources     []domain.Source     `json:"sources,omitempty"`
	Checkpoints []domain.Checkpoint `json:"checkpoints,omitempty"`
	Plan        *domain.Plan        `json:"plan,omitempty"`
	NeedsHuman  []string            `json:"needs_human,omitempty"`
}

type FocusStartCmd struct {
	Binding domain.ScopeBinding
	Key     string
	Item    domain.WorkItemID
}

type CheckpointCmd struct {
	Binding    domain.ScopeBinding
	Key        string
	Item       domain.WorkItemID
	Result     string
	Evidence   []string
	Uncertain  string
	NextAction string
}

type FocusFinishCmd struct {
	Binding domain.ScopeBinding
	Key     string
	Focus   domain.FocusID
	Outcome string
}

type ReviewCmd struct {
	Binding  domain.ScopeBinding
	Key      string
	Kind     string
	Period   string
	Outcomes string
	Coverage string
	Complete bool
}

type SourceCmd struct {
	Binding        domain.ScopeBinding
	ID             string
	Name           string
	Scope          domain.ScopeID
	Kind           domain.SourceKind
	Connector      domain.SourceConnector
	Provider       string
	ConnectionRef  string
	NonSecretQuery string
	Cadence        string
}

// SourceDeleteCmd removes one source. Key is optional: a retry with the same
// key and id replays the stored result, and MCP always supplies one.
type SourceDeleteCmd struct {
	Binding domain.ScopeBinding
	ID      string
	Key     string
}

type SourceReviewCmd struct {
	Binding    domain.ScopeBinding
	SourceID   string
	BatchID    string
	Key        string
	ResultKind string
	Retrieval  domain.SourceRetrieval
	Items      []domain.SourceItem
}

// ContextCmd declares one GTD context name in the binding's primary scope.
type ContextCmd struct {
	Binding domain.ScopeBinding
	Name    string
}

// DocumentCmd creates or updates the document identified by
// (Scope or binding primary scope, Kind, Slug). Expected is 0 on create and the current
// revision on update. DraftOnly is a store-side access policy, not payload: it
// forbids promoting a document past draft and, at Expected 0, refuses to touch
// an existing document. It is excluded from the idempotency hash so the same
// content hashes identically through the CLI and the MCP path.
type DocumentCmd struct {
	Binding   domain.ScopeBinding
	Scope     domain.ScopeID `json:"-"`
	Kind      domain.DocumentKind
	Slug      string
	Title     string
	Body      string
	Status    domain.DocumentStatus
	Expected  domain.Revision
	Sources   []string          `json:",omitempty"`
	ProjectID *domain.ProjectID `json:",omitempty"`
	DraftOnly bool              `json:"-"`
}

// DocumentLogEntry is one append-only history event of a document, carrying
// the document's own scope, kind and slug: history scope_id may be null, so
// the join against documents is what identifies the entry.
type DocumentLogEntry struct {
	Seq       int64           `json:"seq"`
	Event     string          `json:"event"`
	Revision  domain.Revision `json:"revision"`
	CreatedAt time.Time       `json:"created_at"`
	Scope     string          `json:"scope"`
	Kind      string          `json:"kind"`
	Slug      string          `json:"slug"`
}

// DocumentSearchHit is one FTS5 match: the document itself, its bm25 rank
// (smaller is a better match) and a highlighted excerpt of the body.
type DocumentSearchHit struct {
	Document domain.Document `json:"document"`
	Rank     float64         `json:"rank"`
	Snippet  string          `json:"snippet"`
}

// DocumentHistoryFilter narrows one document history listing. An empty Kind
// or Slug lists every document; Limit 0 selects the default of 50 and values
// above 500 are capped.
type DocumentHistoryFilter struct {
	Kind  domain.DocumentKind
	Slug  string
	Limit int
}

// ProjectCmd declares one project in the binding's primary scope. RepoURL and
// ClonePath are optional repository metadata; the id keeps its caller-chosen
// (possibly legacy path) form.
type ProjectCmd struct {
	Binding        domain.ScopeBinding
	ID             string
	DesiredOutcome string
	Status         string
	RepoURL        string
	ClonePath      string
}

type ImportCmd struct {
	SourceCopy    string
	AgentExport   string
	Target        string
	ReportPath    string
	MappingPath   string
	LegacyCheck   string
	LegacyVersion string
	Actor         string
}

// ImportDocumentsCmd populates the document layer from a verified copy of the
// legacy Markdown store. Workspace resolves the relative clone paths on
// project cards (it defaults to the current directory); DryRun plans and
// reports without writing anything.
type ImportDocumentsCmd struct {
	Source      string
	MappingPath string
	Workspace   string
	DryRun      bool
}

// DocumentsImportReport counts one documents import run. Skipped covers files
// that were refused (unknown path, invalid UTF-8, empty body, bad slug), each
// with its reason in Warnings; silent store files are not counted.
type DocumentsImportReport struct {
	Inserted  int      `json:"inserted"`
	Updated   int      `json:"updated"`
	Unchanged int      `json:"unchanged"`
	Skipped   int      `json:"skipped"`
	Warnings  []string `json:"warnings,omitempty"`
}

type MigrationReport struct {
	Version       int           `json:"version"`
	SourceHash    string        `json:"source_hash"`
	SourceVersion string        `json:"source_version"`
	CheckResult   string        `json:"check_result"`
	Imported      int           `json:"imported"`
	Quarantined   int           `json:"quarantined"`
	Dispositions  []Disposition `json:"dispositions"`
	Errors        []string      `json:"errors,omitempty"`
}

type Disposition struct {
	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
	State      string `json:"state"`
	Reason     string `json:"reason,omitempty"`
	Original   string `json:"original,omitempty"`
}

type RestoreReport struct {
	Tables map[string]int `json:"tables"`
}

type CheckReport struct {
	OK       bool     `json:"ok"`
	Errors   []string `json:"errors,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}
