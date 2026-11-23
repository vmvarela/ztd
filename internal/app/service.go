package app

import (
	"context"
	"regexp"
	"strings"
	"time"

	"ztd/internal/domain"
)

type Service struct {
	Repo  Repo
	Clock Clock
}

type systemClock struct{}

func (systemClock) Now() time.Time { return domain.NowUTC() }

func New(repo Repo) *Service { return &Service{Repo: repo, Clock: systemClock{}} }

func (s *Service) now() time.Time {
	if s.Clock == nil {
		return domain.NowUTC()
	}
	return s.Clock.Now().UTC()
}

// Now exposes the service clock to adapters that need the same time source.
func (s *Service) Now() time.Time { return s.now() }

func (s *Service) Capture(ctx context.Context, cmd CaptureCmd) (domain.Capture, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Capture{}, err
	}
	if strings.TrimSpace(cmd.Text) == "" {
		return domain.Capture{}, domain.Invalid("capture text is required")
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.Capture{}, domain.Invalid("idempotency key is required")
	}
	if len(cmd.Text) > 64*1024 {
		return domain.Capture{}, domain.Invalid("capture text exceeds 64 KiB")
	}
	return s.Repo.Capture(ctx, cmd, s.now())
}

func (s *Service) InboxNext(ctx context.Context, b domain.ScopeBinding) (domain.Capture, error) {
	if err := b.Validate(); err != nil {
		return domain.Capture{}, err
	}
	return s.Repo.InboxNext(ctx, b, s.now())
}

func (s *Service) InboxStats(ctx context.Context, b domain.ScopeBinding) (InboxStats, error) {
	if err := b.Validate(); err != nil {
		return InboxStats{}, err
	}
	return s.Repo.InboxStats(ctx, b, s.now())
}

// ListInbox returns the captures awaiting processing in the binding scopes,
// oldest first, capped so one call stays bounded.
func (s *Service) ListInbox(ctx context.Context, b domain.ScopeBinding) ([]domain.Capture, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ListInbox(ctx, b, s.now())
}

// ListWorkItemsFiltered returns the work items of the binding scopes that
// match the filter.
func (s *Service) ListWorkItemsFiltered(ctx context.Context, b domain.ScopeBinding, filter ListWorkItemsFilter) ([]domain.WorkItem, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ListWorkItemsFiltered(ctx, b, filter)
}

// MoveWorkItem applies one lifecycle transition. The store mirrors these
// checks so direct Repo callers get identical errors.
func (s *Service) MoveWorkItem(ctx context.Context, cmd MoveWorkItemCmd) (domain.WorkItem, error) {
	if err := ValidateMoveCmd(cmd); err != nil {
		return domain.WorkItem{}, err
	}
	return s.Repo.MoveWorkItem(ctx, cmd, s.now())
}

// ValidateMoveCmd is the shared precondition check for a move: a valid
// binding and key, one known target lifecycle, the fields that target
// requires, a known closure kind and no reserved custom field key.
func ValidateMoveCmd(cmd MoveWorkItemCmd) error {
	if err := cmd.Binding.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.Invalid("idempotency key is required")
	}
	if strings.TrimSpace(string(cmd.ID)) == "" {
		return domain.Invalid("work item id is required")
	}
	switch cmd.Target {
	case domain.Next, domain.Waiting, domain.Someday, domain.Archived:
	default:
		return domain.Invalid("move target must be next, waiting, someday or archived, got %q", cmd.Target)
	}
	if cmd.Text != nil && strings.TrimSpace(*cmd.Text) == "" {
		return domain.Invalid("text cannot be empty")
	}
	if cmd.Target == domain.Waiting && (cmd.WaitingOn == nil || strings.TrimSpace(*cmd.WaitingOn) == "") {
		return domain.Invalid("waiting requires waiting_on")
	}
	if cmd.Target == domain.Archived && (cmd.Resolution == nil || strings.TrimSpace(*cmd.Resolution) == "") {
		return domain.Invalid("archive requires resolution")
	}
	switch cmd.ClosureKind {
	case "", domain.Completed, domain.Cancelled, domain.Unspecified:
	default:
		return domain.Invalid("closure kind must be completed, cancelled or unspecified, got %q", cmd.ClosureKind)
	}
	for key := range cmd.Fields {
		if strings.TrimSpace(key) == "" {
			return domain.Invalid("field keys cannot be empty")
		}
		if domain.IsReservedField(key) {
			return domain.Invalid("field %q is reserved: waiting_on, resolution, context, client, project, captured_at and closed_at have their own columns", key)
		}
	}
	return nil
}

func (s *Service) Process(ctx context.Context, cmd ProcessCmd) (ProcessResult, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return ProcessResult{}, err
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return ProcessResult{}, domain.Invalid("idempotency key is required")
	}
	if cmd.ID == "" {
		return ProcessResult{}, domain.Invalid("capture id is required")
	}
	if err := validateOutcome(cmd.Outcome); err != nil {
		return ProcessResult{}, err
	}
	return s.Repo.Process(ctx, cmd, s.now())
}

func validateOutcome(o domain.Outcome) error {
	switch o.Kind {
	case domain.OutcomeWorkItems:
		if len(o.Titles) == 0 {
			return domain.Invalid("work_items outcome requires at least one title")
		}
		for _, title := range o.Titles {
			if strings.TrimSpace(title) == "" {
				return domain.Invalid("work item titles cannot be blank")
			}
		}
	case domain.OutcomeReference:
	case domain.OutcomeImmediate:
		if strings.TrimSpace(o.ResultEvidence) == "" {
			return domain.Invalid("immediate outcome requires result evidence")
		}
	case domain.OutcomeDiscard:
		if strings.TrimSpace(o.Reason) == "" {
			return domain.Invalid("discard outcome requires a reason")
		}
	case domain.OutcomeDefer:
		if o.ReviewAfter == nil {
			return domain.Invalid("defer outcome requires review_after")
		}
	default:
		return domain.Invalid("unknown outcome kind %q", o.Kind)
	}
	return nil
}

func (s *Service) SetGoal(ctx context.Context, cmd GoalCmd) (domain.Goal, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Goal{}, err
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.Goal{}, domain.Invalid("idempotency key is required")
	}
	switch cmd.Kind {
	case "primary", "subgoal":
	default:
		return domain.Goal{}, domain.Invalid("goal kind must be primary or subgoal")
	}
	if strings.TrimSpace(cmd.Statement) == "" {
		return domain.Goal{}, domain.Invalid("goal statement is required")
	}
	if cmd.StartOn == "" {
		cmd.StartOn = domain.FormatDate(s.now())
	}
	if _, err := time.Parse("2006-01-02", cmd.StartOn); err != nil {
		return domain.Goal{}, domain.Invalid("start_on must be YYYY-MM-DD")
	}
	if cmd.EndOn != "" {
		if _, err := time.Parse("2006-01-02", cmd.EndOn); err != nil {
			return domain.Goal{}, domain.Invalid("end_on must be YYYY-MM-DD")
		}
	}
	return s.Repo.SetGoal(ctx, cmd, s.now())
}

func (s *Service) ActiveGoal(ctx context.Context, b domain.ScopeBinding) (*domain.Goal, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ActiveGoal(ctx, b)
}

// SetGoalStatus closes the Profile's primary goal: "completed" or
// "cancelled". Repeating the same close is idempotent; the other terminal
// status is invalid_transition and a Profile without a primary goal is
// not_found.
func (s *Service) SetGoalStatus(ctx context.Context, b domain.ScopeBinding, status string) (domain.Goal, error) {
	if err := b.Validate(); err != nil {
		return domain.Goal{}, err
	}
	return s.Repo.SetGoalStatus(ctx, b, status, s.now())
}

func (s *Service) Prepare(ctx context.Context, b domain.ScopeBinding, date string) (PlanBrief, error) {
	if err := b.Validate(); err != nil {
		return PlanBrief{}, err
	}
	if date == "" {
		date = domain.FormatDate(s.now())
	}
	return s.Repo.Prepare(ctx, b, date)
}

func (s *Service) CommitPlan(ctx context.Context, cmd CommitPlanCmd) (domain.Plan, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Plan{}, err
	}
	if cmd.Kind != domain.DailyPlan && cmd.Kind != domain.WeeklyPlan {
		return domain.Plan{}, domain.Invalid("plan kind must be daily or weekly")
	}
	if strings.TrimSpace(cmd.Period) == "" {
		return domain.Plan{}, domain.Invalid("plan period is required")
	}
	seen := make(map[domain.WorkItemID]bool)
	mits := 0
	for _, item := range cmd.Items {
		if seen[item.WorkItemID] {
			return domain.Plan{}, domain.Invalid("duplicate plan item %s", item.WorkItemID)
		}
		seen[item.WorkItemID] = true
		if item.Role != domain.MITRole && item.Role != domain.BigRockRole && item.Role != domain.BatchRole {
			return domain.Plan{}, domain.Invalid("invalid plan role %q", item.Role)
		}
		if item.Role == domain.MITRole && cmd.Kind == domain.DailyPlan {
			mits++
		}
	}
	if mits > 3 && cmd.OverrideID == "" {
		return domain.Plan{}, domain.NewError(domain.RulesAcknowledgement, "daily plan has %d MITs; an override is required", mits)
	}
	return s.Repo.CommitPlan(ctx, cmd, s.now())
}

// AddRoutine registers a routine row in the binding's primary scope; the
// cadence follows the due list semantics (daily or weekly:<day>).
func (s *Service) AddRoutine(ctx context.Context, cmd RoutineAddCmd) (domain.Routine, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Routine{}, err
	}
	return s.Repo.AddRoutine(ctx, cmd)
}

func (s *Service) StartFocus(ctx context.Context, cmd FocusStartCmd) (domain.FocusSession, []domain.Checkpoint, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.FocusSession{}, nil, err
	}
	if cmd.Item == "" {
		return domain.FocusSession{}, nil, domain.Invalid("work item is required")
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.FocusSession{}, nil, domain.Invalid("idempotency key is required")
	}
	return s.Repo.StartFocus(ctx, cmd, s.now())
}

func (s *Service) Checkpoint(ctx context.Context, cmd CheckpointCmd) (domain.Checkpoint, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Checkpoint{}, err
	}
	if strings.TrimSpace(cmd.Result) == "" {
		return domain.Checkpoint{}, domain.Invalid("checkpoint result is required")
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.Checkpoint{}, domain.Invalid("idempotency key is required")
	}
	return s.Repo.Checkpoint(ctx, cmd, s.now())
}

func (s *Service) FinishFocus(ctx context.Context, cmd FocusFinishCmd) (domain.FocusSession, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.FocusSession{}, err
	}
	return s.Repo.FinishFocus(ctx, cmd, s.now())
}

// configIDPattern is the shared id grammar for scopes and profiles. Ids may
// carry ":" (work:prisamedia) but never the declaration separators ",", "|"
// or "=", so a key=value declaration line always parses back.
var configIDPattern = regexp.MustCompile(`^[a-z][a-z0-9_:.-]{0,63}$`)

// ValidConfigID reports whether s is usable as a scope or profile id.
func ValidConfigID(s string) bool { return configIDPattern.MatchString(s) }

// ValidateScopeCmd is the shared precondition check for a scope declaration;
// the store calls it too so direct Repo callers get identical errors.
func ValidateScopeCmd(cmd ScopeCmd) error {
	if !ValidConfigID(cmd.ID) {
		return domain.Invalid("scope id must start with a lowercase letter and use only a-z 0-9 _ : . - (max 64 chars, no , | or =)")
	}
	switch cmd.Kind {
	case string(domain.ScopeKindPersonal), string(domain.ScopeKindWork),
		string(domain.ScopeKindClient), string(domain.ScopeKindOpensource):
	default:
		return domain.Invalid("unknown scope kind %q (personal, work, client or opensource)", cmd.Kind)
	}
	return nil
}

// ValidateProfileCmd is the shared precondition check for a profile
// declaration. It covers what can be known without the database: the kind
// rules that need scope kinds live in the store, inside the write
// transaction.
func ValidateProfileCmd(cmd ProfileCmd) error {
	if !ValidConfigID(cmd.ID) {
		return domain.Invalid("profile id must start with a lowercase letter and use only a-z 0-9 _ : . - (max 64 chars, no , | or =)")
	}
	switch cmd.Kind {
	case string(domain.PersonalProfile), string(domain.WorkClientProfile):
	default:
		return domain.Invalid("unknown profile kind %q (personal or work_client)", cmd.Kind)
	}
	if strings.TrimSpace(cmd.Actor) == "" {
		return domain.Invalid("profile %s needs an owner actor", cmd.ID)
	}
	if len(cmd.Scopes) == 0 {
		return domain.Invalid("profile %s needs at least one scope", cmd.ID)
	}
	seen := make(map[string]bool, len(cmd.Scopes))
	for _, sc := range cmd.Scopes {
		if !ValidConfigID(sc) {
			return domain.Invalid("profile %s references an invalid scope id %q", cmd.ID, sc)
		}
		if seen[sc] {
			return domain.Invalid("profile %s lists scope %s twice", cmd.ID, sc)
		}
		seen[sc] = true
	}
	if cmd.Kind == string(domain.WorkClientProfile) && len(cmd.Scopes) != 1 {
		return domain.Invalid("work_client profile %s needs exactly one scope, got %d", cmd.ID, len(cmd.Scopes))
	}
	return nil
}

// AddScope declares one scope. Scopes are user configuration: the store keeps
// an existing row only when kind and name are identical, otherwise conflict.
func (s *Service) AddScope(ctx context.Context, cmd ScopeCmd) (domain.Scope, error) {
	if err := ValidateScopeCmd(cmd); err != nil {
		return domain.Scope{}, err
	}
	return s.Repo.AddScope(ctx, cmd, s.now())
}

// ListScopes returns every declared scope ordered by id.
func (s *Service) ListScopes(ctx context.Context) ([]domain.Scope, error) {
	return s.Repo.ListScopes(ctx)
}

// AddProfile declares one planning profile over scopes that exist. The owner
// actor is part of the identity: re-adding with another actor is conflict.
func (s *Service) AddProfile(ctx context.Context, cmd ProfileCmd) (domain.Profile, error) {
	if err := ValidateProfileCmd(cmd); err != nil {
		return domain.Profile{}, err
	}
	return s.Repo.AddProfile(ctx, cmd, s.now())
}

// SetProfileScopes replaces the scope set of an existing profile. The profile
// keeps its kind and owner; only the planning view changes.
func (s *Service) SetProfileScopes(ctx context.Context, id domain.ProfileID, scopes []domain.ScopeID) (domain.Profile, error) {
	if strings.TrimSpace(string(id)) == "" {
		return domain.Profile{}, domain.Invalid("profile id is required")
	}
	if len(scopes) == 0 {
		return domain.Profile{}, domain.Invalid("profile needs at least one scope")
	}
	return s.Repo.SetProfileScopes(ctx, id, scopes, s.now())
}

// ListProfiles returns every profile with its scopes, ordered by id.
func (s *Service) ListProfiles(ctx context.Context) ([]domain.Profile, error) {
	return s.Repo.ListProfiles(ctx)
}

// ApplyConfig applies a whole scope/profile declaration in one transaction:
// either every entry lands or none does. It never deletes what it does not
// declare.
func (s *Service) ApplyConfig(ctx context.Context, scopes []ScopeCmd, profiles []ProfileCmd) (ConfigResult, error) {
	if len(scopes) == 0 {
		return ConfigResult{}, domain.Invalid("at least one scope declaration is required")
	}
	if len(profiles) == 0 {
		return ConfigResult{}, domain.Invalid("at least one profile declaration is required")
	}
	for _, cmd := range scopes {
		if err := ValidateScopeCmd(cmd); err != nil {
			return ConfigResult{}, err
		}
	}
	for _, cmd := range profiles {
		if err := ValidateProfileCmd(cmd); err != nil {
			return ConfigResult{}, err
		}
	}
	return s.Repo.ApplyConfig(ctx, scopes, profiles, s.now())
}

// AddSource registers one source in a scope of the binding.
func (s *Service) AddSource(ctx context.Context, cmd SourceCmd) (domain.Source, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Source{}, err
	}
	if err := validateSourceCmd(cmd); err != nil {
		return domain.Source{}, err
	}
	return s.Repo.AddSource(ctx, cmd, s.now())
}

// ApplySources synchronizes a user-defined source configuration. Sources are
// data: ZTD validates generic fields and never selects a provider or performs
// retrieval. Existing sources keep their coverage, cursor and auth state.
func (s *Service) ApplySources(ctx context.Context, cmds []SourceCmd) ([]domain.Source, error) {
	if len(cmds) == 0 {
		return nil, domain.Invalid("source configuration is empty")
	}
	if len(cmds) > domain.MaxSourceConfigItems {
		return nil, domain.Invalid("source configuration exceeds %d entries", domain.MaxSourceConfigItems)
	}
	seen := make(map[string]bool, len(cmds))
	for _, cmd := range cmds {
		if err := cmd.Binding.Validate(); err != nil {
			return nil, err
		}
		if err := validateSourceCmd(cmd); err != nil {
			return nil, err
		}
		if seen[cmd.ID] {
			return nil, domain.Invalid("duplicate source id %s", cmd.ID)
		}
		seen[cmd.ID] = true
	}
	return s.Repo.ApplySources(ctx, cmds, s.now())
}

// validateSourceCmd is the shared precondition check; the store mirrors it so
// direct Repo callers get identical errors.
func validateSourceCmd(cmd SourceCmd) error {
	if !domain.ValidSourceID(cmd.ID) {
		return domain.Invalid("source id must match [a-z][a-z0-9_-]{1,63}")
	}
	if strings.TrimSpace(cmd.Name) == "" {
		return domain.Invalid("source name is required")
	}
	switch cmd.Kind {
	case domain.SourceKindCapture, domain.SourceKindCalendar:
	default:
		return domain.Invalid("unknown source kind %q", cmd.Kind)
	}
	switch cmd.Connector {
	case domain.SourceConnectorManual, domain.SourceConnectorDirectory, domain.SourceConnectorHostMCP:
	default:
		return domain.Invalid("unknown source connector %q", cmd.Connector)
	}
	if cmd.Scope == "" {
		return domain.Invalid("source scope is required")
	}
	if !cmd.Binding.Allows(cmd.Scope) {
		return domain.NewError(domain.ScopeDenied, "scope %s is outside the active scopes", cmd.Scope)
	}
	return nil
}

// DeleteSource removes one source of the binding scopes that no capture or
// review refers to. The store enforces the reference rule and the scope check.
func (s *Service) DeleteSource(ctx context.Context, cmd SourceDeleteCmd) (domain.Source, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Source{}, err
	}
	if !domain.ValidSourceID(cmd.ID) {
		return domain.Source{}, domain.Invalid("source id must match [a-z][a-z0-9_-]{1,63}")
	}
	return s.Repo.DeleteSource(ctx, cmd, s.now())
}

// ListSources returns the sources of the binding scopes.
func (s *Service) ListSources(ctx context.Context, b domain.ScopeBinding) ([]domain.Source, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ListSources(ctx, b)
}

// RecordSourceReview stores one retrieval batch reported for a source. Only
// reported coverage is accepted for now: observed coverage would claim a
// trusted host adapter that does not exist yet.
func (s *Service) RecordSourceReview(ctx context.Context, cmd SourceReviewCmd) (domain.SourceReview, []domain.Capture, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.SourceReview{}, nil, err
	}
	if err := validateSourceReviewCmd(cmd); err != nil {
		return domain.SourceReview{}, nil, err
	}
	return s.Repo.RecordSourceReview(ctx, cmd, s.now())
}

// validateSourceReviewCmd is the shared batch precondition check; the store
// mirrors it so direct Repo callers get identical errors. The batch is
// bounded by domain.MaxSourceBatchItems.
func validateSourceReviewCmd(cmd SourceReviewCmd) error {
	if !domain.ValidSourceID(cmd.SourceID) {
		return domain.Invalid("source id must match [a-z][a-z0-9_-]{1,63}")
	}
	if strings.TrimSpace(cmd.BatchID) == "" {
		return domain.Invalid("batch id is required")
	}
	if strings.TrimSpace(cmd.Key) == "" {
		return domain.Invalid("idempotency key is required")
	}
	switch cmd.ResultKind {
	case "reported":
	case "observed":
		return domain.Invalid("observed coverage requires a trusted host adapter")
	default:
		return domain.Invalid("result kind must be reported, got %q", cmd.ResultKind)
	}
	if len(cmd.Items) > domain.MaxSourceBatchItems {
		return domain.Invalid("source batch exceeds %d items", domain.MaxSourceBatchItems)
	}
	for i, item := range cmd.Items {
		if err := item.Validate(); err != nil {
			return domain.Invalid("source item %d: %v", i, err)
		}
	}
	return nil
}

// ValidateContextCmd is the shared precondition check for a context
// declaration; the store calls it too so direct Repo callers get identical
// errors.
func ValidateContextCmd(cmd ContextCmd) error {
	if err := cmd.Binding.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(cmd.Name) == "" {
		return domain.Invalid("context name is required")
	}
	return nil
}

// documentSlugPattern is the shared slug grammar: non-empty, letters, digits
// and the path-ish separators -, _, / and ..
var documentSlugPattern = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)

// ValidDocumentSlug reports whether s satisfies the document slug grammar.
func ValidDocumentSlug(s string) bool { return documentSlugPattern.MatchString(s) }

// ValidateDocumentCmd is the shared precondition check for a document put; the
// store calls it too so direct Repo callers get identical errors.
func ValidateDocumentCmd(cmd DocumentCmd) error {
	if err := cmd.Binding.Validate(); err != nil {
		return err
	}
	if !domain.ValidDocumentKind(cmd.Kind) {
		return domain.Invalid("unknown document kind %q", cmd.Kind)
	}
	if !domain.ValidDocumentStatus(cmd.Status) {
		return domain.Invalid("unknown document status %q (want draft, verified or superseded)", cmd.Status)
	}
	if !documentSlugPattern.MatchString(cmd.Slug) {
		return domain.Invalid("document slug must be non-empty and use only letters, digits, -, _, / and .")
	}
	if strings.TrimSpace(cmd.Title) == "" {
		return domain.Invalid("document title is required")
	}
	if strings.TrimSpace(cmd.Body) == "" {
		return domain.Invalid("document body is required")
	}
	if cmd.Expected < 0 {
		return domain.Invalid("expected revision cannot be negative")
	}
	if cmd.DraftOnly && cmd.Status != domain.DocumentDraft {
		return domain.Invalid("draft-only write cannot set status %q (want draft)", cmd.Status)
	}
	return nil
}

// repoURLCredentials matches a scheme followed by userinfo before the host:
// scheme://user:pass@host — the shape ZTD never stores.
var repoURLCredentials = regexp.MustCompile(`://[^/?#]*@`)

// isAbsoluteAnyOS reports whether p is absolute on POSIX or on Windows, so a
// clone path recorded on one platform stays valid on the other.
func isAbsoluteAnyOS(p string) bool {
	if strings.HasPrefix(p, "/") || strings.HasPrefix(p, `\`) {
		return true
	}
	return len(p) >= 3 && p[1] == ':' && (p[2] == '/' || p[2] == '\\') &&
		(p[0] >= 'A' && p[0] <= 'Z' || p[0] >= 'a' && p[0] <= 'z')
}

// validClonePath reports whether p is an absolute path with no ".." segment.
func validClonePath(p string) bool {
	if !isAbsoluteAnyOS(p) {
		return false
	}
	for _, seg := range strings.FieldsFunc(p, func(r rune) bool { return r == '/' || r == '\\' }) {
		if seg == ".." {
			return false
		}
	}
	return true
}

// ValidClonePath reports whether p is a storegable clone path: absolute with
// no ".." segment.
func ValidClonePath(p string) bool { return validClonePath(p) }

// repoURLScp matches the scp-style remote git uses: user@host:path.
var repoURLScp = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+$`)

// ValidRepoURL reports whether u is a storegable repository URL: an absolute
// URL with a scheme or an scp-style remote, and no embedded credentials.
func ValidRepoURL(u string) bool {
	if repoURLScp.MatchString(u) {
		return true
	}
	return strings.Contains(u, "://") && !repoURLCredentials.MatchString(u)
}

// ValidateProjectCmd is the shared precondition check for a project
// declaration; the store calls it too so direct Repo callers get identical
// errors.
func ValidateProjectCmd(cmd ProjectCmd) error {
	if err := cmd.Binding.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(cmd.ID) == "" {
		return domain.Invalid("project id is required")
	}
	switch cmd.Status {
	case "active", "paused", "completed", "cancelled":
	default:
		return domain.Invalid("project status must be active, paused, completed or cancelled, got %q", cmd.Status)
	}
	if cmd.ClonePath != "" && !validClonePath(cmd.ClonePath) {
		return domain.Invalid("clone path must be an absolute path without .. segments, got %q", cmd.ClonePath)
	}
	if cmd.RepoURL != "" && !ValidRepoURL(cmd.RepoURL) {
		if repoURLCredentials.MatchString(cmd.RepoURL) {
			return domain.Invalid("repository url must not contain credentials")
		}
		return domain.Invalid("repository url must include a scheme or use user@host:path, got %q", cmd.RepoURL)
	}
	return nil
}

// AddContext declares one context name in the binding's primary scope.
func (s *Service) AddContext(ctx context.Context, cmd ContextCmd) (domain.Context, error) {
	if err := ValidateContextCmd(cmd); err != nil {
		return domain.Context{}, err
	}
	return s.Repo.AddContext(ctx, cmd)
}

// ListContexts returns the contexts of the binding scopes.
func (s *Service) ListContexts(ctx context.Context, b domain.ScopeBinding) ([]domain.Context, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ListContexts(ctx, b)
}

// PutDocument creates or updates the document identified by (scope, kind,
// slug). It is idempotent by that triple plus the expected revision.
func (s *Service) PutDocument(ctx context.Context, cmd DocumentCmd) (domain.Document, error) {
	if err := ValidateDocumentCmd(cmd); err != nil {
		return domain.Document{}, err
	}
	return s.Repo.PutDocument(ctx, cmd, s.now())
}

// GetDocument returns one document of the binding scopes.
func (s *Service) GetDocument(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind, slug string) (domain.Document, error) {
	if err := b.Validate(); err != nil {
		return domain.Document{}, err
	}
	if !domain.ValidDocumentKind(kind) {
		return domain.Document{}, domain.Invalid("unknown document kind %q", kind)
	}
	if strings.TrimSpace(slug) == "" {
		return domain.Document{}, domain.Invalid("document slug is required")
	}
	return s.Repo.GetDocument(ctx, b, kind, slug)
}

// ListDocuments returns the documents of the binding scopes. An empty kind
// lists every kind.
func (s *Service) ListDocuments(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind) ([]domain.Document, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	if kind != "" && !domain.ValidDocumentKind(kind) {
		return nil, domain.Invalid("unknown document kind %q", kind)
	}
	return s.Repo.ListDocuments(ctx, b, kind)
}

// ListDocumentHistory returns the newest-first history of the binding scopes'
// documents, optionally narrowed to one kind or slug.
func (s *Service) ListDocumentHistory(ctx context.Context, b domain.ScopeBinding, filter DocumentHistoryFilter) ([]DocumentLogEntry, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	if filter.Kind != "" && !domain.ValidDocumentKind(filter.Kind) {
		return nil, domain.Invalid("unknown document kind %q", filter.Kind)
	}
	return s.Repo.ListDocumentHistory(ctx, b, filter)
}

// SearchDocuments runs one read-only FTS5 query over the binding scopes'
// documents, optionally narrowed to one kind, best match first.
func (s *Service) SearchDocuments(ctx context.Context, b domain.ScopeBinding, query string, kind domain.DocumentKind, limit int) ([]DocumentSearchHit, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(query) == "" {
		return nil, domain.Invalid("search query is required")
	}
	if kind != "" && !domain.ValidDocumentKind(kind) {
		return nil, domain.Invalid("unknown document kind %q", kind)
	}
	return s.Repo.SearchDocuments(ctx, b, query, kind, limit)
}

// RelatedDocuments returns the link neighbourhood of one document: the
// documents it links to and the ones that link back, resolved inside the
// source's own scope. A document outside the binding is not_found.
func (s *Service) RelatedDocuments(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind, slug string) (DocumentRelations, error) {
	if err := b.Validate(); err != nil {
		return DocumentRelations{}, err
	}
	if !domain.ValidDocumentKind(kind) {
		return DocumentRelations{}, domain.Invalid("unknown document kind %q", kind)
	}
	if strings.TrimSpace(slug) == "" {
		return DocumentRelations{}, domain.Invalid("document slug is required")
	}
	source, err := s.Repo.GetDocument(ctx, b, kind, slug)
	if err != nil {
		return DocumentRelations{}, err
	}
	docs, err := s.Repo.ListDocuments(ctx, b, "")
	if err != nil {
		return DocumentRelations{}, err
	}
	return RelatedDocuments(docs, source), nil
}

// DocumentLint loads the binding scopes' documents and lints them with the
// pure deterministic rules in LintDocuments; it never writes.
func (s *Service) DocumentLint(ctx context.Context, b domain.ScopeBinding) (LintReport, error) {
	if err := b.Validate(); err != nil {
		return LintReport{}, err
	}
	docs, err := s.Repo.ListDocuments(ctx, b, "")
	if err != nil {
		return LintReport{}, err
	}
	return LintDocuments(docs), nil
}

// AddProject declares one project in the binding's primary scope. The id keeps
// its caller-chosen form, including legacy path-style ids.
func (s *Service) AddProject(ctx context.Context, cmd ProjectCmd) (domain.Project, error) {
	if err := ValidateProjectCmd(cmd); err != nil {
		return domain.Project{}, err
	}
	return s.Repo.AddProject(ctx, cmd, s.now())
}

// ListProjects returns the projects of the binding scopes.
func (s *Service) ListProjects(ctx context.Context, b domain.ScopeBinding) ([]domain.Project, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return s.Repo.ListProjects(ctx, b)
}

// GetProject returns one project of the binding scopes.
func (s *Service) GetProject(ctx context.Context, b domain.ScopeBinding, id domain.ProjectID) (domain.Project, error) {
	if err := b.Validate(); err != nil {
		return domain.Project{}, err
	}
	if strings.TrimSpace(string(id)) == "" {
		return domain.Project{}, domain.Invalid("project id is required")
	}
	return s.Repo.GetProject(ctx, b, id)
}

// SetProjectRepo fills the empty repository fields of an existing project; a
// field that already holds a different value is kept.
func (s *Service) SetProjectRepo(ctx context.Context, projectID domain.ProjectID, repoURL, clonePath string) (domain.Project, error) {
	if strings.TrimSpace(string(projectID)) == "" {
		return domain.Project{}, domain.Invalid("project id is required")
	}
	return s.Repo.SetProjectRepo(ctx, projectID, repoURL, clonePath, s.now())
}

// ImportDocuments populates the document layer from a verified copy of the
// legacy Markdown store; the store never reads ~/.ztd directly.
func (s *Service) ImportDocuments(ctx context.Context, cmd ImportDocumentsCmd) (DocumentsImportReport, error) {
	if strings.TrimSpace(cmd.Source) == "" {
		return DocumentsImportReport{}, domain.Invalid("source copy is required")
	}
	return s.Repo.ImportDocuments(ctx, cmd, s.now())
}
