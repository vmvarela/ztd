package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const projectColumns = `id, scope_id, area_id, desired_outcome, status,
	repo_url, clone_path, revision`

func scanProject(sc scanner) (domain.Project, error) {
	var (
		p    domain.Project
		area sql.NullString
		rev  int64
	)
	if err := sc.Scan(&p.ID, &p.Scope, &area, &p.DesiredOutcome, &p.Status,
		&p.RepoURL, &p.ClonePath, &rev); err != nil {
		return domain.Project{}, err
	}
	p.AreaID = ptrID[domain.AreaID](area)
	p.Revision = domain.Revision(rev)
	return p, nil
}

func collectProjects(rows *sql.Rows) ([]domain.Project, error) {
	defer rows.Close()
	var out []domain.Project
	for rows.Next() {
		p, err := scanProject(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// sameProjectConfig reports whether an existing project already carries the
// configuration the command asks for.
func sameProjectConfig(existing domain.Project, cmd app.ProjectCmd, scope domain.ScopeID) bool {
	return existing.Scope == scope &&
		existing.DesiredOutcome == cmd.DesiredOutcome &&
		existing.Status == cmd.Status &&
		existing.RepoURL == cmd.RepoURL &&
		existing.ClonePath == cmd.ClonePath
}

// AddProject declares one project in the binding's primary scope. The id keeps
// its caller-chosen form, including legacy path-style ids like opensource/ztd.
//
// Pre: the command passes app.ValidateProjectCmd and the primary scope is
// declared. Post: one transaction inserts the project with revision 1 and its
// "created" history event. Re-adding the same id with an identical
// configuration returns the existing row without writes; a different
// configuration or scope for the same id is conflict. Nothing is written on
// failure.
func (s *Store) AddProject(ctx context.Context, cmd app.ProjectCmd, now time.Time) (domain.Project, error) {
	now = now.UTC().Truncate(time.Second)
	if err := app.ValidateProjectCmd(cmd); err != nil {
		return domain.Project{}, err
	}
	scope := cmd.Binding.Scopes[0]
	var out domain.Project
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		if err := requireScopeDeclared(ctx, tx, scope); err != nil {
			return err
		}
		existing, err := scanProject(tx.QueryRowContext(ctx,
			"SELECT "+projectColumns+" FROM projects WHERE id = ?", cmd.ID))
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return err
		default:
			if !sameProjectConfig(existing, cmd, scope) {
				return domain.NewError(domain.Conflict,
					"project %s already exists with a different configuration", cmd.ID)
			}
			out = existing
			return nil
		}
		out = domain.Project{
			ID:             domain.ProjectID(cmd.ID),
			Scope:          scope,
			DesiredOutcome: cmd.DesiredOutcome,
			Status:         cmd.Status,
			RepoURL:        cmd.RepoURL,
			ClonePath:      cmd.ClonePath,
			Revision:       1,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO projects (id, scope_id, area_id, desired_outcome, status,
				repo_url, clone_path, revision)
			     VALUES (?, ?, NULL, ?, ?, ?, ?, 1)`,
			cmd.ID, string(scope), cmd.DesiredOutcome, cmd.Status,
			cmd.RepoURL, cmd.ClonePath); err != nil {
			return err
		}
		return insertHistory(ctx, tx, "project", cmd.ID, "created",
			string(scope), "", 1, out, now)
	})
	if err != nil {
		return domain.Project{}, err
	}
	return out, nil
}

// ListProjects returns the projects of the binding scopes ordered by id.
func (s *Store) ListProjects(ctx context.Context, b domain.ScopeBinding) ([]domain.Project, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+projectColumns+" FROM projects WHERE scope_id IN ("+clause+") ORDER BY id", args...)
	if err != nil {
		return nil, err
	}
	return collectProjects(rows)
}

// GetProject returns one project of the binding scopes. A project outside the
// binding is not_found: projects never disclose their existence across scopes.
func (s *Store) GetProject(ctx context.Context, b domain.ScopeBinding, id domain.ProjectID) (domain.Project, error) {
	if err := b.Validate(); err != nil {
		return domain.Project{}, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.Project{}, err
	}
	args = append([]any{string(id)}, args...)
	row := s.db.QueryRowContext(ctx,
		"SELECT "+projectColumns+" FROM projects WHERE id = ? AND scope_id IN ("+clause+")", args...)
	p, err := scanProject(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Project{}, domain.NewError(domain.NotFound, "project %s not found", id)
	}
	if err != nil {
		return domain.Project{}, err
	}
	return p, nil
}

// setProjectRepoTx fills the empty repository fields of one project inside an
// existing transaction. apply=false performs the same reads and computes the
// same result without writing, which is how a dry-run reports what an import
// would do. changed reports whether a real write happened.
//
// Pre: apply implies the values pass app.ValidRepoURL/app.ValidClonePath.
// Post: at most one UPDATE plus its "updated" history event; an unknown
// project is not_found and nothing is written.
func setProjectRepoTx(ctx context.Context, tx *sql.Tx, id domain.ProjectID, repoURL, clonePath string, apply bool, now time.Time) (domain.Project, bool, error) {
	proj, err := scanProject(tx.QueryRowContext(ctx,
		"SELECT "+projectColumns+" FROM projects WHERE id = ?", string(id)))
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Project{}, false, domain.NewError(domain.NotFound, "project %s not found", id)
	}
	if err != nil {
		return domain.Project{}, false, err
	}
	next := proj
	if proj.RepoURL == "" && repoURL != "" {
		next.RepoURL = repoURL
	}
	if proj.ClonePath == "" && clonePath != "" {
		next.ClonePath = clonePath
	}
	changed := next.RepoURL != proj.RepoURL || next.ClonePath != proj.ClonePath
	if !changed || !apply {
		return next, changed, nil
	}
	next.Revision = proj.Revision.Next()
	if _, err := tx.ExecContext(ctx,
		`UPDATE projects SET repo_url = ?, clone_path = ?, revision = ? WHERE id = ?`,
		next.RepoURL, next.ClonePath, int64(next.Revision), string(next.ID)); err != nil {
		return domain.Project{}, false, err
	}
	if err := insertHistory(ctx, tx, "project", string(next.ID), "updated",
		string(next.Scope), "", next.Revision, next, now); err != nil {
		return domain.Project{}, false, err
	}
	return next, true, nil
}

// SetProjectRepo fills the empty repository fields of an existing project and
// leaves a different non-empty value untouched: the caller compares the
// returned project to detect that case. It is the write path behind the
// documents import, kept here so no caller runs raw SQL against projects.
//
// Pre: the project exists; repoURL, when set, passes app.ValidRepoURL and
// clonePath, when set, passes app.ValidClonePath.
// Post: one transaction — zero or one UPDATE with its "updated" history
// event. Nothing is written on failure.
func (s *Store) SetProjectRepo(ctx context.Context, projectID domain.ProjectID, repoURL, clonePath string, now time.Time) (domain.Project, error) {
	now = now.UTC().Truncate(time.Second)
	if strings.TrimSpace(string(projectID)) == "" {
		return domain.Project{}, domain.Invalid("project id is required")
	}
	if repoURL != "" && !app.ValidRepoURL(repoURL) {
		return domain.Project{}, domain.Invalid("repository url must be absolute (include a scheme) and without credentials, got %q", repoURL)
	}
	if clonePath != "" && !app.ValidClonePath(clonePath) {
		return domain.Project{}, domain.Invalid("clone path must be an absolute path without .. segments, got %q", clonePath)
	}
	var out domain.Project
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var err error
		out, _, err = setProjectRepoTx(ctx, tx, projectID, repoURL, clonePath, true, now)
		return err
	})
	if err != nil {
		return domain.Project{}, err
	}
	return out, nil
}
