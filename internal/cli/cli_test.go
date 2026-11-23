package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
	"ztd/internal/store"
)

// newTestCLI returns a CLI on a throwaway database. The caller scripts
// `stdin` and `interactive`, so no test ever needs a real terminal.
func newTestCLI(t *testing.T) *CLI {
	t.Helper()
	var out, errOut bytes.Buffer
	return &CLI{
		Out: &out, Err: &errOut, JSON: true,
		DB: filepath.Join(t.TempDir(), "ztd.db"), Actor: "tester",
	}
}

// TestInitInteractive drives the whole prompt flow from an injected reader:
// actor, scope lines and the confirmation. No TTY is involved.
func TestInitInteractive(t *testing.T) {
	var prompts bytes.Buffer
	c := newTestCLI(t)
	c.Err = &prompts
	c.interactive = func() bool { return true }
	c.stdin = strings.NewReader(strings.Join([]string{
		"victor", // actor id, empty line would keep the default
		"id=personal,kind=personal",
		"id=salud,kind=personal,name=Salud",
		"", // end of scopes
		"y",
	}, "\n"))

	if err := c.init(context.Background(), nil); err != nil {
		t.Fatalf("init: %v", err)
	}

	st, err := store.Open(c.DB)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	ctx := context.Background()

	scopes, err := st.ListScopes(ctx)
	if err != nil {
		t.Fatalf("ListScopes: %v", err)
	}
	if len(scopes) != 2 || scopes[0].ID != "personal" || scopes[1].ID != "salud" ||
		scopes[1].Name != "Salud" || scopes[1].Kind != domain.ScopeKindPersonal {
		t.Fatalf("scopes = %+v, want personal and salud named Salud", scopes)
	}

	profiles, err := st.ListProfiles(ctx)
	if err != nil {
		t.Fatalf("ListProfiles: %v", err)
	}
	if len(profiles) != 1 || profiles[0].ID != "personal" || profiles[0].OwnerActor != "victor" {
		t.Fatalf("profiles = %+v, want one personal profile owned by victor", profiles)
	}
	if len(profiles[0].Scopes) != 2 || profiles[0].Scopes[0] != "personal" || profiles[0].Scopes[1] != "salud" {
		t.Fatalf("profile scopes = %v, want [personal salud]", profiles[0].Scopes)
	}

	// The prompts went to stderr, never to the JSON stream.
	if !strings.Contains(prompts.String(), "Apply this configuration?") {
		t.Fatalf("missing confirmation prompt in %q", prompts.String())
	}
}

// TestInitInteractiveWithoutConfirmation proves a declined or truncated
// conversation writes nothing at all.
func TestInitInteractiveWithoutConfirmation(t *testing.T) {
	cases := map[string]string{
		"declined": "tester\nid=personal,kind=personal\n\nn\n",
		"eof":      "tester\nid=personal,kind=personal\n",
	}
	for name, script := range cases {
		t.Run(name, func(t *testing.T) {
			c := newTestCLI(t)
			c.interactive = func() bool { return true }
			c.stdin = strings.NewReader(script)
			err := c.init(context.Background(), nil)
			if !domain.Of(err, domain.InvalidInput) {
				t.Fatalf("init = %v, want invalid_input", err)
			}
			if _, err := os.Stat(c.DB); !os.IsNotExist(err) {
				t.Fatalf("init without confirmation created %s (err %v)", c.DB, err)
			}
		})
	}
}

// TestInitScopeFlagsCreateImplicitProfile pins the flag-driven path: only
// scopes are declared, the implicit personal profile covers all of them, and
// a --profile flag is rejected outright.
func TestInitScopeFlagsCreateImplicitProfile(t *testing.T) {
	c := newTestCLI(t)
	c.interactive = func() bool { return false }
	args := []string{
		"--scope", "id=personal,kind=personal",
		"--scope", "id=opensource,kind=opensource",
	}
	if err := c.init(context.Background(), args); err != nil {
		t.Fatalf("init: %v", err)
	}

	st, err := store.Open(c.DB)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	ctx := context.Background()

	profiles, err := st.ListProfiles(ctx)
	if err != nil {
		t.Fatalf("ListProfiles: %v", err)
	}
	if len(profiles) != 1 || profiles[0].ID != "personal" || profiles[0].OwnerActor != "tester" {
		t.Fatalf("profiles = %+v, want one personal profile owned by tester", profiles)
	}
	want := []domain.ScopeID{"personal", "opensource"}
	if len(profiles[0].Scopes) != len(want) {
		t.Fatalf("profile scopes = %v, want %v", profiles[0].Scopes, want)
	}
	for i, sc := range want {
		if profiles[0].Scopes[i] != sc {
			t.Fatalf("profile scopes = %v, want %v (in declaration order)", profiles[0].Scopes, want)
		}
	}

	// The same declaration again is idempotent, not a conflict.
	if err := c.init(context.Background(), args); err != nil {
		t.Fatalf("repeat init: %v", err)
	}

	// There is no way to pass a profile declaration any more.
	err = c.init(context.Background(), []string{"--profile", "id=personal,kind=personal,scopes=personal"})
	if !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("init --profile = %v, want invalid_input", err)
	}
}

// TestInitWithoutTerminalOrFlags pins the scripted path: no prompt, no hang,
// no database.
func TestInitWithoutTerminalOrFlags(t *testing.T) {
	c := newTestCLI(t)
	c.interactive = func() bool { return false }
	err := c.init(context.Background(), nil)
	if !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("init = %v, want invalid_input", err)
	}
	if _, err := os.Stat(c.DB); !os.IsNotExist(err) {
		t.Fatalf("init without declarations created %s (err %v)", c.DB, err)
	}
}

// seedConfig declares the scopes and profiles the binding tests need. The
// profile covers the client scope too, so the default view has to exclude it.
func seedConfig(t *testing.T, st *store.Store) {
	t.Helper()
	_, err := st.ApplyConfig(context.Background(),
		[]app.ScopeCmd{
			{ID: "personal", Kind: "personal"},
			{ID: "opensource", Kind: "opensource"},
			{ID: "salud", Kind: "personal", Name: "Salud"},
			{ID: "trabajo", Kind: "work"},
			{ID: "client:prisamedia", Kind: "client"},
		},
		[]app.ProfileCmd{{
			ID: "personal", Kind: "personal", Actor: "tester",
			Scopes: []string{"personal", "opensource", "salud", "client:prisamedia"},
		}},
		time.Now().UTC())
	if err != nil {
		t.Fatalf("ApplyConfig: %v", err)
	}
}

// TestBindingResolvesImplicitProfile pins profile resolution: the scopes come
// from the implicit personal profile's profile_scopes, a database without it
// is not_found, and an explicit --scope cannot reach outside the profile.
func TestBindingResolvesImplicitProfile(t *testing.T) {
	unsetScopeEnv(t)
	c := newTestCLI(t)
	st, err := store.Open(c.DB)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	svc := app.New(st)
	ctx := context.Background()

	// Nothing declared yet: the implicit profile does not exist.
	if _, err := c.binding(ctx, svc, nil); !domain.Of(err, domain.NotFound) {
		t.Fatalf("missing profile: got %v, want not_found", err)
	}

	seedConfig(t, st)

	// The default view keeps the personal scopes and drops the client one.
	b, err := c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("binding: %v", err)
	}
	if b.Profile != implicitProfile {
		t.Fatalf("profile = %q, want %q", b.Profile, implicitProfile)
	}
	want := []domain.ScopeID{"personal", "opensource", "salud"}
	if len(b.Scopes) != len(want) {
		t.Fatalf("scopes = %v, want %v", b.Scopes, want)
	}
	for i, sc := range want {
		if b.Scopes[i] != sc {
			t.Fatalf("scopes = %v, want %v (in declaration order)", b.Scopes, want)
		}
	}

	// An explicit scope inside the profile narrows the binding to it.
	narrow, err := c.binding(ctx, svc, []string{"salud"})
	if err != nil {
		t.Fatalf("binding salud: %v", err)
	}
	if len(narrow.Scopes) != 1 || narrow.Scopes[0] != "salud" {
		t.Fatalf("narrowed scopes = %v, want [salud]", narrow.Scopes)
	}

	// A scope the profile does not cover is refused, even though it exists.
	if _, err := c.binding(ctx, svc, []string{"trabajo"}); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("foreign scope: got %v, want scope_denied", err)
	}
}

// unsetScopeEnv clears ZTD_SCOPES for one test and restores whatever the
// ambient environment held, so a shell export cannot change the default.
func unsetScopeEnv(t *testing.T) {
	t.Helper()
	old, had := os.LookupEnv("ZTD_SCOPES")
	if err := os.Unsetenv("ZTD_SCOPES"); err != nil {
		t.Fatalf("unset ZTD_SCOPES: %v", err)
	}
	t.Cleanup(func() {
		if had {
			_ = os.Setenv("ZTD_SCOPES", old)
		} else {
			_ = os.Unsetenv("ZTD_SCOPES")
		}
	})
}

// bindingFixture is a CLI on a throwaway database seeded with seedConfig,
// with a clean ZTD_SCOPES so the precedence tests start from the default.
func bindingFixture(t *testing.T) (*CLI, context.Context, *app.Service) {
	t.Helper()
	c := newTestCLI(t)
	st, err := store.Open(c.DB)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	seedConfig(t, st)
	t.Cleanup(func() { st.Close() })
	unsetScopeEnv(t)
	return c, context.Background(), app.New(st)
}

// wantScopes asserts the exact scope list of a binding.
func wantScopes(t *testing.T, got []domain.ScopeID, want ...domain.ScopeID) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("scopes = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("scopes = %v, want %v (in order)", got, want)
		}
	}
}

// defaultViewWant is the default binding of seedConfig: every profile scope
// except the client one.
var defaultViewWant = []domain.ScopeID{"personal", "opensource", "salud"}

// TestBindingDefaultView pins the default: the profile's scopes without the
// client and work ones, and a client-only profile keeps its scope instead of
// binding nothing.
func TestBindingDefaultView(t *testing.T) {
	c, ctx, svc := bindingFixture(t)

	b, err := c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("binding: %v", err)
	}
	wantScopes(t, b.Scopes, defaultViewWant...)

	// A profile that only covers a client scope falls back to it.
	if _, err := svc.SetProfileScopes(ctx, implicitProfile, []domain.ScopeID{"client:prisamedia"}); err != nil {
		t.Fatalf("SetProfileScopes: %v", err)
	}
	clientOnly, err := c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("client-only binding: %v", err)
	}
	wantScopes(t, clientOnly.Scopes, "client:prisamedia")
}

// TestBindingScopeEnv pins ZTD_SCOPES: it narrows like an explicit choice,
// an unknown scope is scope_denied and an empty token is invalid_input.
func TestBindingScopeEnv(t *testing.T) {
	c, ctx, svc := bindingFixture(t)

	t.Setenv("ZTD_SCOPES", "client:prisamedia")
	b, err := c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("env client: %v", err)
	}
	wantScopes(t, b.Scopes, "client:prisamedia")

	t.Setenv("ZTD_SCOPES", " personal , opensource ")
	b, err = c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("env pair: %v", err)
	}
	wantScopes(t, b.Scopes, "personal", "opensource")

	t.Setenv("ZTD_SCOPES", "ghost")
	if _, err := c.binding(ctx, svc, nil); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("env ghost: got %v, want scope_denied", err)
	}

	t.Setenv("ZTD_SCOPES", "personal,,opensource")
	if _, err := c.binding(ctx, svc, nil); !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("env empty token: got %v, want invalid_input", err)
	}
}

// inHintDir writes .ztd.json into a fresh directory and makes it the working
// directory; the original directory is restored when the test ends.
func inHintDir(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	if body != "" {
		if err := os.WriteFile(filepath.Join(dir, ".ztd.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(old); err != nil {
			t.Errorf("restore working directory: %v", err)
		}
	})
}

// TestBindingHintSelectsScope pins the routing hint: it narrows to one scope
// when it resolves, and a missing, malformed or unknown hint falls back to
// the default view instead of failing.
func TestBindingHintSelectsScope(t *testing.T) {
	c, ctx, svc := bindingFixture(t)

	for _, tc := range []struct {
		name string
		body string
		want []domain.ScopeID
	}{
		{"client", `{"client":"prisamedia"}`, []domain.ScopeID{"client:prisamedia"}},
		{"context", `{"context":"opensource"}`, []domain.ScopeID{"opensource"}},
		{"unknown context falls back to client", `{"context":"familia","client":"prisamedia"}`,
			[]domain.ScopeID{"client:prisamedia"}},
		{"malformed", `{not json`, defaultViewWant},
		{"unknown scope", `{"context":"ghost","client":"nobody"}`, defaultViewWant},
		{"wrong field type", `{"context":5}`, defaultViewWant},
	} {
		t.Run(tc.name, func(t *testing.T) {
			inHintDir(t, tc.body)
			b, err := c.binding(ctx, svc, nil)
			if err != nil {
				t.Fatalf("binding: %v", err)
			}
			wantScopes(t, b.Scopes, tc.want...)
		})
	}

	// No file at all: the default applies.
	inHintDir(t, "")
	b, err := c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("binding without hint: %v", err)
	}
	wantScopes(t, b.Scopes, defaultViewWant...)
}

// TestBindingPrecedence pins the order: --scope beats ZTD_SCOPES, and
// ZTD_SCOPES beats the .ztd.json hint of the directory.
func TestBindingPrecedence(t *testing.T) {
	c, ctx, svc := bindingFixture(t)
	inHintDir(t, `{"client":"prisamedia"}`)

	// An explicit scope wins over the hint.
	b, err := c.binding(ctx, svc, []string{"salud"})
	if err != nil {
		t.Fatalf("explicit over hint: %v", err)
	}
	wantScopes(t, b.Scopes, "salud")

	// ZTD_SCOPES wins over the hint.
	t.Setenv("ZTD_SCOPES", "personal")
	b, err = c.binding(ctx, svc, nil)
	if err != nil {
		t.Fatalf("env over hint: %v", err)
	}
	wantScopes(t, b.Scopes, "personal")

	// An explicit scope wins over ZTD_SCOPES too.
	b, err = c.binding(ctx, svc, []string{"opensource"})
	if err != nil {
		t.Fatalf("explicit over env: %v", err)
	}
	wantScopes(t, b.Scopes, "opensource")
}

// TestStatusEffectiveScopes pins the report: scopes lists every declared
// scope, effective_scopes is the binding a command gets with no explicit
// --scope, and the raw .ztd.json hint stays in binding.
func TestStatusEffectiveScopes(t *testing.T) {
	c := newTestCLI(t)
	st, err := store.Open(c.DB)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	seedConfig(t, st)
	if err := st.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	unsetScopeEnv(t)

	var out bytes.Buffer
	c.Out = &out
	if err := c.status(context.Background(), nil); err != nil {
		t.Fatalf("status: %v", err)
	}
	var env struct {
		OK   bool       `json:"ok"`
		Data statusData `json:"data"`
	}
	if err := json.Unmarshal(out.Bytes(), &env); err != nil {
		t.Fatalf("decode %q: %v", out.String(), err)
	}
	if !env.OK {
		t.Fatalf("status envelope = %+v, want ok", env)
	}
	wantScopes(t, scopeIDs(env.Data.EffectiveScopes), defaultViewWant...)
	declared := []string{"client:prisamedia", "opensource", "personal", "salud", "trabajo"}
	if len(env.Data.Scopes) != len(declared) {
		t.Fatalf("declared scopes = %v, want %v", env.Data.Scopes, declared)
	}
	for i, id := range declared {
		if env.Data.Scopes[i] != id {
			t.Fatalf("declared scopes = %v, want %v", env.Data.Scopes, declared)
		}
	}
	if env.Data.Binding != nil {
		t.Fatalf("binding = %+v, want null without .ztd.json", env.Data.Binding)
	}
}

// TestCommandsWithoutProfile drives the dispatcher: no command takes a
// --profile flag, planning commands resolve the implicit profile, and the
// removed profile subcommands are unknown.
func TestCommandsWithoutProfile(t *testing.T) {
	c := newTestCLI(t)
	c.interactive = func() bool { return false }
	if err := c.init(context.Background(), []string{
		"--scope", "id=personal,kind=personal",
		"--scope", "id=opensource,kind=opensource",
	}); err != nil {
		t.Fatalf("init: %v", err)
	}
	ctx := context.Background()

	if err := c.run(ctx, "capture", []string{"buy milk"}); err != nil {
		t.Fatalf("capture without flags: %v", err)
	}
	// An explicit scope outside the implicit profile is refused.
	err := c.run(ctx, "capture", []string{"--scope", "ghost", "x"})
	if !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("capture --scope ghost: got %v, want scope_denied", err)
	}
	// --profile is not a flag any more.
	err = c.run(ctx, "capture", []string{"--profile", "personal", "x"})
	if !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("capture --profile: got %v, want invalid_input", err)
	}
	// The profile subcommands are gone from the dispatcher.
	err = c.run(ctx, "profile", []string{"list"})
	if !domain.Of(err, domain.InvalidInput) {
		t.Fatalf("profile list: got %v, want invalid_input", err)
	}
}

// TestReadBindingHint pins the routing hint contract: a valid object is
// returned as-is, everything else comes back as null plus a warning.
func TestReadBindingHint(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}

	got, warning := readBindingHint(filepath.Join(dir, ".ztd.json"))
	if got != nil || !strings.Contains(warning, "not found") {
		t.Fatalf("missing file = %v/%q, want null with a warning", got, warning)
	}

	path := write("valid.json", `{"context":"trabajo","client":"prisamedia"}`)
	obj, warning := readBindingHint(path)
	if warning != "" {
		t.Fatalf("valid object warning = %q, want none", warning)
	}
	m, ok := obj.(map[string]any)
	if !ok || m["context"] != "trabajo" || m["client"] != "prisamedia" {
		t.Fatalf("valid object = %#v, want the parsed contents", obj)
	}

	for name, body := range map[string]string{
		"malformed": `{"context": `,
		"array":     `["personal"]`,
		"null":      `null`,
		"string":    `"personal"`,
	} {
		t.Run(name, func(t *testing.T) {
			got, warning := readBindingHint(write(name+".json", body))
			if got != nil || warning == "" {
				t.Fatalf("%s = %v/%q, want null with a warning", name, got, warning)
			}
		})
	}
}

// TestSplitMoveArgs pins the argument split that lets the documented
// `move ID LIST --flag value` order work alongside flags-first calls.
func TestSplitMoveArgs(t *testing.T) {
	cases := []struct {
		args       []string
		flagArgs   []string
		positional []string
	}{
		{
			args:       []string{"T-1", "waiting", "--waiting-on", "ana", "--field", "k:v"},
			flagArgs:   []string{"--waiting-on", "ana", "--field", "k:v"},
			positional: []string{"T-1", "waiting"},
		},
		{
			args:       []string{"--key", "k1", "--expected", "2", "T-1", "next"},
			flagArgs:   []string{"--key", "k1", "--expected", "2"},
			positional: []string{"T-1", "next"},
		},
		{
			args:       []string{"--text=renamed", "T-1", "someday"},
			flagArgs:   []string{"--text=renamed"},
			positional: []string{"T-1", "someday"},
		},
		{
			args:       []string{"T-1", "archive", "--resolution", "done at last"},
			flagArgs:   []string{"--resolution", "done at last"},
			positional: []string{"T-1", "archive"},
		},
	}
	for _, tc := range cases {
		flags, positional := splitMoveArgs(tc.args)
		if strings.Join(flags, "|") != strings.Join(tc.flagArgs, "|") {
			t.Errorf("splitMoveArgs(%v) flags = %v, want %v", tc.args, flags, tc.flagArgs)
		}
		if strings.Join(positional, "|") != strings.Join(tc.positional, "|") {
			t.Errorf("splitMoveArgs(%v) positional = %v, want %v", tc.args, positional, tc.positional)
		}
	}
}

// TestHelp pins the top-level help: --help/-h/help print the usage and exit
// 0, while a bare invocation keeps exiting 2 with the same text.
func TestHelp(t *testing.T) {
	for _, arg := range []string{"--help", "-h", "help"} {
		var out, errOut bytes.Buffer
		if code := Main([]string{arg}, &out, &errOut); code != 0 {
			t.Fatalf("Main(%q) exit = %d, want 0", arg, code)
		}
		if !strings.Contains(out.String(), "ztd — local ZTD") {
			t.Fatalf("Main(%q) output = %q, want the usage", arg, out.String())
		}
		if !strings.Contains(out.String(), "source delete --id ID") {
			t.Fatalf("Main(%q) usage lacks source delete --id ID", arg)
		}
	}
	var out, errOut bytes.Buffer
	if code := Main(nil, &out, &errOut); code != 2 {
		t.Fatalf("bare Main exit = %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "ztd — local ZTD") {
		t.Fatalf("bare Main output = %q, want the usage on stderr", errOut.String())
	}
}
