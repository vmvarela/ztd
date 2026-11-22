package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"ztd/internal/app"
	"ztd/internal/domain"
)

// documentMapping overrides context→scope resolution for the documents
// import. It is the same JSON shape as the migrate import mapping, reduced to
// the fields the document rules use; without a file the built-in rules and
// default_scope=personal apply.
type documentMapping struct {
	DefaultScope string                   `json:"default_scope"`
	Contexts     map[string]mappingTarget `json:"contexts"`
}

func loadDocumentMapping(path string) (documentMapping, error) {
	m := documentMapping{DefaultScope: "personal"}
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
	return m, nil
}

// builtInDocumentScopes is the built-in document rule table: the context keys
// the store itself claims before falling back to default_scope.
var builtInDocumentScopes = map[string]string{
	"opensource":  "opensource",
	"trabajo":     "client:prisamedia",
	"familia":     "personal",
	"propiedades": "personal",
	"salud":       "salud",
}

// resolveDocumentScope applies the resolution order: the --mapping context
// map first, then the built-in rules, then default_scope (personal unless a
// mapping says otherwise).
func resolveDocumentScope(contextKey string, m documentMapping) string {
	if contextKey != "" {
		if t, ok := m.Contexts[contextKey]; ok && t.Scope != "" {
			return t.Scope
		}
		if s, ok := builtInDocumentScopes[contextKey]; ok {
			return s
		}
	}
	return m.DefaultScope
}

// silentDocumentPath reports paths that are part of the store but never a
// document: the same exclusions the legacy parser applies before it copies
// document bytes, plus the store's own README.
func silentDocumentPath(rel string) bool {
	switch rel {
	case "README.md", "config.json", "contexts.md", "inbox.md",
		"lists/next.md", "lists/waiting.md", "lists/someday.md", "lists/archive.md",
		"routines/state.md", ".ztd-assets.json":
		return true
	}
	return strings.HasPrefix(rel, "ztd.db")
}

// documentClass is one classified legacy file: where it lands in the document
// layer and which context key its scope resolves from (empty when the path
// carries no context segment).
type documentClass struct {
	kind    domain.DocumentKind
	slug    string
	context string
}

// classifyDocument maps a store-relative .md path to its document kind, slug
// and context key. A non-empty warning means the file is skipped: an
// ambiguous path is reported instead of given an invented kind.
func classifyDocument(rel string) (documentClass, string) {
	trimmed := strings.TrimSuffix(rel, ".md")
	switch trimmed {
	case "calendar":
		return documentClass{kind: domain.DocumentCalendar, slug: "calendar"}, ""
	case "adoption":
		return documentClass{kind: domain.DocumentAdoption, slug: "adoption"}, ""
	case "passion":
		return documentClass{kind: domain.DocumentPassion, slug: "passion"}, ""
	case "routines/daily":
		return documentClass{kind: domain.DocumentRoutine, slug: "daily"}, ""
	case "routines/weekly":
		return documentClass{kind: domain.DocumentRoutine, slug: "weekly"}, ""
	case "goals/active":
		return documentClass{kind: domain.DocumentKnowledge, slug: "goals/active"}, ""
	case "goals/archive":
		return documentClass{kind: domain.DocumentKnowledge, slug: "goals/archive"}, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "knowledge/"); ok {
		class := documentClass{kind: domain.DocumentKnowledge, slug: rest}
		if path.Base(rest) == "index" {
			class.kind = domain.DocumentKnowledgeIndex
		}
		if i := strings.Index(rest, "/"); i > 0 {
			class.context = rest[:i]
		}
		return class, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "reading/"); ok {
		// Reading is personal by rule: the path segment after reading/ is a
		// note name, never a context key.
		return documentClass{kind: domain.DocumentKnowledge, slug: "reading/" + rest}, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "lists/projects/"); ok {
		if rest == "" || strings.HasSuffix(rest, "/") {
			return documentClass{}, "empty project note path"
		}
		class := documentClass{kind: domain.DocumentProjectNote, slug: rest}
		if i := strings.Index(rest, "/"); i > 0 {
			class.context = rest[:i]
		}
		return class, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "reviews/"); ok {
		class := documentClass{kind: domain.DocumentReview, slug: rest}
		if i := strings.Index(rest, "/"); i > 0 {
			class.context = rest[:i]
		}
		return class, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "plans/daily/"); ok {
		if !isDateSlug(rest) {
			return documentClass{}, "daily plan must be plans/daily/YYYY-MM-DD.md"
		}
		return documentClass{kind: domain.DocumentPlanDaily, slug: rest}, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "plans/weekly/"); ok {
		if strings.Contains(rest, "/") {
			return documentClass{}, "weekly plan must be a direct child of plans/weekly"
		}
		return documentClass{kind: domain.DocumentPlanWeekly, slug: rest}, ""
	}
	if rest, ok := strings.CutPrefix(trimmed, "journal/"); ok {
		if !isDateSlug(rest) {
			return documentClass{}, "journal must be journal/YYYY-MM-DD.md"
		}
		return documentClass{kind: domain.DocumentJournal, slug: rest}, ""
	}
	return documentClass{}, "no document kind for this path"
}

// isDateSlug reports whether s is exactly YYYY-MM-DD.
func isDateSlug(s string) bool {
	_, err := time.Parse("2006-01-02", s)
	return err == nil
}

// documentTitle uses the first Markdown `# ` heading of the body, trimmed; a
// body without one falls back to the slug.
func documentTitle(body, slug string) string {
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		if !strings.HasPrefix(line, "# ") {
			continue
		}
		if title := strings.TrimSpace(strings.TrimPrefix(line, "# ")); title != "" {
			return title
		}
	}
	return slug
}

// projectRepository reads the first data row of the `## Repositories` (or
// legacy `## Repositorios`) table of a project card and returns its remote
// URL and local path cells. warn is set when the heading exists but holds no
// usable table row; both cells are empty when the card has no such heading.
func projectRepository(body string) (repoURL, clonePath, warn string) {
	inSection, headerSkipped := false, false
	for _, raw := range strings.Split(body, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if !inSection {
			switch strings.ToLower(strings.TrimSpace(strings.TrimLeft(line, "#"))) {
			case "repositories", "repositorios":
				inSection = strings.HasPrefix(line, "#")
			}
			continue
		}
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "|") {
			break // any other content (heading, paragraph) ends the section
		}
		cells := tableCells(line)
		if isTableSeparator(cells) {
			continue
		}
		if !headerSkipped {
			headerSkipped = true
			continue
		}
		if len(cells) < 3 {
			return "", "", "repository table row needs at least 3 columns"
		}
		return cells[1], cells[2], ""
	}
	if inSection {
		return "", "", "no usable repository table under the Repositories heading"
	}
	return "", "", ""
}

func tableCells(line string) []string {
	line = strings.TrimPrefix(strings.TrimSpace(line), "|")
	line = strings.TrimSuffix(line, "|")
	parts := strings.Split(line, "|")
	cells := make([]string, len(parts))
	for i, p := range parts {
		cells[i] = strings.TrimSpace(p)
	}
	return cells
}

// isTableSeparator reports whether every cell is a Markdown table separator
// such as `---` or `:---:`.
func isTableSeparator(cells []string) bool {
	if len(cells) == 0 {
		return false
	}
	for _, c := range cells {
		c = strings.Trim(c, ":")
		if c == "" || strings.Trim(c, "-") != "" {
			return false
		}
	}
	return true
}

// resolveClonePath turns the local path cell of a project card into the
// absolute clone path the store requires: a relative path resolves against
// the workspace, and a ".." segment or a non-absolute result is refused with
// a warning instead of guessed.
func resolveClonePath(raw, workspace string) (string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", ""
	}
	for _, seg := range strings.Split(filepath.ToSlash(raw), "/") {
		if seg == ".." {
			return "", fmt.Sprintf("clone path %q contains a .. segment; not imported", raw)
		}
	}
	p := raw
	// A path absolute on POSIX or Windows is kept as recorded; only a
	// relative one resolves against the workspace.
	if !app.ValidClonePath(p) {
		p = filepath.Join(workspace, p)
	}
	if !app.ValidClonePath(p) {
		return "", fmt.Sprintf("clone path %q does not resolve to an absolute path; not imported", raw)
	}
	return p, ""
}

// plannedDocument is one file that will become a document row.
type plannedDocument struct {
	rel   string
	class documentClass
	scope string
	title string
	body  string
	// Repository cells extracted from a project card; both empty when the
	// card has no Repositories table.
	repoURL   string
	clonePath string
}

type documentPlan struct {
	docs     []plannedDocument
	warnings []string
	skipped  int
}

// planDocuments walks the source copy read-only and classifies every
// candidate file. Files outside the document rules, invalid UTF-8, empty
// bodies, invalid slugs and unusable scopes are counted as skipped with a
// warning; store bookkeeping files are skipped silently.
func planDocuments(source, workspace string, mapping documentMapping) (documentPlan, error) {
	var plan documentPlan
	err := filepath.WalkDir(source, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			rel, _ := filepath.Rel(source, p)
			plan.skipped++
			plan.warnings = append(plan.warnings, filepath.ToSlash(rel)+": unreadable: "+err.Error())
			return nil
		}
		rel, relErr := filepath.Rel(source, p)
		if relErr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if rel == "." {
			return nil
		}
		if d.IsDir() {
			name := d.Name()
			// Tooling state is never a document: hidden directories at any
			// depth and the top-level templates/ subtree.
			if strings.HasPrefix(name, ".") {
				return fs.SkipDir
			}
			if name == "templates" && !strings.Contains(rel, "/") {
				return fs.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() || !strings.HasSuffix(rel, ".md") || silentDocumentPath(rel) {
			return nil
		}
		class, warn := classifyDocument(rel)
		if warn != "" {
			plan.skipped++
			plan.warnings = append(plan.warnings, rel+": "+warn)
			return nil
		}
		if !app.ValidDocumentSlug(class.slug) {
			plan.skipped++
			plan.warnings = append(plan.warnings,
				rel+": slug "+fmt.Sprintf("%q", class.slug)+" is not a valid document slug")
			return nil
		}
		b, readErr := os.ReadFile(p)
		if readErr != nil {
			plan.skipped++
			plan.warnings = append(plan.warnings, rel+": unreadable: "+readErr.Error())
			return nil
		}
		if !utf8.Valid(b) {
			plan.skipped++
			plan.warnings = append(plan.warnings, rel+": invalid UTF-8; not imported")
			return nil
		}
		if len(b) == 0 {
			plan.skipped++
			plan.warnings = append(plan.warnings, rel+": empty file; not imported")
			return nil
		}
		scope := resolveDocumentScope(class.context, mapping)
		if !app.ValidConfigID(scope) {
			plan.skipped++
			plan.warnings = append(plan.warnings,
				rel+": scope "+fmt.Sprintf("%q", scope)+" is not a valid scope id; not imported")
			return nil
		}
		doc := plannedDocument{rel: rel, class: class, scope: scope, body: string(b)}
		doc.title = documentTitle(doc.body, class.slug)
		if class.kind == domain.DocumentProjectNote {
			repoURL, clonePath, repoWarn := projectRepository(doc.body)
			if repoWarn != "" {
				plan.warnings = append(plan.warnings, rel+": "+repoWarn)
			}
			if repoURL != "" && !app.ValidRepoURL(repoURL) {
				plan.warnings = append(plan.warnings,
					rel+": repository url "+fmt.Sprintf("%q", repoURL)+" is not usable; not imported")
				repoURL = ""
			}
			if clonePath != "" {
				resolved, pathWarn := resolveClonePath(clonePath, workspace)
				if pathWarn != "" {
					plan.warnings = append(plan.warnings, rel+": "+pathWarn)
				}
				clonePath = resolved
			}
			doc.repoURL, doc.clonePath = repoURL, clonePath
		}
		plan.docs = append(plan.docs, doc)
		return nil
	})
	if err != nil {
		return plan, domain.NewError(domain.IOError, "walk source copy: %v", err)
	}
	return plan, nil
}

// ensureDocumentScope declares a scope the documents land in, so `check`
// never sees a document referencing a missing scope. An existing scope keeps
// its own name and kind.
func ensureDocumentScope(ctx context.Context, tx *sql.Tx, scope string, now time.Time) error {
	kind := "personal"
	switch {
	case scope == "opensource":
		kind = "opensource"
	case scope == "work":
		kind = "work"
	case strings.HasPrefix(scope, "client:"):
		kind = "client"
	}
	_, err := tx.ExecContext(ctx,
		`INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)
		 ON CONFLICT(id) DO NOTHING`, scope, scope, kind, fmtTime(now))
	return err
}

// ImportDocuments reads a verified, quiescent copy of the legacy Markdown
// store and populates the document layer: every classified file becomes one
// document at status verified, and each imported project note contributes its
// repository URL and clone path to the matching project.
//
// Pre:  cmd.Source is a quiescent legacy store copy with no pending journal;
//
//	the caller never points it at ~/.ztd directly. cmd.MappingPath, when
//	set, is valid JSON in the migrate import shape. cmd.Workspace, when
//	set, is an existing directory.
//
// Post: one transaction writes every insert and update with one history event
//
//	each, fills only empty project repository fields and compares existing
//	(scope, kind, slug) documents directly, so a re-run of the same copy
//	counts every file as unchanged and writes nothing. DryRun performs the
//	same reads and writes nothing at all. Ambiguous files are counted as
//	skipped with a warning instead of being invented.
func (s *Store) ImportDocuments(ctx context.Context, cmd app.ImportDocumentsCmd, now time.Time) (app.DocumentsImportReport, error) {
	now = now.UTC().Truncate(time.Second)
	report := app.DocumentsImportReport{}
	if strings.TrimSpace(cmd.Source) == "" {
		return report, domain.Invalid("source copy is required")
	}
	info, err := os.Stat(cmd.Source)
	if err != nil {
		return report, domain.NewError(domain.IOError, "read source copy: %v", err)
	}
	if !info.IsDir() {
		return report, domain.Invalid("source copy must be a directory")
	}
	// Same precondition as migrate import: a pending legacy journal means the
	// copy is mid-transaction and recovery belongs to the legacy tool.
	pending := filepath.Join(cmd.Source, ".state", "pending.json")
	if _, err := os.Lstat(pending); err == nil {
		return report, domain.NewError(domain.PendingTransaction, "pending transaction: %s", pending)
	} else if !errors.Is(err, os.ErrNotExist) {
		return report, domain.NewError(domain.IOError, "cannot inspect %s: %v", pending, err)
	}
	mapping, err := loadDocumentMapping(cmd.MappingPath)
	if err != nil {
		return report, err
	}
	workspace := cmd.Workspace
	if workspace == "" {
		workspace = "."
	}
	if workspace, err = filepath.Abs(workspace); err != nil {
		return report, domain.NewError(domain.IOError, "resolve workspace: %v", err)
	}
	wsInfo, err := os.Stat(workspace)
	if err != nil {
		return report, domain.NewError(domain.IOError, "read workspace: %v", err)
	}
	if !wsInfo.IsDir() {
		return report, domain.Invalid("workspace must be a directory")
	}

	plan, err := planDocuments(cmd.Source, workspace, mapping)
	if err != nil {
		return report, err
	}
	report.Skipped = plan.skipped
	report.Warnings = append(report.Warnings, plan.warnings...)

	scopeSet := map[string]bool{}
	for _, d := range plan.docs {
		scopeSet[d.scope] = true
	}
	scopes := make([]string, 0, len(scopeSet))
	for sc := range scopeSet {
		scopes = append(scopes, sc)
	}
	sort.Strings(scopes)

	err = s.withTx(ctx, func(tx *sql.Tx) error {
		if !cmd.DryRun {
			for _, sc := range scopes {
				if err := ensureDocumentScope(ctx, tx, sc, now); err != nil {
					return err
				}
			}
		}
		for _, d := range plan.docs {
			existing, err := scanDocument(tx.QueryRowContext(ctx,
				"SELECT "+documentColumns+" FROM documents WHERE scope_id = ? AND kind = ? AND slug = ?",
				d.scope, string(d.class.kind), d.class.slug))
			switch {
			case errors.Is(err, sql.ErrNoRows):
				report.Inserted++
				if !cmd.DryRun {
					doc := domain.Document{
						ID:        fmt.Sprintf("doc:%s:%s:%s", d.scope, d.class.kind, d.class.slug),
						Scope:     d.scope,
						Kind:      string(d.class.kind),
						Slug:      d.class.slug,
						Title:     d.title,
						Body:      d.body,
						Status:    domain.DocumentVerified,
						Revision:  1,
						CreatedAt: now,
						UpdatedAt: now,
					}
					if _, err := tx.ExecContext(ctx,
						`INSERT INTO documents (id, scope_id, kind, slug, title, body, status,
							revision, created_at, updated_at)
						     VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
						doc.ID, d.scope, string(d.class.kind), d.class.slug, doc.Title, doc.Body,
						string(doc.Status), fmtTime(now), fmtTime(now)); err != nil {
						return err
					}
					if err := insertHistory(ctx, tx, "document", doc.ID, "created",
						d.scope, "", 1, doc, now); err != nil {
						return err
					}
				}
			case err != nil:
				return err
			case existing.Body == d.body && existing.Title == d.title &&
				existing.Status == domain.DocumentVerified:
				report.Unchanged++
			default:
				report.Updated++
				if !cmd.DryRun {
					next := existing
					next.Title, next.Body, next.Status = d.title, d.body, domain.DocumentVerified
					next.Revision = existing.Revision.Next()
					next.UpdatedAt = now
					if _, err := tx.ExecContext(ctx,
						`UPDATE documents SET title = ?, body = ?, status = ?, revision = ?, updated_at = ?
						     WHERE id = ? AND scope_id = ? AND kind = ? AND slug = ?`,
						next.Title, next.Body, string(next.Status), int64(next.Revision), fmtTime(next.UpdatedAt),
						next.ID, d.scope, string(d.class.kind), d.class.slug); err != nil {
						return err
					}
					if err := insertHistory(ctx, tx, "document", next.ID, "updated",
						d.scope, "", next.Revision, next, now); err != nil {
						return err
					}
				}
			}
			if d.class.kind == domain.DocumentProjectNote && (d.repoURL != "" || d.clonePath != "") {
				if err := importProjectRepo(ctx, tx, d, cmd.DryRun, now, &report); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return app.DocumentsImportReport{}, err
	}
	return report, nil
}

// importProjectRepo fills the empty repository fields of the project a
// project note points at. One bad project is a warning, never a failed
// import: an unknown project or a value that differs from the stored one is
// reported and the stored row wins.
func importProjectRepo(ctx context.Context, tx *sql.Tx, d plannedDocument, dryRun bool, now time.Time, report *app.DocumentsImportReport) error {
	proj, _, err := setProjectRepoTx(ctx, tx, domain.ProjectID(d.class.slug),
		d.repoURL, d.clonePath, !dryRun, now)
	if domain.Of(err, domain.NotFound) {
		report.Warnings = append(report.Warnings,
			d.rel+": project "+d.class.slug+" not found; repository fields not imported")
		return nil
	}
	if err != nil {
		return err
	}
	if d.repoURL != "" && proj.RepoURL != d.repoURL {
		report.Warnings = append(report.Warnings,
			d.rel+": project "+d.class.slug+" already has repo_url "+proj.RepoURL+"; keeping it")
	}
	if d.clonePath != "" && proj.ClonePath != d.clonePath {
		report.Warnings = append(report.Warnings,
			d.rel+": project "+d.class.slug+" already has clone_path "+proj.ClonePath+"; keeping it")
	}
	return nil
}
