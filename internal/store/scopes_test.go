package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func profileCmd(id, kind, actor string, scopes ...string) app.ProfileCmd {
	return app.ProfileCmd{ID: id, Kind: kind, Actor: actor, Scopes: scopes}
}

func mustAddScope(t *testing.T, s *Store, cmd app.ScopeCmd, now time.Time) {
	t.Helper()
	if _, err := s.AddScope(context.Background(), cmd, now); err != nil {
		t.Fatalf("AddScope(%s): %v", cmd.ID, err)
	}
}

// TestAddScopeListAndConflict pins the scope contract: create, idempotent
// re-add, conflict on a different kind or name, and a listing ordered by id.
func TestAddScopeListAndConflict(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)

	got, err := s.AddScope(ctx, app.ScopeCmd{ID: "salud", Kind: "personal", Name: "Salud"}, now)
	if err != nil {
		t.Fatalf("AddScope: %v", err)
	}
	if got.ID != "salud" || got.Name != "Salud" || got.Kind != domain.ScopeKindPersonal {
		t.Fatalf("scope = %+v, want salud named Salud", got)
	}
	if !got.CreatedAt.Equal(now) {
		t.Fatalf("created_at = %v, want %v", got.CreatedAt, now)
	}

	// An identical declaration is a no-op, even an hour later.
	again, err := s.AddScope(ctx, app.ScopeCmd{ID: "salud", Kind: "personal", Name: "Salud"}, now.Add(time.Hour))
	if err != nil {
		t.Fatalf("re-add: %v", err)
	}
	if !again.CreatedAt.Equal(now) {
		t.Fatalf("re-add moved created_at to %v", again.CreatedAt)
	}

	// Another kind or another name for the same id is conflict.
	if _, err := s.AddScope(ctx, app.ScopeCmd{ID: "salud", Kind: "work"}, now); !domain.Of(err, domain.Conflict) {
		t.Fatalf("different kind: got %v, want conflict", err)
	}
	if _, err := s.AddScope(ctx, app.ScopeCmd{ID: "salud", Kind: "personal", Name: "Health"}, now); !domain.Of(err, domain.Conflict) {
		t.Fatalf("different name: got %v, want conflict", err)
	}
	// Invalid declarations are rejected before any SQL runs.
	for _, bad := range []app.ScopeCmd{
		{ID: "Bad Id", Kind: "personal"},
		{ID: "x", Kind: "health"},
		{ID: "x,y", Kind: "personal"},
	} {
		if _, err := s.AddScope(ctx, bad, now); !domain.Of(err, domain.InvalidInput) {
			t.Fatalf("AddScope(%+v): got %v, want invalid_input", bad, err)
		}
	}
	if n := countRows(t, s, "scopes"); n != 1 {
		t.Fatalf("scopes = %d, want 1", n)
	}

	for _, cmd := range []app.ScopeCmd{
		{ID: "personal", Kind: "personal"},
		{ID: "client:prisamedia", Kind: "client"},
		{ID: "opensource", Kind: "opensource"},
	} {
		mustAddScope(t, s, cmd, now)
	}
	list, err := s.ListScopes(ctx)
	if err != nil {
		t.Fatalf("ListScopes: %v", err)
	}
	want := []domain.ScopeID{"client:prisamedia", "opensource", "personal", "salud"}
	if len(list) != len(want) {
		t.Fatalf("list = %+v, want %v", list, want)
	}
	for i, id := range want {
		if list[i].ID != id {
			t.Fatalf("list[%d] = %s, want %s (ordered by id)", i, list[i].ID, id)
		}
	}
}

// TestAddProfileRules pins the profile contract: create, idempotence, owner
// and scope-set conflicts, and the kind rules that need the referenced scope
// kinds.
func TestSingletonOwnerAndScopeView(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Now()
	mustAddScope(t, s, app.ScopeCmd{ID: "personal", Kind: "personal"}, now)
	p, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice", "personal"), now)
	if err != nil {
		t.Fatal(err)
	}
	if p.OwnerActor != "alice" || len(p.Scopes) != 1 {
		t.Fatalf("settings: %+v", p)
	}
	mustAddScope(t, s, app.ScopeCmd{ID: "client:acme", Kind: "client"}, now)
	scopes, err := s.ProfileScopes(ctx, "personal")
	if err != nil || len(scopes) != 2 {
		t.Fatalf("declared scopes: %v %v", scopes, err)
	}
	_, err = s.AddProfile(ctx, profileCmd("personal", "personal", "bob", "personal"), now)
	wantFamily(t, err, domain.Conflict)
	_, err = s.AddProfile(ctx, profileCmd("second", "personal", "alice", "personal"), now)
	wantFamily(t, err, domain.InvalidInput)
	_, err = s.SetProfileScopes(ctx, "personal", []domain.ScopeID{"personal"}, now)
	wantFamily(t, err, domain.InvalidInput)
	_, err = s.ProfileScopes(ctx, "missing")
	wantFamily(t, err, domain.NotFound)
	if countRows(t, s, "settings") != 1 {
		t.Fatal("more than one settings row")
	}
}

func TestApplyConfigAtomic(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	scopes := []app.ScopeCmd{
		{ID: "personal", Kind: "personal"},
		{ID: "salud", Kind: "personal", Name: "Salud"},
	}
	profiles := []app.ProfileCmd{
		profileCmd("personal", "personal", "alice", "personal", "salud"),
	}

	res, err := s.ApplyConfig(ctx, scopes, profiles, now)
	if err != nil {
		t.Fatalf("ApplyConfig: %v", err)
	}
	if len(res.Scopes) != 2 || res.Scopes[0].Existed || res.Scopes[1].Existed || len(res.Profiles) != 1 || res.Profiles[0].Existed {
		t.Fatalf("first result = %+v, want everything created", res)
	}

	// The same declaration again creates nothing and reports what existed.
	res, err = s.ApplyConfig(ctx, scopes, profiles, now)
	if err != nil {
		t.Fatalf("repeat ApplyConfig: %v", err)
	}
	for _, e := range append(res.Scopes, res.Profiles...) {
		if !e.Existed {
			t.Fatalf("entry %s = created, want it to already exist", e.ID)
		}
	}
	if n := countRows(t, s, "scopes"); n != 2 {
		t.Fatalf("scopes = %d, want 2", n)
	}
	if n := countRows(t, s, "profiles"); n != 1 {
		t.Fatalf("profiles = %d, want 1", n)
	}

	// A conflicting entry rolls the whole batch back: the new scope declared
	// before the conflict must not survive.
	_, err = s.ApplyConfig(ctx,
		[]app.ScopeCmd{{ID: "trabajo", Kind: "work"}},
		[]app.ProfileCmd{profileCmd("personal", "work_client", "alice", "personal")},
		now)
	wantFamily(t, err, domain.InvalidInput)
	if n := countRows(t, s, "scopes"); n != 2 {
		t.Fatalf("scopes after conflict = %d, want 2: the batch rolled back", n)
	}
	owned, err := s.ProfileScopes(ctx, "personal")
	if err != nil {
		t.Fatalf("ProfileScopes: %v", err)
	}
	if len(owned) != 2 {
		t.Fatalf("profile scopes after conflict = %v, want the original two", owned)
	}

	// Empty declarations are refused.
	if _, err := s.ApplyConfig(ctx, nil, profiles, now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("no scopes: got %v, want invalid_input", err)
	}
	if _, err := s.ApplyConfig(ctx, scopes, nil, now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("no profiles: got %v, want invalid_input", err)
	}
}

// TestPersonalProfileCoversAllScopes pins the global planning view: a personal
// profile may cover every declared scope, including work and client scopes.
func TestPersonalProfileCoversAllScopes(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	for _, cmd := range []app.ScopeCmd{
		{ID: "personal", Kind: "personal"},
		{ID: "opensource", Kind: "opensource"},
		{ID: "trabajo", Kind: "work"},
		{ID: "client:prisamedia", Kind: "client"},
	} {
		mustAddScope(t, s, cmd, now)
	}
	got, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice",
		"personal", "opensource", "trabajo", "client:prisamedia"), now)
	if err != nil {
		t.Fatalf("AddProfile: %v", err)
	}
	if len(got.Scopes) != 4 {
		t.Fatalf("scopes = %v, want all four", got.Scopes)
	}
}
