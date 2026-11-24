package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const contextColumns = `id, scope_id, name, revision`
const documentColumns = `id, scope_id, kind, slug, title, body, status, revision,
	created_at, updated_at, sources_json, project_id`

func scanContext(sc scanner) (domain.Context, error) {
	var (
		c     domain.Context
		scope string
	)
	if err := sc.Scan(&c.ID, &scope, &c.Name, &c.Revision); err != nil {
		return domain.Context{}, err
	}
	c.Scope = domain.ScopeID(scope)
	return c, nil
}

func scanDocument(sc scanner) (domain.Document, error) {
	var (
		d                         domain.Document
		scope, kind, status       string
		created, updated, sources string
		project                   sql.NullString
	)
	if err := sc.Scan(&d.ID, &scope, &kind, &d.Slug, &d.Title, &d.Body,
		&status, &d.Revision, &created, &updated, &sources, &project); err != nil {
		return domain.Document{}, err
	}
	if err := json.Unmarshal([]byte(sources), &d.Sources); err != nil {
		return domain.Document{}, err
	}
	d.ProjectID = ptrID[domain.ProjectID](project)
	d.Scope = scope
	d.Kind = kind
	d.Status = domain.DocumentStatus(status)
	var err error
	if d.CreatedAt, err = parseTime("documents.created_at", created); err != nil {
		return domain.Document{}, err
	}
	if d.UpdatedAt, err = parseTime("documents.updated_at", updated); err != nil {
		return domain.Document{}, err
	}
	return d, nil
}

// requireScopeDeclared fails with invalid_input when the scope is not
// declared, so a hand-built binding cannot surface a raw foreign key error.
func requireScopeDeclared(ctx context.Context, tx *sql.Tx, scope domain.ScopeID) error {
	var one int
	switch err := tx.QueryRowContext(ctx, "SELECT 1 FROM scopes WHERE id = ?", string(scope)).Scan(&one); {
	case errors.Is(err, sql.ErrNoRows):
		return domain.Invalid("unknown scope reference %s", scope)
	case err != nil:
		return err
	}
	return nil
}

// AddContext declares one context name in the binding's primary scope.
//
// Pre: the binding validates and the name is non-blank; the primary scope is
// declared. Post: one transaction — an existing context with the same name in
// that scope is returned untouched without writes, a new one is inserted with
// revision 1 plus its "created" history event. Nothing is written on failure.
func (s *Store) AddContext(ctx context.Context, cmd app.ContextCmd) (domain.Context, error) {
	if err := app.ValidateContextCmd(cmd); err != nil {
		return domain.Context{}, err
	}
	scope := cmd.Binding.Scopes[0]
	now := domain.NowUTC()
	var out domain.Context
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		if err := requireScopeDeclared(ctx, tx, scope); err != nil {
			return err
		}
		existing, err := scanContext(tx.QueryRowContext(ctx,
			"SELECT "+contextColumns+" FROM contexts WHERE scope_id = ? AND name = ?",
			string(scope), cmd.Name))
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return err
		default:
			out = existing
			return nil
		}
		out = domain.Context{
			ID:       domain.ContextID("ctx:" + string(scope) + ":" + cmd.Name),
			Scope:    scope,
			Name:     cmd.Name,
			Revision: 1,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO contexts (id, scope_id, name, revision) VALUES (?, ?, ?, 1)`,
			string(out.ID), string(scope), cmd.Name); err != nil {
			return err
		}
		return insertHistory(ctx, tx, "context", string(out.ID), "created",
			string(scope), "", 1, out, now)
	})
	if err != nil {
		return domain.Context{}, err
	}
	return out, nil
}

// ListContexts returns the contexts of the binding scopes ordered by name.
func (s *Store) ListContexts(ctx context.Context, b domain.ScopeBinding) ([]domain.Context, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+contextColumns+" FROM contexts WHERE scope_id IN ("+clause+") ORDER BY name", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Context{}
	for rows.Next() {
		c, err := scanContext(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// PutDocument creates or updates the document identified by (selected scope,
// kind, slug).
//
// Pre: the command passes app.ValidateDocumentCmd; the scope is
// declared; Expected is 0 or the current revision of an existing document.
// The idempotency key is derived from scope, kind, slug and Expected, so no
// caller key is required. Post: one transaction — an identical retry replays
// the stored document, a different payload under the same key is
// idempotency_conflict, a missing document with a non-zero Expected or an
// existing document at another revision is stale_revision, otherwise the
// document is inserted at revision 1 or advanced by one, with its history
// event and the idempotency record. Nothing is written on failure.
// DraftOnly adds two guards inside the same transaction: Expected 0 never
// touches an existing document (stale_revision), and only a draft may be
// updated (invalid_transition).
func (s *Store) PutDocument(ctx context.Context, cmd app.DocumentCmd, now time.Time) (domain.Document, error) {
	now = now.UTC().Truncate(time.Second)
	if err := app.ValidateDocumentCmd(cmd); err != nil {
		return domain.Document{}, err
	}
	var out domain.Document
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var err error
		out, err = putDocumentTx(ctx, tx, cmd, now)
		return err
	})
	return out, err
}

func putDocumentTx(ctx context.Context, tx *sql.Tx, cmd app.DocumentCmd, now time.Time) (domain.Document, error) {
	if err := app.ValidateDocumentCmd(cmd); err != nil {
		return domain.Document{}, err
	}
	scope := cmd.Scope
	if scope == "" {
		scope = cmd.Binding.Scopes[0]
	}
	key := fmt.Sprintf("%s|%s|%s|%d", scope, cmd.Kind, cmd.Slug, int64(cmd.Expected))
	// The binding is session context, not payload: the key already pins the
	// scope, so an identical document under an equivalent binding replays.
	payload := cmd
	payload.Binding = domain.ScopeBinding{}
	hash, err := hashPayload(payload)
	if err != nil {
		return domain.Document{}, err
	}
	var out domain.Document
	err = func() error {
		done, err := lookupIdem(ctx, tx, "doc put", key, hash, &out)
		if err != nil || done {
			return err
		}
		if err := requireScopeDeclared(ctx, tx, scope); err != nil {
			return err
		}
		if cmd.ProjectID != nil {
			if err := checkSameScope(ctx, tx, "projects", "project", string(*cmd.ProjectID), scope); err != nil {
				return err
			}
		}
		existing, err := scanDocument(tx.QueryRowContext(ctx,
			"SELECT "+documentColumns+" FROM documents WHERE scope_id = ? AND slug = ?",
			string(scope), cmd.Slug))
		var next domain.Revision
		switch {
		case errors.Is(err, sql.ErrNoRows):
			if cmd.Expected != 0 {
				return domain.NewError(domain.StaleRevision,
					"no document %s/%s exists in scope %s, so expected must be 0",
					cmd.Kind, cmd.Slug, scope)
			}
			next = 1
		case err != nil:
			return err
		default:
			if cmd.Expected == 0 {
				return domain.NewError(domain.StaleRevision,
					"document %s/%s already exists at revision %d in scope %s, so expected must be its current revision",
					cmd.Kind, cmd.Slug, existing.Revision, scope)
			}
			if cmd.Expected != 0 && cmd.Expected != existing.Revision {
				return domain.NewError(domain.StaleRevision,
					"document %s/%s is at revision %d, expected %d",
					cmd.Kind, cmd.Slug, existing.Revision, cmd.Expected)
			}
			if cmd.DraftOnly && existing.Status != domain.DocumentDraft {
				return domain.NewError(domain.InvalidTransition,
					"document %s/%s is %s, so a draft-only write cannot update it",
					cmd.Kind, cmd.Slug, existing.Status)
			}
			next = existing.Revision.Next()
		}

		event := "created"
		if next == 1 {
			out = domain.Document{
				ID:        fmt.Sprintf("doc:%s:%s:%s", scope, cmd.Kind, cmd.Slug),
				Scope:     string(scope),
				Kind:      string(cmd.Kind),
				Slug:      cmd.Slug,
				Title:     cmd.Title,
				Body:      cmd.Body,
				Status:    cmd.Status,
				Revision:  1,
				CreatedAt: now,
				UpdatedAt: now,
			}
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO documents (id, scope_id, kind, slug, title, body, status,
					revision, created_at, updated_at)
				     VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
				out.ID, string(scope), string(cmd.Kind), cmd.Slug, cmd.Title, cmd.Body,
				string(cmd.Status), fmtTime(now), fmtTime(now)); err != nil {
				return err
			}
		} else {
			out = existing
			out.Title, out.Body, out.Status = cmd.Title, cmd.Body, cmd.Status
			if existing.Kind != string(cmd.Kind) {
				return domain.NewError(domain.Conflict, "slug already belongs to a document with another purpose")
			}
			out.Revision = next
			out.UpdatedAt = now
			if _, err := tx.ExecContext(ctx,
				`UPDATE documents SET title = ?, body = ?, status = ?, revision = ?, updated_at = ?
				     WHERE id = ? AND scope_id = ? AND kind = ? AND slug = ?`,
				out.Title, out.Body, string(out.Status), int64(out.Revision), fmtTime(out.UpdatedAt),
				out.ID, string(scope), string(cmd.Kind), cmd.Slug); err != nil {
				return err
			}
			event = "updated"
		}
		out.Sources, out.ProjectID = cmd.Sources, cmd.ProjectID
		sources := cmd.Sources
		if sources == nil {
			sources = []string{}
		}
		encoded, err := json.Marshal(sources)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE documents SET sources_json = ?, project_id = ? WHERE id = ?", string(encoded), argID(cmd.ProjectID), out.ID); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "document", out.ID, event,
			string(scope), "", out.Revision, out, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "doc put", key, hash, out, now)
	}()
	if err != nil {
		return domain.Document{}, err
	}
	return out, nil
}

// GetDocument returns a document in the selected scope, or in the binding
// when no scope is supplied. Ambiguous slugs require an explicit scope.
func (s *Store) GetDocument(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind, slug string, scope ...domain.ScopeID) (domain.Document, error) {
	if err := b.Validate(); err != nil {
		return domain.Document{}, err
	}
	if len(scope) > 1 {
		return domain.Document{}, domain.Invalid("at most one document scope may be selected")
	}
	query := "SELECT " + documentColumns + " FROM documents WHERE (kind = ? AND slug = ? OR id IN (SELECT document_id FROM document_aliases WHERE kind = ? AND slug = ?))"
	args := []any{string(kind), slug, string(kind), slug}
	if len(scope) == 1 && scope[0] != "" {
		if !b.Allows(scope[0]) {
			return domain.Document{}, domain.NewError(domain.ScopeDenied, "document scope is outside this binding")
		}
		query += " AND scope_id = ?"
		args = append(args, string(scope[0]))
	} else {
		clause, scopeArgs, err := scopeClause(b)
		if err != nil {
			return domain.Document{}, err
		}
		query += " AND scope_id IN (" + clause + ")"
		args = append(args, scopeArgs...)
	}
	rows, err := s.db.QueryContext(ctx, query+" ORDER BY scope_id LIMIT 2", args...)
	if err != nil {
		return domain.Document{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return domain.Document{}, err
		}
		return domain.Document{}, domain.NewError(domain.NotFound,
			"document %s/%s not found", kind, slug)
	}
	d, err := scanDocument(rows)
	if err != nil {
		return domain.Document{}, err
	}
	if rows.Next() {
		return domain.Document{}, domain.NewError(domain.Conflict,
			"document %s/%s exists in multiple bound scopes; specify scope", kind, slug)
	}
	if err := rows.Err(); err != nil {
		return domain.Document{}, err
	}
	return d, nil
}

// ListDocuments returns the documents of the binding scopes ordered by kind
// and slug. An empty kind lists every kind.
func (s *Store) ListDocuments(ctx context.Context, b domain.ScopeBinding, kind domain.DocumentKind) ([]domain.Document, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	query := "SELECT " + documentColumns + " FROM documents WHERE scope_id IN (" + clause + ")"
	if kind != "" {
		query += " AND kind = ?"
		args = append(args, string(kind))
	}
	query += " ORDER BY kind, slug"
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Document{}
	for rows.Next() {
		d, err := scanDocument(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// documentHistoryDefault and documentHistoryCap bound one doc log listing:
// 50 entries unless asked otherwise, never more than 500.
const (
	documentHistoryDefault = 50
	documentHistoryCap     = 500
)

// documentSearchDefault and documentSearchCap bound one doc search listing:
// 10 hits unless asked otherwise, never more than 50.
const (
	documentSearchDefault = 10
	documentSearchCap     = 50
)

// joinedDocumentColumns qualifies every document column with its table so the
// FTS5 join never hits an ambiguous name shared with documents_fts.
const joinedDocumentColumns = `documents.id, documents.scope_id, documents.kind,
	documents.slug, documents.title, documents.body, documents.status,
	documents.revision, documents.created_at, documents.updated_at, documents.sources_json, documents.project_id`

// ftsQuery renders user input as a safe FTS5 MATCH expression: every
// whitespace-separated token is wrapped in double quotes with embedded quotes
// doubled, then the tokens are ANDed. No operator or syntax from the caller
// ever reaches MATCH, so a query can only be a literal search.
func ftsQuery(query string) string {
	tokens := strings.Fields(query)
	quoted := make([]string, 0, len(tokens))
	for _, t := range tokens {
		quoted = append(quoted, `"`+strings.ReplaceAll(t, `"`, `""`)+`"`)
	}
	return strings.Join(quoted, " AND ")
}

// SearchDocuments runs one read-only FTS5 query over the binding scopes'
// documents, optionally narrowed to one kind. Limit 0 selects the default of
// 10; any limit above 50 is capped at 50. Hits are ordered by bm25 ascending
// (the smaller the better), then kind and slug for a deterministic tie-break.
// An empty result is a list, not an error.
func (s *Store) SearchDocuments(ctx context.Context, b domain.ScopeBinding, query string, kind domain.DocumentKind, limit int, project ...domain.ProjectID) ([]app.DocumentSearchHit, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	match := ftsQuery(query)
	if match == "" {
		return nil, domain.Invalid("search query is required")
	}
	if kind != "" && !domain.ValidDocumentKind(kind) {
		return nil, domain.Invalid("unknown document kind %q", kind)
	}
	switch {
	case limit <= 0:
		limit = documentSearchDefault
	case limit > documentSearchCap:
		limit = documentSearchCap
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	stmt := `SELECT ` + joinedDocumentColumns + `,
			bm25(documents_fts),
			snippet(documents_fts, 5, '[', ']', '…', 20)
		FROM documents_fts
		JOIN documents ON documents.id = documents_fts.doc_id
		WHERE documents_fts MATCH ? AND documents_fts.scope_id IN (` + clause + `)`
	args = append([]any{match}, args...)
	if kind != "" {
		stmt += " AND documents_fts.kind = ?"
		args = append(args, string(kind))
	}
	if len(project) > 0 && project[0] != "" {
		stmt += " AND documents.project_id = ?"
		args = append(args, string(project[0]))
	}
	stmt += " ORDER BY bm25(documents_fts) ASC, documents.kind, documents.slug LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, stmt, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []app.DocumentSearchHit{}
	for rows.Next() {
		var (
			hit     app.DocumentSearchHit
			scope   string
			kindCol string
			status  string
			created string
			updated string
			sources string
			project sql.NullString
		)
		if err := rows.Scan(&hit.Document.ID, &scope, &kindCol, &hit.Document.Slug,
			&hit.Document.Title, &hit.Document.Body, &status, &hit.Document.Revision,
			&created, &updated, &sources, &project, &hit.Rank, &hit.Snippet); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(sources), &hit.Document.Sources); err != nil {
			return nil, err
		}
		hit.Document.ProjectID = ptrID[domain.ProjectID](project)
		hit.Document.Scope = scope
		hit.Document.Kind = kindCol
		hit.Document.Status = domain.DocumentStatus(status)
		if hit.Document.CreatedAt, err = parseTime("documents.created_at", created); err != nil {
			return nil, err
		}
		if hit.Document.UpdatedAt, err = parseTime("documents.updated_at", updated); err != nil {
			return nil, err
		}
		out = append(out, hit)
	}
	return out, rows.Err()
}

// ListDocumentHistory returns the history events of the binding scopes'
// documents, newest first (seq DESC), optionally narrowed to one kind or
// slug. The join reads d.scope_id because history scope_id may be null, and
// the binding filter therefore applies to the document, never to the event.
// An empty result is a list, not an error.
func (s *Store) ListDocumentHistory(ctx context.Context, b domain.ScopeBinding, filter app.DocumentHistoryFilter) ([]app.DocumentLogEntry, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	if filter.Kind != "" && !domain.ValidDocumentKind(filter.Kind) {
		return nil, domain.Invalid("unknown document kind %q", filter.Kind)
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	limit := filter.Limit
	switch {
	case limit <= 0:
		limit = documentHistoryDefault
	case limit > documentHistoryCap:
		limit = documentHistoryCap
	}
	query := `SELECT h.seq, h.event, h.revision, h.created_at, d.scope_id, d.kind, d.slug
		     FROM history_events h JOIN documents d ON d.id = h.entity_id
		     WHERE h.entity_type = 'document' AND d.scope_id IN (` + clause + `)`
	if filter.Kind != "" {
		query += " AND d.kind = ?"
		args = append(args, string(filter.Kind))
	}
	if filter.Slug != "" {
		query += " AND d.slug = ?"
		args = append(args, filter.Slug)
	}
	query += " ORDER BY h.seq DESC LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []app.DocumentLogEntry{}
	for rows.Next() {
		var (
			e       app.DocumentLogEntry
			created string
		)
		if err := rows.Scan(&e.Seq, &e.Event, &e.Revision, &created, &e.Scope, &e.Kind, &e.Slug); err != nil {
			return nil, err
		}
		if e.CreatedAt, err = parseTime("history_events.created_at", created); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
