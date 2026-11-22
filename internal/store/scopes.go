package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const scopeColumns = `id, name, kind, created_at`
const profileColumns = `id, name, kind, owner_actor_id, timezone, status`

func scanScope(sc scanner) (domain.Scope, error) {
	var (
		s       domain.Scope
		kind    string
		created string
	)
	if err := sc.Scan(&s.ID, &s.Name, &kind, &created); err != nil {
		return domain.Scope{}, err
	}
	s.Kind = domain.ScopeKind(kind)
	createdAt, err := parseTime("scopes.created_at", created)
	if err != nil {
		return domain.Scope{}, err
	}
	s.CreatedAt = createdAt
	return s, nil
}

func scanProfile(sc scanner) (domain.Profile, error) {
	var p domain.Profile
	if err := sc.Scan(&p.ID, &p.Name, &p.Kind, &p.OwnerActor, &p.Timezone, &p.Status); err != nil {
		return domain.Profile{}, err
	}
	return p, nil
}

// addScopeTx applies one scope declaration inside an existing transaction.
// existed reports whether the row was already there with an identical
// configuration.
//
// Pre: cmd passes app.ValidateScopeCmd. Post: an identical row is returned
// untouched, a different kind or name for the same id is conflict, and a new
// id is inserted. Nothing is written on conflict.
func addScopeTx(ctx context.Context, tx *sql.Tx, cmd app.ScopeCmd, now time.Time) (domain.Scope, bool, error) {
	if err := app.ValidateScopeCmd(cmd); err != nil {
		return domain.Scope{}, false, err
	}
	if cmd.Name == "" {
		cmd.Name = cmd.ID
	}
	existing, err := scanScope(tx.QueryRowContext(ctx,
		"SELECT "+scopeColumns+" FROM scopes WHERE id = ?", cmd.ID))
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return domain.Scope{}, false, err
	default:
		if existing.Kind != domain.ScopeKind(cmd.Kind) || existing.Name != cmd.Name {
			return domain.Scope{}, true, domain.NewError(domain.Conflict,
				"scope %s already exists with a different kind or name", cmd.ID)
		}
		return existing, true, nil
	}
	scope := domain.Scope{
		ID: domain.ScopeID(cmd.ID), Name: cmd.Name,
		Kind: domain.ScopeKind(cmd.Kind), CreatedAt: now,
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO scopes (id, name, kind, created_at) VALUES (?, ?, ?, ?)`,
		scope.ID, scope.Name, string(scope.Kind), fmtTime(now)); err != nil {
		return domain.Scope{}, false, err
	}
	return scope, false, nil
}

// loadProfileTx reads one profile and its scopes. found is false for an
// unknown id.
func loadProfileTx(ctx context.Context, tx *sql.Tx, id string) (domain.Profile, []domain.ScopeID, bool, error) {
	p, err := scanProfile(tx.QueryRowContext(ctx,
		"SELECT "+profileColumns+" FROM profiles WHERE id = ?", id))
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return domain.Profile{}, nil, false, nil
	case err != nil:
		return domain.Profile{}, nil, false, err
	}
	rows, err := tx.QueryContext(ctx,
		// rowid keeps the declaration order: Scopes[0] is the primary scope a
		// capture lands in when no --scope is given.
		"SELECT scope_id FROM profile_scopes WHERE profile_id = ? ORDER BY rowid", id)
	if err != nil {
		return domain.Profile{}, nil, false, err
	}
	defer rows.Close()
	var scopes []domain.ScopeID
	for rows.Next() {
		var sc domain.ScopeID
		if err := rows.Scan(&sc); err != nil {
			return domain.Profile{}, nil, false, err
		}
		scopes = append(scopes, sc)
	}
	return p, scopes, true, rows.Err()
}

// scopeKinds resolves the kind of every referenced scope. A scope that does
// not exist is invalid_input, so a profile can never point at a missing
// boundary.
func scopeKindsTx(ctx context.Context, tx *sql.Tx, ids []string) (map[string]string, error) {
	kinds := make(map[string]string, len(ids))
	for _, id := range ids {
		if _, ok := kinds[id]; ok {
			continue
		}
		var kind string
		err := tx.QueryRowContext(ctx, "SELECT kind FROM scopes WHERE id = ?", id).Scan(&kind)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			return nil, domain.Invalid("unknown scope reference %s", id)
		case err != nil:
			return nil, err
		}
		kinds[id] = kind
	}
	return kinds, nil
}

// checkProfileScopeKinds enforces the kind rules: a work_client profile
// covers exactly one client scope. A personal profile is the global planning
// view and may cover any declared scope; scopes are organizational labels.
func checkProfileScopeKinds(cmd app.ProfileCmd, kinds map[string]string) error {
	switch cmd.Kind {
	case string(domain.WorkClientProfile):
		if kinds[cmd.Scopes[0]] != string(domain.ScopeKindClient) {
			return domain.Invalid("work_client profile %s needs a client scope, %s is %s",
				cmd.ID, cmd.Scopes[0], kinds[cmd.Scopes[0]])
		}
	}
	return nil
}

// addProfileTx applies one profile declaration inside an existing
// transaction. existed reports whether the profile already covered every
// declared scope.
//
// Pre: cmd passes app.ValidateProfileCmd. Post: a new profile is inserted with
// its profile_scopes rows; an existing profile with the same kind and owner
// gains any missing declared scopes, preserving order, and never loses one.
// A different owner or kind is conflict. Every referenced scope must exist and
// satisfy the kind rules of the profile kind.
func addProfileTx(ctx context.Context, tx *sql.Tx, cmd app.ProfileCmd, now time.Time) (domain.Profile, bool, error) {
	if err := app.ValidateProfileCmd(cmd); err != nil {
		return domain.Profile{}, false, err
	}
	if cmd.Name == "" {
		cmd.Name = cmd.ID
	}
	existing, scopes, found, err := loadProfileTx(ctx, tx, cmd.ID)
	if err != nil {
		return domain.Profile{}, false, err
	}
	if found {
		if string(existing.Kind) != cmd.Kind {
			return domain.Profile{}, true, domain.NewError(domain.Conflict,
				"profile %s already exists as kind %s", cmd.ID, existing.Kind)
		}
		if string(existing.OwnerActor) != cmd.Actor {
			return domain.Profile{}, true, domain.NewError(domain.Conflict,
				"profile %s is owned by actor %s, not %s", cmd.ID, existing.OwnerActor, cmd.Actor)
		}
	}
	kinds, err := scopeKindsTx(ctx, tx, cmd.Scopes)
	if err != nil {
		return domain.Profile{}, false, err
	}
	if err := checkProfileScopeKinds(cmd, kinds); err != nil {
		return domain.Profile{}, false, err
	}
	if found {
		have := make(map[domain.ScopeID]bool, len(scopes))
		for _, sc := range scopes {
			have[sc] = true
		}
		missing := 0
		for _, id := range cmd.Scopes {
			sc := domain.ScopeID(id)
			if have[sc] {
				continue
			}
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO profile_scopes (profile_id, scope_id) VALUES (?, ?)`,
				existing.ID, sc); err != nil {
				return domain.Profile{}, false, err
			}
			scopes = append(scopes, sc)
			missing++
		}
		existing.Scopes = scopes
		return existing, missing == 0, nil
	}
	profile := domain.Profile{
		ID: domain.ProfileID(cmd.ID), Name: cmd.Name,
		Kind: domain.ProfileKind(cmd.Kind), OwnerActor: domain.ActorID(cmd.Actor),
		Timezone: localTimezone(), Status: "active",
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO profiles (id, name, kind, owner_actor_id, timezone, status)
		 VALUES (?, ?, ?, ?, ?, 'active')`,
		profile.ID, profile.Name, string(profile.Kind), profile.OwnerActor, profile.Timezone); err != nil {
		return domain.Profile{}, false, err
	}
	// Declared order is kept: reads order by rowid, so profile_scopes needs no
	// position column and the first declared scope stays the primary one.
	profile.Scopes = make([]domain.ScopeID, 0, len(cmd.Scopes))
	for _, id := range cmd.Scopes {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO profile_scopes (profile_id, scope_id) VALUES (?, ?)`,
			profile.ID, id); err != nil {
			return domain.Profile{}, false, err
		}
		profile.Scopes = append(profile.Scopes, domain.ScopeID(id))
	}
	return profile, false, nil
}

// AddScope declares one scope.
//
// Pre: cmd validates. Post: one transaction. An identical configuration is
// returned without writing; a different kind or name for the same id is
// conflict. Nothing is written on failure.
func (s *Store) AddScope(ctx context.Context, cmd app.ScopeCmd, now time.Time) (domain.Scope, error) {
	now = now.UTC().Truncate(time.Second)
	var out domain.Scope
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var err error
		out, _, err = addScopeTx(ctx, tx, cmd, now)
		return err
	})
	if err != nil {
		return domain.Scope{}, err
	}
	return out, nil
}

// ListScopes returns every declared scope ordered by id, so the listing is
// deterministic across calls.
func (s *Store) ListScopes(ctx context.Context) ([]domain.Scope, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+scopeColumns+" FROM scopes ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Scope{}
	for rows.Next() {
		sc, err := scanScope(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, rows.Err()
}

// AddProfile declares one planning profile over scopes that exist.
//
// Pre: cmd validates; every referenced scope exists and satisfies the kind
// rules. Post: one transaction inserts the profile and its profile_scopes
// rows. An identical profile (kind, owner actor, scope set) is returned
// without writing; another owner, kind or scope set is conflict. Nothing is
// written on failure.
func (s *Store) AddProfile(ctx context.Context, cmd app.ProfileCmd, now time.Time) (domain.Profile, error) {
	now = now.UTC().Truncate(time.Second)
	var out domain.Profile
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var err error
		out, _, err = addProfileTx(ctx, tx, cmd, now)
		return err
	})
	if err != nil {
		return domain.Profile{}, err
	}
	return out, nil
}

// ListProfiles returns every profile ordered by id, each with the scopes it
// covers in declaration order.
// SetProfileScopes replaces the scopes of an existing profile in one
// transaction. Kind, owner and name are preserved; the new set must satisfy
// the same kind rules as profile creation.
func (s *Store) SetProfileScopes(ctx context.Context, id domain.ProfileID, scopes []domain.ScopeID, now time.Time) (domain.Profile, error) {
	now = now.UTC().Truncate(time.Second)
	var out domain.Profile
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		existing, _, found, err := loadProfileTx(ctx, tx, string(id))
		if err != nil {
			return err
		}
		if !found {
			return domain.NewError(domain.NotFound, "profile %s not found", id)
		}
		cmd := app.ProfileCmd{ID: string(id), Name: existing.Name, Kind: string(existing.Kind), Actor: string(existing.OwnerActor)}
		for _, sc := range scopes {
			cmd.Scopes = append(cmd.Scopes, string(sc))
		}
		if err := app.ValidateProfileCmd(cmd); err != nil {
			return err
		}
		kinds, err := scopeKindsTx(ctx, tx, cmd.Scopes)
		if err != nil {
			return err
		}
		if err := checkProfileScopeKinds(cmd, kinds); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "DELETE FROM profile_scopes WHERE profile_id = ?", id); err != nil {
			return err
		}
		for _, sc := range scopes {
			if _, err := tx.ExecContext(ctx, "INSERT INTO profile_scopes (profile_id, scope_id) VALUES (?, ?)", id, sc); err != nil {
				return err
			}
		}
		out = existing
		out.Scopes = append([]domain.ScopeID(nil), scopes...)
		return nil
	})
	if err != nil {
		return domain.Profile{}, err
	}
	return out, nil
}

func (s *Store) ListProfiles(ctx context.Context) ([]domain.Profile, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+profileColumns+" FROM profiles ORDER BY id ASC")
	if err != nil {
		return nil, err
	}
	out := []domain.Profile{}
	for rows.Next() {
		p, err := scanProfile(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		p.Scopes = []domain.ScopeID{}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	// Declaration order matters: the first scope is the binding's primary
	// scope, where a capture lands when no --scope is given.
	scopeRows, err := s.db.QueryContext(ctx,
		"SELECT profile_id, scope_id FROM profile_scopes ORDER BY profile_id ASC, rowid ASC")
	if err != nil {
		return nil, err
	}
	defer scopeRows.Close()
	byID := make(map[domain.ProfileID]*domain.Profile, len(out))
	for i := range out {
		byID[out[i].ID] = &out[i]
	}
	for scopeRows.Next() {
		var profile domain.ProfileID
		var sc domain.ScopeID
		if err := scopeRows.Scan(&profile, &sc); err != nil {
			return nil, err
		}
		if p := byID[profile]; p != nil {
			p.Scopes = append(p.Scopes, sc)
		}
	}
	return out, scopeRows.Err()
}

// ApplyConfig applies one scope/profile declaration in a single transaction:
// scopes first, then the profiles that reference them, so a profile can
// declare its own scopes. Any conflict rolls back the whole batch, and
// entries that already existed with an identical configuration are reported
// as such. Nothing it does not declare is deleted.
//
// Pre: at least one scope and one profile; every command validates.
// Post: one transaction, all or nothing.
func (s *Store) ApplyConfig(ctx context.Context, scopes []app.ScopeCmd, profiles []app.ProfileCmd, now time.Time) (app.ConfigResult, error) {
	now = now.UTC().Truncate(time.Second)
	if len(scopes) == 0 {
		return app.ConfigResult{}, domain.Invalid("at least one scope declaration is required")
	}
	if len(profiles) == 0 {
		return app.ConfigResult{}, domain.Invalid("at least one profile declaration is required")
	}
	res := app.ConfigResult{Scopes: []app.ConfigEntry{}, Profiles: []app.ConfigEntry{}}
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		for _, cmd := range scopes {
			_, existed, err := addScopeTx(ctx, tx, cmd, now)
			if err != nil {
				return err
			}
			res.Scopes = append(res.Scopes, app.ConfigEntry{ID: cmd.ID, Existed: existed})
		}
		for _, cmd := range profiles {
			_, existed, err := addProfileTx(ctx, tx, cmd, now)
			if err != nil {
				return err
			}
			res.Profiles = append(res.Profiles, app.ConfigEntry{ID: cmd.ID, Existed: existed})
		}
		return nil
	})
	if err != nil {
		return app.ConfigResult{}, err
	}
	return res, nil
}

// ProfileScopes returns the scopes a profile covers, in declaration order:
// the first one is the primary scope of the binding. An unknown profile is
// not_found instead of an empty binding, so a typo never silently widens or
// empties a session.
func (s *Store) ProfileScopes(ctx context.Context, profile domain.ProfileID) ([]domain.ScopeID, error) {
	var one int
	err := s.db.QueryRowContext(ctx, "SELECT 1 FROM profiles WHERE id = ?", string(profile)).Scan(&one)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, domain.NewError(domain.NotFound, "profile %s not found", profile)
	case err != nil:
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT scope_id FROM profile_scopes WHERE profile_id = ? ORDER BY rowid", string(profile))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.ScopeID{}
	for rows.Next() {
		var sc domain.ScopeID
		if err := rows.Scan(&sc); err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, rows.Err()
}
