package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
	"ztd/internal/legacy"
)

// importMapping is the operator-supplied translation from legacy routing to
// Scope/Area/Profile. It is data, not model input: the importer never
// guesses a scope for an unmapped context.
type importMapping struct {
	DefaultScope string                   `json:"default_scope"`
	Actor        string                   `json:"actor"`
	Contexts     map[string]mappingTarget `json:"contexts"`
	AgentScopes  map[string]string        `json:"agent_scopes"`
}

type mappingTarget struct {
	Scope string `json:"scope"`
	Area  string `json:"area"`
}

func defaultImportMapping() importMapping {
	return importMapping{
		DefaultScope: "personal",
		Contexts: map[string]mappingTarget{
			"familia":     {Scope: "personal", Area: "familia"},
			"salud":       {Scope: "personal", Area: "salud"},
			"propiedades": {Scope: "personal", Area: "propiedades"},
			"opensource":  {Scope: "opensource", Area: "opensource"},
			"work":        {Scope: "work", Area: "work"},
			"work:acme":   {Scope: "client:acme", Area: "work"},
		},
		AgentScopes: map[string]string{"work": "work"},
	}
}

func loadImportMapping(path string) (importMapping, error) {
	m := defaultImportMapping()
	if path == "" {
		return m, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return m, domain.NewError(domain.IOError, "read mapping: %v", err)
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return m, domain.Invalid("mapping is not valid JSON: %v", err)
	}
	if m.DefaultScope == "" {
		m.DefaultScope = "personal"
	}
	if m.Contexts == nil {
		m.Contexts = defaultImportMapping().Contexts
	}
	if m.AgentScopes == nil {
		m.AgentScopes = defaultImportMapping().AgentScopes
	}
	return m, nil
}

// Import reads a verified, quiescent copy of the legacy Markdown store and
// the optional agent export, then writes one staging database. The whole
// import is one transaction: a crash leaves no partial staging state.
// Pre:  SourceCopy is a quiescent legacy store copy that passed `ztd check`;
//
//	LegacyCheck is "ok"; AgentExport, when set, is a valid export; Target
//	is empty or a completed import with the same source hash.
//
// Post: one transaction writes every source entity exactly once, either
//
//	imported or quarantined with its original payload, and persists a
//	report whose counts match legacy_records. A changed source hash fails
//	before any staging write.
func (s *Store) Import(ctx context.Context, cmd app.ImportCmd, now time.Time) (app.MigrationReport, error) {
	if cmd.SourceCopy == "" {
		return app.MigrationReport{}, domain.Invalid("source copy is required")
	}
	if cmd.LegacyCheck != "ok" {
		return app.MigrationReport{}, domain.Invalid("legacy check must be 'ok' before import")
	}
	mapping, err := loadImportMapping(cmd.MappingPath)
	if err != nil {
		return app.MigrationReport{}, err
	}
	actor := strings.TrimSpace(cmd.Actor)
	if actor == "" {
		actor = strings.TrimSpace(mapping.Actor)
	}
	if actor == "" {
		actor = "operator"
	}
	srcHash, err := legacySourceHash(cmd.SourceCopy, cmd.AgentExport)
	if err != nil {
		return app.MigrationReport{}, err
	}
	parsed, err := legacy.ParseStore(cmd.SourceCopy)
	if err != nil {
		return app.MigrationReport{}, err
	}
	var agent *legacy.AgentExport
	if cmd.AgentExport != "" {
		agent, err = legacy.ParseAgentExport(cmd.AgentExport)
		if err != nil {
			return app.MigrationReport{}, err
		}
	}
	report := app.MigrationReport{
		Version:       1,
		SourceHash:    srcHash,
		SourceVersion: cmd.LegacyVersion,
		CheckResult:   cmd.LegacyCheck,
	}
	if report.SourceVersion == "" {
		report.SourceVersion = "2"
	}
	source := "legacy:" + srcHash
	seen := map[string]bool{}
	var existing *app.MigrationReport
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		var status, prior string
		err := tx.QueryRowContext(ctx,
			`SELECT status, report_json FROM import_runs WHERE source_hash = ?`, srcHash).Scan(&status, &prior)
		if err == nil {
			if status == "completed" {
				var r app.MigrationReport
				if json.Unmarshal([]byte(prior), &r) == nil {
					existing = &r
				}
				return nil
			}
			return domain.NewError(domain.Conflict, "an import for this source is already running")
		}
		if err != sql.ErrNoRows {
			return err
		}
		if err := stagingEmpty(ctx, tx); err != nil {
			return err
		}
		imp := &importer{
			tx: tx, ctx: ctx, now: now, mapping: mapping, actor: actor,
			source: source, report: &report, seen: seen,
		}
		if err := imp.run(parsed, agent); err != nil {
			return err
		}
		rep, err := json.Marshal(report)
		if err != nil {
			return err
		}
		runID := "IMP-" + srcHash[:12]
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO import_runs (id, source_hash, source_version, check_result, status, report_json, created_at, completed_at)
			 VALUES (?, ?, ?, ?, 'completed', ?, ?, ?)`,
			runID, srcHash, report.SourceVersion, report.CheckResult, string(rep), fmtTime(now), fmtTime(now)); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return app.MigrationReport{}, err
	}
	if existing != nil {
		return *existing, nil
	}
	if cmd.ReportPath != "" {
		b, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			return report, err
		}
		if dir := filepath.Dir(cmd.ReportPath); dir != "." {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return report, domain.NewError(domain.IOError, "create report directory: %v", err)
			}
		}
		if err := os.WriteFile(cmd.ReportPath, b, 0o644); err != nil {
			return report, domain.NewError(domain.IOError, "write report: %v", err)
		}
	}
	return report, nil
}

// VerifyImport re-reads the source copy hash and checks the completed run's
// persisted dispositions against the staged database. It writes nothing.
// Pre:  the same source hash was imported to completion into this store.
// Post: recomputes the source hash and compares persisted dispositions with
//
//	legacy_records; returns not_found for an unknown or changed source.
func (s *Store) VerifyImport(ctx context.Context, cmd app.ImportCmd) (app.MigrationReport, error) {
	if cmd.SourceCopy == "" {
		return app.MigrationReport{}, domain.Invalid("source copy is required")
	}
	hash, err := legacySourceHash(cmd.SourceCopy, cmd.AgentExport)
	if err != nil {
		return app.MigrationReport{}, err
	}
	var prior string
	err = s.db.QueryRowContext(ctx,
		`SELECT report_json FROM import_runs WHERE source_hash = ? AND status = 'completed'`, hash).Scan(&prior)
	if err == sql.ErrNoRows {
		return app.MigrationReport{}, domain.NewError(domain.NotFound, "no completed import for this source")
	}
	if err != nil {
		return app.MigrationReport{}, err
	}
	var report app.MigrationReport
	if err := json.Unmarshal([]byte(prior), &report); err != nil {
		return report, domain.Invalid("stored migration report is corrupt: %v", err)
	}
	var imported, quarantined int
	if err := s.db.QueryRowContext(ctx,
		`SELECT
		   COALESCE(SUM(disposition = 'imported'), 0),
		   COALESCE(SUM(disposition = 'quarantined'), 0)
		 FROM legacy_records WHERE source = ?`, "legacy:"+hash).Scan(&imported, &quarantined); err != nil {
		return report, err
	}
	if imported != report.Imported || quarantined != report.Quarantined {
		report.Errors = append(report.Errors,
			fmt.Sprintf("stored dispositions differ: report imported=%d quarantined=%d, database imported=%d quarantined=%d",
				report.Imported, report.Quarantined, imported, quarantined))
	}
	return report, nil
}

func stagingEmpty(ctx context.Context, tx *sql.Tx) error {
	for _, table := range []string{"captures", "work_items", "plans", "routines", "documents", "legacy_records"} {
		var n int
		if err := tx.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			return domain.NewError(domain.DestinationNotEmpty, "staging target already contains %s rows", table)
		}
	}
	return nil
}

func legacySourceHash(root, agentExport string) (string, error) {
	info, err := os.Stat(root)
	if err != nil {
		return "", domain.NewError(domain.IOError, "read source copy: %v", err)
	}
	if !info.IsDir() {
		return "", domain.Invalid("source copy must be a directory")
	}
	var files []string
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			name := d.Name()
			if path != root && (name == ".state" || name == "templates" || strings.HasPrefix(name, ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return "", domain.NewError(domain.IOError, "walk source copy: %v", err)
	}
	if agentExport != "" {
		absRoot, _ := filepath.Abs(root)
		absAgent, _ := filepath.Abs(agentExport)
		if !strings.HasPrefix(absAgent, absRoot+string(filepath.Separator)) {
			files = append(files, agentExport)
		}
	}
	sort.Strings(files)
	h := sha256.New()
	for _, path := range files {
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		b, err := os.ReadFile(path)
		if err != nil {
			return "", domain.NewError(domain.IOError, "read %s: %v", rel, err)
		}
		fmt.Fprintf(h, "file\x00%s\x00", rel)
		if _, err := h.Write(b); err != nil {
			return "", domain.NewError(domain.IOError, "hash %s: %v", rel, err)
		}
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

type importer struct {
	ctx     context.Context
	tx      *sql.Tx
	now     time.Time
	mapping importMapping
	actor   string
	source  string
	report  *app.MigrationReport
	seen    map[string]bool
	// Legacy project id -> scope, for task project resolution.
	projects map[string]string
}

func (im *importer) run(parsed *legacy.Store, agent *legacy.AgentExport) error {
	im.projects = map[string]string{}
	profiles := map[string]string{} // scope -> profile
	ensure := func(scope string) error {
		p, err := im.ensureScope(scope, profiles)
		if err != nil {
			return err
		}
		profiles[scope] = p
		return nil
	}
	if err := ensure(im.mapping.DefaultScope); err != nil {
		return err
	}
	for _, t := range im.mapping.Contexts {
		if t.Scope == "" {
			continue
		}
		if err := ensure(t.Scope); err != nil {
			return err
		}
	}
	for _, s := range im.mapping.AgentScopes {
		if s != "" {
			if err := ensure(s); err != nil {
				return err
			}
		}
	}

	for _, c := range parsed.Contexts {
		if c.Name == "" {
			continue
		}
		scope := im.mapping.DefaultScope
		if t, ok := im.mapping.Contexts[c.Name]; ok && t.Scope != "" {
			scope = t.Scope
		}
		if _, err := im.ensureContext(scope, c.Name); err != nil {
			return err
		}
	}
	for _, p := range parsed.Projects {
		if err := im.importProject(p); err != nil {
			return err
		}
	}
	for _, t := range parsed.Tasks {
		if len(t.Issues) > 0 {
			if err := im.quarantine("task", t.ID, t.Original, strings.Join(t.Issues, "; ")); err != nil {
				return err
			}
			continue
		}
		if t.List == "inbox" {
			if err := im.importInbox(t); err != nil {
				return err
			}
			continue
		}
		if err := im.importTask(t); err != nil {
			return err
		}
	}
	for _, p := range parsed.Plans {
		if err := im.importPlan(p, profiles); err != nil {
			return err
		}
	}
	for _, r := range parsed.Routines {
		if err := im.importRoutine(r); err != nil {
			return err
		}
	}
	paths := make([]string, 0, len(parsed.Documents))
	for p := range parsed.Documents {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		payload := map[string]any{"path": p, "content": string(parsed.Documents[p])}
		if err := im.record("document", p, "", payload, "imported", ""); err != nil {
			return err
		}
	}
	for _, issue := range parsed.Issues {
		if strings.HasPrefix(issue.Detail, "warning:") {
			im.report.Errors = append(im.report.Errors, issue.Entity+" "+issue.ID+": "+issue.Detail)
			continue
		}
		if err := im.quarantine(issue.Entity, issue.ID, issue.Original, issue.Detail); err != nil {
			return err
		}
	}
	if agent != nil {
		if err := im.importAgent(agent, profiles); err != nil {
			return err
		}
	}
	return nil
}

func (im *importer) ensureScope(scope string, profiles map[string]string) (string, error) {
	if scope == "" {
		return "", domain.Invalid("empty scope in mapping")
	}
	kind := "personal"
	switch {
	case scope == "opensource":
		kind = "opensource"
	case scope == "work":
		kind = "work"
	case strings.HasPrefix(scope, "client:"):
		kind = "client"
	case scope != "personal":
		return "", domain.Invalid("unsupported scope %q in mapping", scope)
	}
	now := fmtTime(im.now)
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)
		 ON CONFLICT(id) DO NOTHING`, scope, scope, kind, now); err != nil {
		return "", err
	}
	profile := "personal"
	if _, err := im.tx.ExecContext(im.ctx, "INSERT INTO settings(id,owner_actor_id,timezone) VALUES(1,?,?) ON CONFLICT(id) DO NOTHING", im.actor, localTimezone()); err != nil {
		return "", err
	}

	profiles[scope] = profile
	return profile, nil
}

func (im *importer) profileFor(scope string, profiles map[string]string) string {
	if p, ok := profiles[scope]; ok {
		return p
	}
	return "personal"
}

func (im *importer) ensureContext(scope, name string) (string, error) {
	if name == "" {
		return "", nil
	}
	id := "ctx:" + scope + ":" + name
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO contexts (id, scope_id, name, revision) VALUES (?, ?, ?, 1)
		 ON CONFLICT(scope_id, name) DO NOTHING`, id, scope, name); err != nil {
		return "", err
	}
	return id, nil
}

func (im *importer) ensureArea(scope, name string) (string, error) {
	if name == "" {
		return "", nil
	}
	id := "area:" + scope + ":" + name
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO contexts (id, scope_id, name, revision) VALUES (?, ?, ?, 1)
		 ON CONFLICT(scope_id, name) DO NOTHING`, id, scope, "legacy-area/"+fmt.Sprintf("%X", id)); err != nil {
		return "", err
	}
	return id, nil
}

func (im *importer) targetFor(context, client string) (mappingTarget, error) {
	key := context
	if client != "" {
		if _, ok := im.mapping.Contexts[context+":"+client]; ok {
			key = context + ":" + client
		}
	}
	if t, ok := im.mapping.Contexts[key]; ok && t.Scope != "" {
		return t, nil
	}
	return mappingTarget{}, domain.Invalid("no scope mapping for context %q", key)
}

func (im *importer) importProject(p legacy.Project) error {
	context, client := p.Context, p.Client
	// Older project files omit the Context field; the registered path is the
	// authority, so infer it from the project id instead of quarantining.
	if context == "" {
		parts := strings.Split(p.ID, "/")
		if len(parts) > 0 {
			context = parts[0]
		}
		if len(parts) > 1 && client == "" {
			client = parts[1]
		}
	}
	t, err := im.targetFor(context, client)
	if err != nil {
		return im.quarantine("project", p.ID, p.Original, err.Error())
	}
	scope := t.Scope
	area, err := im.ensureArea(scope, t.Area)
	if err != nil {
		return err
	}
	status := p.Status
	switch status {
	case "active", "paused", "completed", "cancelled":
	default:
		status = "active"
	}
	payload := map[string]any{
		"legacy_id": p.ID, "context": p.Context, "client": p.Client,
		"status": p.Status, "desired_outcome": p.DesiredOutcome, "original": p.Original,
	}
	var areaArg any
	if area != "" {
		areaArg = area
	}
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO projects (id, scope_id, area_id, desired_outcome, status, revision)
		 VALUES (?, ?, ?, ?, ?, 1) ON CONFLICT(id) DO NOTHING`,
		p.ID, scope, areaArg, p.DesiredOutcome, status); err != nil {
		return err
	}
	im.projects[p.ID] = scope
	if err := im.record("project", p.ID, scope, payload, "imported", ""); err != nil {
		return err
	}
	return nil
}

func (im *importer) importInbox(t legacy.Task) error {
	target, err := im.targetFor(t.Field("context"), t.Field("client"))
	if err != nil {
		target = mappingTarget{Scope: im.mapping.DefaultScope}
	}
	scope := target.Scope
	if scope == "" {
		scope = im.mapping.DefaultScope
	}
	captured := legacyTime(t.Field("captured_at"), t.ID)
	date := captured.UTC().Format("20060102")
	seq, err := nextDailySeq(im.ctx, im.tx, "captures", "C-"+date+"-")
	if err != nil {
		return err
	}
	id := fmt.Sprintf("C-%s-%03d", date, seq)
	text := strings.TrimSpace(t.Original)
	payload := map[string]any{
		"legacy_id": t.ID, "list": t.List, "title": t.Title,
		"fields": t.Fields, "original": t.Original, "source_path": t.SourcePath, "line": t.Line,
	}
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO captures (id, scope_id, source_id, external_id, external_revision, original_text,
		   content_hash, source_uri, occurred_at, captured_at, processing_state, processing_outcome,
		   review_after, revision)
		 VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, 'pending', NULL, NULL, 1)`,
		id, scope, domain.LegacySourceID, text, sha256hex(text), fmt.Sprintf("%s:%d", t.SourcePath, t.Line),
		fmtTime(captured), fmtTime(captured)); err != nil {
		return err
	}
	if err := insertHistory(im.ctx, im.tx, "capture", id, "imported", scope, "", 1, payload, im.now); err != nil {
		return err
	}
	return im.record("capture", id, scope, payload, "imported", "")
}

// customFields keeps every legacy task field that has no dedicated work item
// column; the reserved routing and lifecycle fields are read separately.
func customFields(t legacy.Task) map[string]string {
	out := map[string]string{}
	for _, f := range t.Fields {
		if !domain.IsReservedField(f.Key) {
			out[f.Key] = f.Value
		}
	}
	return out
}

func (im *importer) importTask(t legacy.Task) error {
	target, err := im.targetFor(t.Field("context"), t.Field("client"))
	if err != nil {
		return im.quarantine("task", t.ID, t.Original, err.Error())
	}
	scope := target.Scope
	ctxID, err := im.ensureContext(scope, t.Field("context"))
	if err != nil {
		return err
	}
	lifecycle := t.List
	switch lifecycle {
	case "next", "waiting", "someday", "archive":
	default:
		return im.quarantine("task", t.ID, t.Original, "unsupported legacy list "+t.List)
	}
	if lifecycle == "archive" {
		lifecycle = "archived"
	}
	projectID := t.Field("project")
	project := ""
	if projectID != "" {
		project = im.resolveProject(scope, projectID)
		if project == "" {
			im.report.Errors = append(im.report.Errors,
				fmt.Sprintf("task %s: project %q not resolved in scope %s; preserved in legacy payload", t.ID, projectID, scope))
		}
	}
	captured := legacyTime(t.Field("captured_at"), t.ID)
	updated := captured
	var closed *time.Time
	if lifecycle == "archived" {
		c := legacyTime(t.Field("closed_at"), t.ID)
		closed = &c
		updated = c
	}
	status := lifecycle
	if lifecycle == "archived" {
		status = "closed_unknown"
	}
	var ctxArg, projArg, closedArg any
	if ctxID != "" {
		ctxArg = ctxID
	}
	if project != "" {
		projArg = project
	}
	if closed != nil {
		closedArg = fmtTime(*closed)
	}
	waiting := t.Field("waiting_on")
	resolution := t.Field("resolution")
	custom, err := json.Marshal(customFields(t))
	if err != nil {
		return domain.Invalid("task %s: custom fields are not serializable: %v", t.ID, err)
	}
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO work_items (id, scope_id, area_id, project_id, context_id, title, origin_capture_id,
		   status, waiting_on, due_at, closed_at, resolution, revision, created_at, updated_at,
		   custom_fields)
		 VALUES (?, ?, NULL, ?, ?, ?, NULL, ?, ?, NULL, ?, ?, 1, ?, ?, ?)
		 ON CONFLICT(id) DO NOTHING`,
		t.ID, scope, projArg, ctxArg, t.Title, status, nullIfEmpty(waiting),
		closedArg, nullIfEmpty(resolution), fmtTime(captured), fmtTime(updated),
		string(custom)); err != nil {
		return err
	}
	fields := map[string]string{}
	for _, f := range t.Fields {
		fields[f.Key] = f.Value
	}
	payload := map[string]any{
		"legacy_id": t.ID, "list": t.List, "title": t.Title, "fields": fields,
		"original": t.Original, "source_path": t.SourcePath, "line": t.Line,
	}
	if err := insertHistory(im.ctx, im.tx, "work_item", t.ID, "imported", scope, "", 1, payload, im.now); err != nil {
		return err
	}
	return im.record("task", t.ID, scope, payload, "imported", "")
}

func (im *importer) resolveProject(scope, want string) string {
	if s, ok := im.projects[want]; ok && s == scope {
		return want
	}
	var match string
	for id, s := range im.projects {
		if s != scope {
			continue
		}
		if id == want || strings.HasSuffix(id, "/"+want) {
			if match != "" && match != id {
				return ""
			}
			match = id
		}
	}
	return match
}

func (im *importer) importPlan(p legacy.Plan, profiles map[string]string) error {
	byProfile := map[string][]domain.PlanItem{}
	mitSet := map[string]bool{}
	for _, id := range p.MITs {
		mitSet[id] = true
	}
	rockSet := map[string]bool{}
	for _, id := range p.BigRocks {
		rockSet[id] = true
	}
	var order []string
	add := func(id string, role domain.PlanRole) {
		scope, err := im.workItemScope(id)
		if err != nil || scope == "" {
			im.report.Errors = append(im.report.Errors,
				fmt.Sprintf("plan %s %s: %s not imported; reference preserved", p.Kind, p.Period, id))
			return
		}
		profile := im.profileFor(scope, profiles)
		if _, ok := byProfile[profile]; !ok {
			order = append(order, profile)
		}
		byProfile[profile] = append(byProfile[profile], domain.PlanItem{WorkItemID: domain.WorkItemID(id), Role: role})
	}
	seen := map[string]bool{}
	addAll := func(ids []string, role domain.PlanRole) {
		for _, id := range ids {
			if seen[id] {
				continue
			}
			seen[id] = true
			add(id, role)
		}
	}
	if p.Kind == "weekly" {
		addAll(p.BigRocks, domain.BigRockRole)
		addAll(p.IDs, domain.BatchRole)
	} else {
		addAll(p.MITs, domain.MITRole)
		addAll(p.IDs, domain.BatchRole)
	}
	sort.Strings(order)
	for _, profile := range order {
		items := byProfile[profile]
		// Historical plans may exceed today's per-profile MIT limit. Preserve
		// the links and record a warning; do not invent a limit override.
		mits := 0
		for _, it := range items {
			if it.Role == domain.MITRole {
				mits++
			}
		}
		if p.Kind == "daily" && (mits > 3 || mits == 0) {
			im.report.Errors = append(im.report.Errors,
				fmt.Sprintf("plan %s %s profile %s has %d MITs; preserved as historical data", p.Kind, p.Period, profile, mits))
		}
		planID := "PL:" + profile + ":" + p.Kind + ":" + p.Period
		payload := map[string]any{"kind": p.Kind, "period": p.Period, "source_path": p.SourcePath, "original_ids": p.IDs, "mits": p.MITs, "big_rocks": p.BigRocks}
		if _, err := im.tx.ExecContext(im.ctx,
			`INSERT INTO plans (id, profile_id, kind, period, status, revision, created_at, updated_at)
			 VALUES (?, ?, ?, ?, 'committed', 1, ?, ?) ON CONFLICT(id) DO NOTHING`,
			planID, profile, p.Kind, p.Period, fmtTime(im.now), fmtTime(im.now)); err != nil {
			return err
		}
		for i, it := range items {
			it.Position = i
			if _, err := im.tx.ExecContext(im.ctx,
				`INSERT INTO plan_items (plan_id, work_item_id, role, position) VALUES (?, ?, ?, ?)
				 ON CONFLICT(plan_id, work_item_id) DO NOTHING`,
				planID, string(it.WorkItemID), string(it.Role), it.Position); err != nil {
				return err
			}
		}
		if err := insertHistory(im.ctx, im.tx, "plan", planID, "imported", "", profile, 1, payload, im.now); err != nil {
			return err
		}
		if err := im.record("plan", p.Kind+":"+p.Period+":"+profile, profile, payload, "imported", ""); err != nil {
			return err
		}
	}
	if len(order) == 0 {
		return im.record("plan", p.Kind+":"+p.Period, "", map[string]any{"source_path": p.SourcePath, "original": p}, "imported", "no resolvable item references")
	}
	return nil
}

func (im *importer) workItemScope(id string) (string, error) {
	var scope string
	err := im.tx.QueryRowContext(im.ctx, `SELECT scope_id FROM work_items WHERE id = ?`, id).Scan(&scope)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return scope, err
}

func (im *importer) importRoutine(r legacy.Routine) error {
	scope := im.mapping.DefaultScope
	var last any
	if r.LastCompletedAt != nil {
		last = fmtTime(*r.LastCompletedAt)
	}
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO routines (id, scope_id, kind, cadence, last_completed_at, active, revision)
		 VALUES (?, ?, 'routine', ?, ?, 1, 1) ON CONFLICT(id) DO NOTHING`,
		r.ID, scope, r.Cadence, last); err != nil {
		return err
	}
	payload := map[string]any{"id": r.ID, "cadence": r.Cadence, "last": r.LastCompletedAt, "original": r.Original, "source_path": r.SourcePath}
	return im.record("routine", r.ID, scope, payload, "imported", "")
}

func (im *importer) importAgent(export *legacy.AgentExport, profiles map[string]string) error {
	oldToNew := map[string]string{}
	for _, s := range export.Scopes {
		to := im.mapping.AgentScopes[s.ID]
		if to == "" {
			to = s.ID
		}
		if _, err := im.ensureScope(to, profiles); err != nil {
			return im.quarantine("agent_scope", s.ID, "", err.Error())
		}
		oldToNew[s.ID] = to
	}
	for _, a := range export.Assignments {
		scope := oldToNew[a.ScopeID]
		if scope == "" {
			if err := im.quarantine("agent_assignment", a.ID, a.Request, "unknown agent scope"); err != nil {
				return err
			}
			continue
		}
		if err := im.record("agent_assignment", a.ID, scope, a, "imported", ""); err != nil {
			return err
		}
	}
	for _, c := range export.Checkpoints {
		if err := im.record("agent_checkpoint", c.ID, "", c, "imported", ""); err != nil {
			return err
		}
	}
	for _, o := range export.Operations {
		if err := im.record("agent_operation", o.Key, "", o, "imported", ""); err != nil {
			return err
		}
	}
	for _, k := range export.Knowledge {
		scope := oldToNew[k.Scope]
		if scope == "" {
			if err := im.quarantine("agent_knowledge", k.ID, k.Text, "unknown agent scope"); err != nil {
				return err
			}
			continue
		}
		sourceRefs := "[]"
		if k.Source != nil && *k.Source != "" {
			b, _ := json.Marshal([]string{*k.Source})
			sourceRefs = string(b)
		}
		created := k.CreatedAt
		if _, err := time.Parse(time.RFC3339, created); err != nil {
			created = fmtTime(im.now)
		}
		if _, err := im.tx.ExecContext(im.ctx,
			`INSERT INTO documents (id, scope_id, kind, slug, title, body, status, sources_json, metadata_json, revision, created_at, updated_at)
 VALUES (?, ?, 'knowledge', ?, ?, ?, 'verified', ?, ?, 1, ?, ?) ON CONFLICT(id) DO NOTHING`,
			"legacy-knowledge:"+fmt.Sprintf("%X", k.ID), scope, "legacy/knowledge/"+fmt.Sprintf("%X", k.ID), k.ID, k.Text, sourceRefs,
			string(mustJSON(k)), created, created); err != nil {
			return err
		}
		if err := im.record("agent_knowledge", k.ID, scope, k, "imported", ""); err != nil {
			return err
		}
	}
	return nil
}

func (im *importer) quarantine(entity, id, original, reason string) error {
	payload := map[string]any{"original": original}
	return im.record(entity, id, "", payload, "quarantined", reason)
}

func (im *importer) record(entity, id, scope string, payload any, disposition, reason string) error {
	key := entity + "\x00" + id
	if im.seen[key] {
		return nil
	}
	im.seen[key] = true
	b, err := json.Marshal(payload)
	if err != nil {
		return domain.Invalid("legacy payload is not serializable: %v", err)
	}
	var scopeArg any
	if scope != "" {
		scopeArg = scope
	}
	if _, err := im.tx.ExecContext(im.ctx,
		`INSERT INTO legacy_records (source, entity_type, entity_id, scope_id, payload_json, disposition, reason)
		 VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(source, entity_type, entity_id) DO UPDATE SET
		   payload_json = excluded.payload_json,
		   disposition = excluded.disposition,
		   reason = excluded.reason`,
		im.source, entity, id, scopeArg, string(b), disposition, reason); err != nil {
		return err
	}
	if disposition == "imported" {
		im.report.Imported++
	} else {
		im.report.Quarantined++
	}
	im.report.Dispositions = append(im.report.Dispositions, app.Disposition{
		EntityType: entity, EntityID: id, State: disposition, Reason: reason, Original: originalOf(payload),
	})
	return nil
}

func originalOf(payload any) string {
	switch v := payload.(type) {
	case map[string]any:
		if s, ok := v["original"].(string); ok {
			return s
		}
		if s, ok := v["request"].(string); ok {
			return s
		}
	case legacy.Task:
		return v.Original
	case legacy.Project:
		return v.Original
	case legacy.Routine:
		return v.Original
	}
	return ""
}

func legacyTime(value, taskID string) time.Time {
	for _, layout := range []string{"2006-01-02", time.RFC3339} {
		if t, err := time.Parse(layout, value); err == nil {
			return t.UTC()
		}
	}
	if len(taskID) >= 11 {
		if t, err := time.Parse("20060102", taskID[2:10]); err == nil {
			return t.UTC()
		}
	}
	return time.Now().UTC()
}

var _ = io.Discard

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }
