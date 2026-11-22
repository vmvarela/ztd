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
func TestAddProfileRules(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	for _, cmd := range []app.ScopeCmd{
		{ID: "personal", Kind: "personal"},
		{ID: "opensource", Kind: "opensource"},
		{ID: "salud", Kind: "personal", Name: "Salud"},
		{ID: "trabajo", Kind: "work"},
		{ID: "client:prisamedia", Kind: "client"},
	} {
		mustAddScope(t, s, cmd, now)
	}

	created, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice", "personal", "salud"), now)
	if err != nil {
		t.Fatalf("AddProfile: %v", err)
	}
	if created.OwnerActor != "alice" || created.Status != "active" || created.Timezone == "" {
		t.Fatalf("profile = %+v, want alice/active with a timezone", created)
	}
	if len(created.Scopes) != 2 || created.Scopes[0] != "personal" || created.Scopes[1] != "salud" {
		t.Fatalf("scopes = %v, want [personal salud] in declaration order", created.Scopes)
	}

	// The same declaration again changes nothing.
	again, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice", "salud", "personal"), now)
	if err != nil {
		t.Fatalf("re-add: %v", err)
	}
	if len(again.Scopes) != 2 || again.Scopes[0] != "personal" {
		t.Fatalf("re-added scopes = %v, want the stored set", again.Scopes)
	}

	// Another owner, another kind or another scope set is conflict.
	if _, err := s.AddProfile(ctx, profileCmd("personal", "personal", "bob", "personal", "salud"), now); !domain.Of(err, domain.Conflict) {
		t.Fatalf("other owner: got %v, want conflict", err)
	}
	if _, err := s.AddProfile(ctx, profileCmd("personal", "work_client", "alice", "personal"), now); !domain.Of(err, domain.Conflict) {
		t.Fatalf("other kind: got %v, want conflict", err)
	}
	extended, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice", "personal", "opensource"), now)
	if err != nil {
		t.Fatalf("extend scopes: %v", err)
	}
	if len(extended.Scopes) != 3 || extended.Scopes[2] != "opensource" {
		t.Fatalf("extended scopes = %v, want personal, salud, opensource", extended.Scopes)
	}
	if n := countRows(t, s, "profiles"); n != 1 {
		t.Fatalf("profiles = %d, want 1", n)
	}

	// A scope that does not exist is invalid input.
	if _, err := s.AddProfile(ctx, profileCmd("ghost-view", "personal", "alice", "ghost"), now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("missing scope: got %v, want invalid_input", err)
	}
	// A personal profile is the global planning view; it may cover any scope.
	// The work_client rules below still keep a client profile narrow.
	// A work_client profile takes exactly one scope, and it must be a client.
	if _, err := s.AddProfile(ctx, profileCmd("two-scopes", "work_client", "alice", "client:prisamedia", "personal"), now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("two scopes on work_client: got %v, want invalid_input", err)
	}
	if _, err := s.AddProfile(ctx, profileCmd("wrong-kind", "work_client", "alice", "personal"), now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("non-client scope on work_client: got %v, want invalid_input", err)
	}
	client, err := s.AddProfile(ctx, profileCmd("work:prisamedia", "work_client", "alice", "client:prisamedia"), now)
	if err != nil {
		t.Fatalf("work_client profile: %v", err)
	}
	if client.Kind != domain.WorkClientProfile || len(client.Scopes) != 1 {
		t.Fatalf("client profile = %+v", client)
	}
	if n := countRows(t, s, "profiles"); n != 2 {
		t.Fatalf("profiles = %d, want personal and work:prisamedia", n)
	}

	// Profile lookup: an unknown profile is not_found, a known one returns
	// exactly its scopes.
	if _, err := s.ProfileScopes(ctx, "ghost"); !domain.Of(err, domain.NotFound) {
		t.Fatalf("unknown profile: got %v, want not_found", err)
	}
	owned, err := s.ProfileScopes(ctx, "personal")
	if err != nil {
		t.Fatalf("ProfileScopes: %v", err)
	}
	if len(owned) != 3 || owned[0] != "personal" || owned[1] != "salud" || owned[2] != "opensource" {
		t.Fatalf("owned scopes = %v, want [personal salud opensource]", owned)
	}

	list, err := s.ListProfiles(ctx)
	if err != nil {
		t.Fatalf("ListProfiles: %v", err)
	}
	if len(list) != 2 || list[0].ID != "personal" || list[1].ID != "work:prisamedia" {
		t.Fatalf("profiles = %+v, want personal then work:prisamedia", list)
	}
	if len(list[0].Scopes) != 3 || len(list[1].Scopes) != 1 || list[1].Scopes[0] != "client:prisamedia" {
		t.Fatalf("listed scopes = %+v, want each profile's own set", list)
	}
}

// TestApplyConfigAtomic pins the init batch: one transaction, all or
// nothing, idempotent on a repeat, and never deleting what it does not
// declare.
// TestSetProfileScopes replaces the planning view without changing kind or
// owner, and keeps the declaration order used for the primary scope.
func TestSetProfileScopes(t *testing.T) {
	s := openTestStore(t, filepath.Join(t.TempDir(), "ztd.db"))
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	for _, cmd := range []app.ScopeCmd{
		{ID: "personal", Kind: "personal"},
		{ID: "opensource", Kind: "opensource"},
		{ID: "salud", Kind: "personal"},
		{ID: "trabajo", Kind: "work"},
		{ID: "client:prisamedia", Kind: "client"},
	} {
		mustAddScope(t, s, cmd, now)
	}
	if _, err := s.AddProfile(ctx, profileCmd("personal", "personal", "alice", "personal"), now); err != nil {
		t.Fatalf("AddProfile: %v", err)
	}
	if _, err := s.AddProfile(ctx, profileCmd("work:prisamedia", "work_client", "alice", "client:prisamedia"), now); err != nil {
		t.Fatalf("AddProfile(work): %v", err)
	}
	updated, err := s.SetProfileScopes(ctx, "personal", []domain.ScopeID{"personal", "opensource", "salud"}, now)
	if err != nil {
		t.Fatalf("SetProfileScopes: %v", err)
	}
	if updated.Kind != "personal" || updated.OwnerActor != "alice" {
		t.Fatalf("profile = %+v, want kind/owner preserved", updated)
	}
	if len(updated.Scopes) != 3 || updated.Scopes[2] != "salud" {
		t.Fatalf("scopes = %v, want [personal opensource salud]", updated.Scopes)
	}
	if _, err := s.SetProfileScopes(ctx, "ghost", []domain.ScopeID{"personal"}, now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("unknown profile: got %v, want not_found", err)
	}
	if _, err := s.SetProfileScopes(ctx, "personal", []domain.ScopeID{"ghost"}, now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("unknown scope: got %v, want invalid_input", err)
	}
	// A work_client profile cannot be widened to two scopes.
	if _, err := s.SetProfileScopes(ctx, "work:prisamedia", []domain.ScopeID{"client:prisamedia", "personal"}, now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("widened work profile: got %v, want invalid_input", err)
	}
	if _, err := s.SetProfileScopes(ctx, "work:prisamedia", []domain.ScopeID{"client:prisamedia", "trabajo"}, now); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("mixed work profile: got %v, want invalid_input", err)
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
	wantFamily(t, err, domain.Conflict)
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
	got, err := s.AddProfile(ctx, profileCmd("global", "personal", "alice",
		"personal", "opensource", "trabajo", "client:prisamedia"), now)
	if err != nil {
		t.Fatalf("AddProfile: %v", err)
	}
	if len(got.Scopes) != 4 {
		t.Fatalf("scopes = %v, want all four", got.Scopes)
	}
}
