package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mattn/go-isatty"

	"ztd"
	"ztd/internal/app"
	"ztd/internal/domain"
	"ztd/internal/install"
	"ztd/internal/mcpserver"
	"ztd/internal/store"
)

var Version = "0.1.0-dev"

type CLI struct {
	Out  io.Writer
	Err  io.Writer
	JSON bool
	DB   string
	// Actor is the default owner actor; commands may override it with
	// --actor, and init asks for it on a terminal.
	Actor string

	// data rides along in the JSON failure envelope when a command reports a
	// structured result and still fails, so `doc lint --json` keeps the
	// findings instead of only the counts.
	data any

	// stdin and interactive make init testable without a real terminal: a
	// nil value means os.Stdin and a real TTY check, a test injects a
	// scripted reader and a fixed answer instead.
	stdin       io.Reader
	interactive func() bool
}

type envelope struct {
	OK      bool        `json:"ok"`
	Command string      `json:"command,omitempty"`
	Data    any         `json:"data,omitempty"`
	Error   *errorShape `json:"error,omitempty"`
}

type errorShape struct {
	Family string `json:"family"`
	Detail string `json:"detail"`
}

func Main(args []string, stdout, stderr io.Writer) int {
	c := &CLI{Out: stdout, Err: stderr, Actor: defaultActor()}
	args, err := c.parseGlobals(args)
	if err != nil {
		c.fail("", err)
		return 1
	}
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	ctx := context.Background()
	if err := c.run(ctx, args[0], args[1:]); err != nil {
		c.fail(args[0], err)
		return 1
	}
	return 0
}

func defaultActor() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	return "operator"
}

// isTerminal reports whether f is a terminal. A real TTY check matters
// because a redirected stdin is still a readable character device: init must
// not read a prompt from an empty or piped stream.
func isTerminal(f *os.File) bool {
	return isatty.IsTerminal(f.Fd()) || isatty.IsCygwinTerminal(f.Fd())
}

func DefaultDB() string {
	if p := os.Getenv("ZTD_DB"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "ztd.db"
	}
	return filepath.Join(home, ".ztd", "ztd.db")
}

// DefaultSourcesPath is the user-owned source configuration. It is plain
// data: the host resolves provider connections, ZTD only records identities.
func DefaultSourcesPath() string {
	if p := os.Getenv("ZTD_SOURCES"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "sources.json"
	}
	return filepath.Join(home, ".ztd", "sources.json")
}

func (c *CLI) parseGlobals(args []string) ([]string, error) {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			c.JSON = true
		case "--db":
			i++
			if i >= len(args) {
				return nil, domain.Invalid("--db needs a value")
			}
			c.DB = args[i]
		case "--actor":
			i++
			if i >= len(args) {
				return nil, domain.Invalid("--actor needs a value")
			}
			c.Actor = args[i]
		default:
			out = append(out, args[i])
		}
	}
	if c.DB == "" {
		c.DB = DefaultDB()
	}
	return out, nil
}

func (c *CLI) succeed(command string, data any) {
	if c.JSON {
		_ = json.NewEncoder(c.Out).Encode(envelope{OK: true, Command: command, Data: data})
		return
	}
	switch v := data.(type) {
	case nil:
		fmt.Fprintln(c.Out, "ok")
	case string:
		fmt.Fprintln(c.Out, v)
	default:
		b, _ := json.MarshalIndent(v, "", "  ")
		fmt.Fprintln(c.Out, string(b))
	}
}

func (c *CLI) fail(command string, err error) {
	family := domain.FamilyOf(err)
	detail := err.Error()
	var de *domain.Error
	if errors.As(err, &de) {
		detail = de.Detail
	}
	if c.JSON {
		_ = json.NewEncoder(c.Out).Encode(envelope{OK: false, Command: command, Data: c.data, Error: &errorShape{Family: string(family), Detail: detail}})
		return
	}
	fmt.Fprintf(c.Err, "%s: %s\n", family, detail)
}

func (c *CLI) open() (*store.Store, *app.Service, error) {
	if err := os.MkdirAll(filepath.Dir(c.DB), 0o755); err != nil {
		return nil, nil, domain.NewError(domain.IOError, "create database directory: %v", err)
	}
	st, err := store.Open(c.DB)
	if err != nil {
		return nil, nil, err
	}
	return st, app.New(st), nil
}

// operatorProfile is the sentinel binding for operator commands (sources and
// scope administration). It is never persisted: it is not a planning
// profile, so it owns no goal, plan or review.
const operatorProfile = "operator"

// implicitProfile is the single planning profile. The user never names it:
// init creates it over the declared scopes and every command resolves it.
const implicitProfile = "personal"

// binding resolves the implicit planning profile into a scope binding. The
// scopes come from profile_scopes: a profile that does not exist is
// not_found, and a selected scope must belong to the profile instead of
// widening it. resolveScopes picks which of the profile's scopes apply.
func (c *CLI) binding(ctx context.Context, svc *app.Service, scopes []string) (domain.ScopeBinding, error) {
	owned, err := svc.Repo.ProfileScopes(ctx, implicitProfile)
	if err != nil {
		if domain.Of(err, domain.NotFound) {
			return domain.ScopeBinding{}, domain.NewError(domain.NotFound,
				"planning profile %s not found: run `ztd init` first", implicitProfile)
		}
		return domain.ScopeBinding{}, err
	}
	declared, err := svc.ListScopes(ctx)
	if err != nil {
		return domain.ScopeBinding{}, err
	}
	ids, err := resolveScopes(owned, declared, scopes)
	if err != nil {
		return domain.ScopeBinding{}, err
	}
	b := domain.ScopeBinding{
		Profile: implicitProfile, Actor: domain.ActorID(c.Actor), Scopes: ids,
	}
	if err := b.Validate(); err != nil {
		return domain.ScopeBinding{}, err
	}
	return b, nil
}

// resolveScopes picks the scopes of one binding for the host, in this
// precedence: explicit --scope, then ZTD_SCOPES, then the .ztd.json routing
// hint of the working directory, then the default view. The result narrows
// one shared store: it never splits or duplicates tasks, and no model
// argument can widen it.
func resolveScopes(owned []domain.ScopeID, declared []domain.Scope, explicit []string) ([]domain.ScopeID, error) {
	if len(explicit) > 0 {
		return narrowToProfile(owned, explicit)
	}
	if v, ok := os.LookupEnv("ZTD_SCOPES"); ok {
		list, err := splitScopeList(v)
		if err != nil {
			return nil, err
		}
		return narrowToProfile(owned, list)
	}
	hint, _ := readBindingHint(".ztd.json")
	// The hint may select a scope, but only one the profile covers: a
	// directory hint can never widen the binding beyond profile_scopes.
	if id, ok := hintScope(hint, declared); ok && covers(owned, id) {
		return []domain.ScopeID{id}, nil
	}
	return defaultView(owned, declared), nil
}

// narrowToProfile keeps the requested scope ids that the profile covers; a
// scope outside it is scope_denied, so neither a flag nor the host
// configuration can widen the binding beyond the profile.
func narrowToProfile(owned []domain.ScopeID, want []string) ([]domain.ScopeID, error) {
	allowed := make(map[domain.ScopeID]bool, len(owned))
	for _, sc := range owned {
		allowed[sc] = true
	}
	out := make([]domain.ScopeID, 0, len(want))
	for _, sc := range want {
		if !allowed[domain.ScopeID(sc)] {
			return nil, domain.NewError(domain.ScopeDenied,
				"scope %s is not covered by the planning profile", sc)
		}
		out = append(out, domain.ScopeID(sc))
	}
	return out, nil
}

// splitScopeList parses a comma-separated ZTD_SCOPES value. Spaces around an
// id are trimmed; an empty token is a configuration error, not a silent skip.
func splitScopeList(v string) ([]string, error) {
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			return nil, domain.Invalid("ZTD_SCOPES must be a comma-separated list of scope ids, got %q", v)
		}
		out = append(out, p)
	}
	return out, nil
}

// hintScope resolves a parsed .ztd.json routing hint to one scope, in the
// order of check --bindings: context, then client:<client>, then personal
// when the hint names no scope at all. ok is false for a missing, malformed
// or unknown hint: the caller falls back to the default view, so a bad hint
// never fails a command.
func hintScope(hint any, declared []domain.Scope) (domain.ScopeID, bool) {
	obj, ok := hint.(map[string]any)
	if !ok {
		return "", false
	}
	known := make(map[domain.ScopeID]bool, len(declared))
	for _, sc := range declared {
		known[sc.ID] = true
	}
	// A field that is present but not a string makes the whole hint unusable.
	str := func(key string) (string, bool) {
		v, present := obj[key]
		if !present {
			return "", true
		}
		s, isString := v.(string)
		if !isString {
			return "", false
		}
		return strings.TrimSpace(s), true
	}
	contextVal, ok := str("context")
	if !ok {
		return "", false
	}
	clientVal, ok := str("client")
	if !ok {
		return "", false
	}
	switch {
	case contextVal != "" && known[domain.ScopeID(contextVal)]:
		return domain.ScopeID(contextVal), true
	case clientVal != "" && known[domain.ScopeID("client:"+clientVal)]:
		return domain.ScopeID("client:" + clientVal), true
	case contextVal == "" && clientVal == "" && known["personal"]:
		// The hint names no scope: personal, like check --bindings.
		return "personal", true
	default:
		// The hint names a scope that does not resolve: ignore it.
		return "", false
	}
}

// defaultView is the binding of a command with no explicit scope: the
// profile's scopes without the client and work ones, so a personal session
// never returns client work. A profile that only covers client or work
// scopes keeps all of them, so the binding is never empty.
func defaultView(owned []domain.ScopeID, declared []domain.Scope) []domain.ScopeID {
	kind := make(map[domain.ScopeID]domain.ScopeKind, len(declared))
	for _, sc := range declared {
		kind[sc.ID] = sc.Kind
	}
	out := make([]domain.ScopeID, 0, len(owned))
	for _, id := range owned {
		if isClientOrWork(id, kind[id]) {
			continue
		}
		out = append(out, id)
	}
	if len(out) == 0 {
		return owned
	}
	return out
}

// isClientOrWork reports whether a scope stays out of the default view: a
// client or work scope by kind, by the client: id prefix, or the plain work id.
func isClientOrWork(id domain.ScopeID, kind domain.ScopeKind) bool {
	return kind == domain.ScopeKindClient || kind == domain.ScopeKindWork ||
		strings.HasPrefix(string(id), "client:") || id == "work"
}

// covers reports whether a profile owns one scope.
func covers(owned []domain.ScopeID, id domain.ScopeID) bool {
	for _, sc := range owned {
		if sc == id {
			return true
		}
	}
	return false
}

// bound opens the database and resolves the implicit profile binding in one
// step, so a failed resolution never leaves a handle open.
func (c *CLI) bound(ctx context.Context, scopes []string) (*store.Store, *app.Service, domain.ScopeBinding, error) {
	st, svc, err := c.open()
	if err != nil {
		return nil, nil, domain.ScopeBinding{}, err
	}
	b, err := c.binding(ctx, svc, scopes)
	if err != nil {
		_ = st.Close()
		return nil, nil, domain.ScopeBinding{}, err
	}
	return st, svc, b, nil
}

// oneScope turns a single --scope flag into a binding scope list.
func oneScope(scope string) []string {
	if scope == "" {
		return nil
	}
	return []string{scope}
}

func scopeIDs(ids []string) []domain.ScopeID {
	out := make([]domain.ScopeID, 0, len(ids))
	for _, id := range ids {
		out = append(out, domain.ScopeID(id))
	}
	return out
}

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func (c *CLI) run(ctx context.Context, command string, args []string) error {
	switch command {
	case "version", "--version", "-v":
		c.succeed("version", map[string]string{"version": Version})
		return nil
	case "--help", "-h", "help":
		// The same text a bare invocation prints, on explicit request.
		if c.JSON {
			c.succeed("help", usage)
		} else {
			fmt.Fprintln(c.Out, usage)
		}
		return nil
	case "init":
		return c.init(ctx, args)
	case "install":
		return c.install(args)
	case "scope":
		return c.scope(ctx, args)
	case "capture":
		return c.capture(ctx, args)
	case "inbox":
		return c.inbox(ctx, args)
	case "process":
		return c.process(ctx, args)
	case "show":
		return c.show(ctx, args)
	case "find":
		return c.find(ctx, args)
	case "list":
		return c.list(ctx, args)
	case "move":
		return c.move(ctx, args)
	case "status":
		return c.status(ctx, args)
	case "due":
		// Alias for `routines due`.
		return c.routines(ctx, append([]string{"due"}, args...))
	case "routine":
		// Alias for `routines done ID`.
		if len(args) == 0 || args[0] != "done" {
			return domain.Invalid("usage: routine done [flags] <routine-id>")
		}
		return c.routines(ctx, append([]string{"done"}, args[1:]...))
	case "prepare":
		return c.prepare(ctx, args)
	case "goal":
		return c.goal(ctx, args)
	case "plan":
		return c.plan(ctx, args)
	case "focus":
		return c.focus(ctx, args)
	case "review":
		return c.review(ctx, args)
	case "source":
		return c.source(ctx, args)
	case "context":
		return c.context(ctx, args)
	case "doc":
		return c.doc(ctx, args)
	case "project":
		return c.project(ctx, args)
	case "routines":
		return c.routines(ctx, args)
	case "migrate":
		return c.migrate(ctx, args)
	case "export":
		return c.export(ctx, args)
	case "restore":
		return c.restore(ctx, args)
	case "snapshot":
		return c.snapshot(ctx, args)
	case "check":
		return c.check(ctx, args)
	case "recover":
		return c.recover(args)
	case "mcp":
		return c.mcp(ctx, args)
	default:
		return domain.Invalid("unknown command %q (see usage)", command)
	}
}

// init declares scopes. On a terminal it asks for them; with flags it takes
// them as given; with neither it fails immediately instead of inventing
// defaults. The implicit personal profile covers every declared scope in the
// same batch. It never drops what an existing database already holds, and a
// conflicting entry rolls the whole batch back.
func (c *CLI) init(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var scopeDecls stringList
	fs.Var(&scopeDecls, "scope", "scope declaration id=...,kind=... (repeatable)")
	actor := fs.String("actor", c.Actor, "owner actor")
	nonInteractive := fs.Bool("non-interactive", false, "never prompt, even on a terminal")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *actor != "" {
		c.Actor = *actor
	}
	// Explicit flags are the stable path: they skip the prompt even on a
	// terminal. Only a bare `init` on a terminal asks.
	if !*nonInteractive && len(scopeDecls) == 0 && c.initIsInteractive() {
		actor, scopes, err := readInitDeclaration(c.initInput(), c.Err, c.Actor)
		if err != nil {
			return err
		}
		return c.applyConfig(ctx, actor, scopes)
	}
	// Scripts get no prompt: an empty stdin that is not a terminal must not
	// hang waiting for input that can never arrive.
	scopes := make([]app.ScopeCmd, 0, len(scopeDecls))
	for _, decl := range scopeDecls {
		cmd, err := parseScopeDecl(decl)
		if err != nil {
			return err
		}
		scopes = append(scopes, cmd)
	}
	return c.applyConfig(ctx, c.Actor, scopes)
}

// applyConfig validates the whole declaration before the database exists, so
// a typo never leaves an empty file behind, then applies it in one
// transaction: the scopes and the implicit personal profile that covers all
// of them land together or not at all.
func (c *CLI) applyConfig(ctx context.Context, actor string, scopes []app.ScopeCmd) error {
	if len(scopes) == 0 {
		return domain.Invalid("init needs at least one scope declaration (pass --scope id=...,kind=...)")
	}
	if actor == "" {
		return domain.Invalid("actor is required")
	}
	c.Actor = actor
	ids := make([]string, 0, len(scopes))
	for _, s := range scopes {
		ids = append(ids, s.ID)
	}
	profiles := []app.ProfileCmd{{
		ID: implicitProfile, Kind: string(domain.PersonalProfile),
		Actor: actor, Scopes: ids,
	}}
	st, svc, err := c.open() // migrations run here
	if err != nil {
		return err
	}
	defer st.Close()
	res, err := svc.ApplyConfig(ctx, scopes, profiles)
	if err != nil {
		return err
	}
	c.succeed("init", map[string]any{
		"database": c.DB, "actor": actor, "scopes": res.Scopes, "profiles": res.Profiles,
	})
	return nil
}

// initIsInteractive reports whether init should prompt.
func (c *CLI) initIsInteractive() bool {
	if c.interactive != nil {
		return c.interactive()
	}
	return isTerminal(os.Stdin)
}

// initInput is the stream interactive init reads.
func (c *CLI) initInput() io.Reader {
	if c.stdin != nil {
		return c.stdin
	}
	return os.Stdin
}

// readInitDeclaration walks the interactive setup: the actor id, one scope
// declaration per line, a summary and a confirmation. It reads from in and
// writes prompts to out, so a test can script it without a terminal. It
// returns only after an explicit yes, and it writes nothing itself.
func readInitDeclaration(in io.Reader, out io.Writer, defaultActor string) (string, []app.ScopeCmd, error) {
	sc := bufio.NewScanner(in)
	prompt := func(format string, args ...any) (string, error) {
		fmt.Fprintf(out, format, args...)
		if !sc.Scan() {
			if err := sc.Err(); err != nil {
				return "", domain.NewError(domain.IOError, "read init input: %v", err)
			}
			return "", domain.Invalid("init cancelled: input ended before confirmation; nothing was written")
		}
		return strings.TrimSpace(sc.Text()), nil
	}

	answer, err := prompt("Actor id [%s]: ", defaultActor)
	if err != nil {
		return "", nil, err
	}
	actor := answer
	if actor == "" {
		actor = defaultActor
	}

	fmt.Fprintln(out, "Scopes, one declaration per line (id=...,kind=...,name=...); empty line finishes:")
	var scopes []app.ScopeCmd
	for {
		line, err := prompt("  > ")
		if err != nil {
			return "", nil, err
		}
		if line == "" {
			break
		}
		cmd, err := parseScopeDecl(line)
		if err != nil {
			return "", nil, err
		}
		scopes = append(scopes, cmd)
	}

	if len(scopes) == 0 {
		return "", nil, domain.Invalid("init needs at least one scope")
	}

	fmt.Fprintf(out, "actor: %s\nscopes:\n", actor)
	for _, s := range scopes {
		name := s.Name
		if name == "" {
			name = s.ID
		}
		fmt.Fprintf(out, "  %s kind=%s name=%s\n", s.ID, s.Kind, name)
	}
	confirm, err := prompt("Apply this configuration? [y/N]: ")
	if err != nil {
		return "", nil, err
	}
	switch strings.ToLower(confirm) {
	case "y", "yes":
	default:
		return "", nil, domain.Invalid("init cancelled: nothing was written")
	}
	return actor, scopes, nil
}

// parseDecl parses one comma-separated key=value declaration. A value cannot
// contain the separators, so an id like work:prisamedia survives intact and a
// malformed field is rejected instead of guessed.
func parseDecl(kind, raw string) (map[string]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, domain.Invalid("%s declaration is empty", kind)
	}
	fields := make(map[string]string)
	for _, part := range strings.Split(raw, ",") {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 || strings.TrimSpace(kv[0]) == "" || strings.TrimSpace(kv[1]) == "" {
			return nil, domain.Invalid("%s declaration %q: every field must be key=value", kind, raw)
		}
		key, value := strings.TrimSpace(kv[0]), strings.TrimSpace(kv[1])
		if _, dup := fields[key]; dup {
			return nil, domain.Invalid("%s declaration %q: duplicate field %q", kind, raw, key)
		}
		fields[key] = value
	}
	return fields, nil
}

func allowedFields(raw, kind string, fields map[string]string, allowed ...string) error {
	for key := range fields {
		ok := false
		for _, a := range allowed {
			if key == a {
				ok = true
				break
			}
		}
		if !ok {
			return domain.Invalid("%s declaration %q: unknown field %q", kind, raw, key)
		}
	}
	return nil
}

// parseScopeDecl reads one scope declaration: id=...,kind=...,name=...
func parseScopeDecl(raw string) (app.ScopeCmd, error) {
	fields, err := parseDecl("scope", raw)
	if err != nil {
		return app.ScopeCmd{}, err
	}
	if err := allowedFields(raw, "scope", fields, "id", "kind", "name"); err != nil {
		return app.ScopeCmd{}, err
	}
	cmd := app.ScopeCmd{ID: fields["id"], Kind: fields["kind"], Name: fields["name"]}
	if err := app.ValidateScopeCmd(cmd); err != nil {
		return app.ScopeCmd{}, err
	}
	return cmd, nil
}

// scope administers scope declarations. It only adds and lists: removal and
// rename are out of scope, so a typo stays visible instead of silently
// rewriting history.
func (c *CLI) scope(ctx context.Context, args []string) error {
	const usage = "usage: scope add --id ID --kind KIND [--name NAME] | scope list"
	if len(args) == 0 {
		return domain.Invalid(usage)
	}
	switch args[0] {
	case "add":
		return c.scopeAdd(ctx, args[1:])
	case "list":
		return c.scopeList(ctx, args[1:])
	default:
		return domain.Invalid(usage)
	}
}

func (c *CLI) scopeAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("scope add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	id := fs.String("id", "", "scope id")
	kind := fs.String("kind", "", "personal, work, client or opensource")
	name := fs.String("name", "", "scope name (defaults to the id)")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: scope add --id ID --kind KIND [--name NAME]")
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	scope, err := svc.AddScope(ctx, app.ScopeCmd{ID: *id, Kind: *kind, Name: *name})
	if err != nil {
		return err
	}
	c.succeed("scope add", scope)
	return nil
}

func (c *CLI) scopeList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("scope list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: scope list")
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	scopes, err := svc.ListScopes(ctx)
	if err != nil {
		return err
	}
	c.succeed("scope list", scopes)
	return nil
}

// splitFlagArgs separates flags from positionals before parsing, because Go's
// flag package stops at the first non-flag while several documented forms put
// the positional first. valueFlags are the flags that consume the next
// argument.
func splitFlagArgs(args []string, valueFlags map[string]bool) (flagArgs, positional []string) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") || a == "-" {
			positional = append(positional, a)
			continue
		}
		flagArgs = append(flagArgs, a)
		if strings.Contains(a, "=") {
			continue
		}
		if valueFlags[a] && i+1 < len(args) {
			i++
			flagArgs = append(flagArgs, args[i])
		}
	}
	return flagArgs, positional
}

// context add/list declare and read GTD context names inside a scope.
func (c *CLI) context(ctx context.Context, args []string) error {
	const usage = "usage: context add NAME [--scope S] | context list [--scope S]"
	if len(args) == 0 {
		return domain.Invalid(usage)
	}
	switch args[0] {
	case "add":
		return c.contextAdd(ctx, args[1:])
	case "list":
		return c.contextList(ctx, args[1:])
	default:
		return domain.Invalid(usage)
	}
}

func (c *CLI) contextAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("context add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	flagArgs, positional := splitFlagArgs(args, map[string]bool{"--scope": true})
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 1 {
		return domain.Invalid("usage: context add NAME [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.AddContext(ctx, app.ContextCmd{Binding: b, Name: positional[0]})
	if err != nil {
		return err
	}
	c.succeed("context add", out)
	return nil
}

func (c *CLI) contextList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("context list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	flagArgs, positional := splitFlagArgs(args, map[string]bool{"--scope": true})
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 0 {
		return domain.Invalid("usage: context list [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.ListContexts(ctx, b)
	if err != nil {
		return err
	}
	c.succeed("context list", out)
	return nil
}

// doc put/get/list/search/related read the document layer; log, lint and
// archive audit and fill it.
func (c *CLI) doc(ctx context.Context, args []string) error {
	const usage = "usage: doc put|get|list|search|related|log|lint|archive [flags]"
	if len(args) == 0 {
		return domain.Invalid(usage)
	}
	switch args[0] {
	case "put":
		return c.docPut(ctx, args[1:])
	case "get":
		return c.docGet(ctx, args[1:])
	case "list":
		return c.docList(ctx, args[1:])
	case "search":
		return c.docSearch(ctx, args[1:])
	case "related":
		return c.docRelated(ctx, args[1:])
	case "log":
		return c.docLog(ctx, args[1:])
	case "lint":
		return c.docLint(ctx, args[1:])
	case "archive":
		return c.docArchive(ctx, args[1:])
	default:
		return domain.Invalid(usage)
	}
}

func (c *CLI) docPut(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc put", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "document kind")
	slug := fs.String("slug", "", "document slug")
	title := fs.String("title", "", "document title (defaults to the slug)")
	body := fs.String("body", "", "document body")
	file := fs.String("file", "", "read the body from this file")
	status := fs.String("status", string(domain.DocumentDraft), "draft|verified|superseded")
	expected := fs.Int64("expected", 0, "expected document revision")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc put --kind K --slug S [flags]")
	}
	if *kind == "" {
		return domain.Invalid("--kind is required")
	}
	if *slug == "" {
		return domain.Invalid("--slug is required")
	}
	if flagSet(fs, "body") && flagSet(fs, "file") {
		return domain.Invalid("--body and --file are mutually exclusive")
	}
	if flagSet(fs, "file") {
		raw, err := os.ReadFile(*file)
		if err != nil {
			return domain.NewError(domain.IOError, "read body file: %v", err)
		}
		*body = string(raw)
	}
	if *title == "" {
		*title = *slug
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.PutDocument(ctx, app.DocumentCmd{
		Binding: b, Kind: domain.DocumentKind(*kind), Slug: *slug,
		Title: *title, Body: *body, Status: domain.DocumentStatus(*status),
		Expected: domain.Revision(*expected),
	})
	if err != nil {
		return err
	}
	c.succeed("doc put", out)
	return nil
}

func (c *CLI) docGet(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc get", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "document kind")
	slug := fs.String("slug", "", "document slug")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc get --kind K --slug S [--scope X]")
	}
	if *kind == "" {
		return domain.Invalid("--kind is required")
	}
	if *slug == "" {
		return domain.Invalid("--slug is required")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.GetDocument(ctx, b, domain.DocumentKind(*kind), *slug)
	if err != nil {
		return err
	}
	c.succeed("doc get", out)
	return nil
}

func (c *CLI) docList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "document kind filter")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc list [--kind K] [--scope X]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.ListDocuments(ctx, b, domain.DocumentKind(*kind))
	if err != nil {
		return err
	}
	c.succeed("doc list", out)
	return nil
}

// docSearch runs one read-only FTS5 query over the binding scopes'
// documents. JSON carries the hits; the human output is one block per hit
// with its slug, title and body snippet.
func (c *CLI) docSearch(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc search", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	query := fs.String("query", "", "search query")
	kind := fs.String("kind", "", "document kind filter")
	limit := fs.Int("limit", 10, "maximum hits (capped at 50)")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc search --query Q [--kind K] [--scope X] [--limit N]")
	}
	if strings.TrimSpace(*query) == "" {
		return domain.Invalid("--query is required")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	hits, err := svc.SearchDocuments(ctx, b, *query, domain.DocumentKind(*kind), *limit)
	if err != nil {
		return err
	}
	if c.JSON {
		c.succeed("doc search", hits)
		return nil
	}
	if len(hits) == 0 {
		c.succeed("doc search", "no matches")
		return nil
	}
	var lines strings.Builder
	for _, h := range hits {
		fmt.Fprintf(&lines, "%s/%s | %s\n  %s\n",
			h.Document.Kind, h.Document.Slug, h.Document.Title, h.Snippet)
	}
	c.succeed("doc search", strings.TrimSuffix(lines.String(), "\n"))
	return nil
}

// docRelated resolves one document's links inside its own scope: the
// documents it links to and the ones that link back. JSON carries the whole
// relation; the human output lists both directions under the source.
func (c *CLI) docRelated(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc related", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "document kind")
	slug := fs.String("slug", "", "document slug")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc related --kind K --slug S [--scope X]")
	}
	if *kind == "" {
		return domain.Invalid("--kind is required")
	}
	if *slug == "" {
		return domain.Invalid("--slug is required")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	rel, err := svc.RelatedDocuments(ctx, b, domain.DocumentKind(*kind), *slug)
	if err != nil {
		return err
	}
	if c.JSON {
		c.succeed("doc related", rel)
		return nil
	}
	var lines strings.Builder
	fmt.Fprintf(&lines, "%s/%s | %s\n", rel.Source.Kind, rel.Source.Slug, rel.Source.Title)
	fmt.Fprintf(&lines, "outlinks (%d):\n", len(rel.Outlinks))
	for _, d := range rel.Outlinks {
		fmt.Fprintf(&lines, "  %s/%s | %s\n", d.Kind, d.Slug, d.Title)
	}
	fmt.Fprintf(&lines, "backlinks (%d):\n", len(rel.Backlinks))
	for _, d := range rel.Backlinks {
		fmt.Fprintf(&lines, "  %s/%s | %s\n", d.Kind, d.Slug, d.Title)
	}
	c.succeed("doc related", strings.TrimSuffix(lines.String(), "\n"))
	return nil
}

// docLog lists a document's history newest first in JSON; the human output
// reverses to chronological ascending, one Markdown heading per event.
func (c *CLI) docLog(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc log", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "document kind filter")
	slug := fs.String("slug", "", "document slug filter")
	limit := fs.Int("limit", 50, "maximum entries (capped at 500)")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc log [--scope X] [--kind K] [--slug S] [--limit N]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	entries, err := svc.ListDocumentHistory(ctx, b, app.DocumentHistoryFilter{
		Kind: domain.DocumentKind(*kind), Slug: *slug, Limit: *limit,
	})
	if err != nil {
		return err
	}
	if c.JSON {
		c.succeed("doc log", entries)
		return nil
	}
	if len(entries) == 0 {
		c.succeed("doc log", "no document history")
		return nil
	}
	var lines strings.Builder
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		fmt.Fprintf(&lines, "## [%s] %s | %s/%s\n",
			e.CreatedAt.Format("2006-01-02"), e.Event, e.Kind, e.Slug)
	}
	c.succeed("doc log", strings.TrimSuffix(lines.String(), "\n"))
	return nil
}

// docLint checks the knowledge documents of the binding scopes. Errors fail
// the command; --strict fails on warnings too. JSON carries the whole report
// in the envelope, in the success envelope when it passes and in the failure
// envelope when it does not.
func (c *CLI) docLint(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc lint", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	strict := fs.Bool("strict", false, "fail on warnings too")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc lint [--scope X] [--strict]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	report, err := svc.DocumentLint(ctx, b)
	if err != nil {
		return err
	}
	failed := !report.OK() || (*strict && !report.StrictOK())
	if c.JSON {
		if !failed {
			c.succeed("doc lint", report)
			return nil
		}
		c.data = report
	} else {
		c.printLint(report)
	}
	if !report.OK() {
		return domain.NewError(domain.Conflict, "doc lint reported %d error(s)", len(report.Errors))
	}
	return domain.NewError(domain.Conflict, "doc lint reported %d warning(s) in strict mode", len(report.Warnings))
}

// printLint is the compact human summary of a lint report: one line per
// finding, then the counts.
func (c *CLI) printLint(r app.LintReport) {
	for _, f := range r.Findings {
		where := f.Scope
		if f.Kind != "" {
			where += "/" + f.Kind
		}
		if f.Slug != "" {
			where += "/" + f.Slug
		}
		fmt.Fprintf(c.Out, "%s %s: %s\n", f.Severity, where, f.Message)
	}
	fmt.Fprintf(c.Out, "doc lint: %d error(s), %d warning(s)\n", len(r.Errors), len(r.Warnings))
}

// docArchive stores one Q&A answer as a draft knowledge document under
// answers/<slug>, reusing the document put's idempotency and revision guard.
func (c *CLI) docArchive(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("doc archive", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	slug := fs.String("slug", "", "answer slug (stored as answers/<slug>)")
	title := fs.String("title", "", "document title (defaults to the slug)")
	question := fs.String("question", "", "the question this answer records")
	body := fs.String("body", "", "answer body")
	file := fs.String("file", "", "read the answer body from this file")
	expected := fs.Int64("expected", 0, "expected document revision")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: doc archive --slug S [flags]")
	}
	if *slug == "" {
		return domain.Invalid("--slug is required")
	}
	if flagSet(fs, "body") && flagSet(fs, "file") {
		return domain.Invalid("--body and --file are mutually exclusive")
	}
	if flagSet(fs, "file") {
		raw, err := os.ReadFile(*file)
		if err != nil {
			return domain.NewError(domain.IOError, "read body file: %v", err)
		}
		*body = string(raw)
	}
	*slug = "answers/" + strings.TrimPrefix(*slug, "answers/")
	if *title == "" {
		*title = *slug
	}
	if q := strings.TrimSpace(*question); q != "" {
		*body = fmt.Sprintf("# %s\n\nQuestion: %s\nArchived: %s\n\n%s",
			*title, q, time.Now().UTC().Format("2006-01-02"), *body)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.PutDocument(ctx, app.DocumentCmd{
		Binding: b, Kind: domain.DocumentKnowledge, Slug: *slug,
		Title: *title, Body: *body, Status: domain.DocumentDraft,
		Expected: domain.Revision(*expected),
	})
	if err != nil {
		return err
	}
	c.succeed("doc archive", out)
	return nil
}

// project add/list/show declare and read projects, including their repository
// metadata.
func (c *CLI) project(ctx context.Context, args []string) error {
	const usage = "usage: project add ID [flags] | project list [--scope S] | project show ID [--scope S]"
	if len(args) == 0 {
		return domain.Invalid(usage)
	}
	switch args[0] {
	case "add":
		return c.projectAdd(ctx, args[1:])
	case "list":
		return c.projectList(ctx, args[1:])
	case "show":
		return c.projectShow(ctx, args[1:])
	default:
		return domain.Invalid(usage)
	}
}

// projectValueFlags are the project flags that consume the next argument.
var projectValueFlags = map[string]bool{
	"--scope": true, "--desired-outcome": true, "--status": true,
	"--repo-url": true, "--clone-path": true,
}

func (c *CLI) projectAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("project add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	outcome := fs.String("desired-outcome", "", "desired outcome")
	status := fs.String("status", "active", "active|paused|completed|cancelled")
	repoURL := fs.String("repo-url", "", "repository url")
	clonePath := fs.String("clone-path", "", "absolute clone path")
	flagArgs, positional := splitFlagArgs(args, projectValueFlags)
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 1 {
		return domain.Invalid("usage: project add ID [--scope S] [--desired-outcome TEXT] [--status ...] [--repo-url URL] [--clone-path PATH]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.AddProject(ctx, app.ProjectCmd{
		Binding: b, ID: positional[0], DesiredOutcome: *outcome, Status: *status,
		RepoURL: *repoURL, ClonePath: *clonePath,
	})
	if err != nil {
		return err
	}
	c.succeed("project add", out)
	return nil
}

func (c *CLI) projectList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("project list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	flagArgs, positional := splitFlagArgs(args, map[string]bool{"--scope": true})
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 0 {
		return domain.Invalid("usage: project list [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.ListProjects(ctx, b)
	if err != nil {
		return err
	}
	c.succeed("project list", out)
	return nil
}

func (c *CLI) projectShow(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("project show", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	flagArgs, positional := splitFlagArgs(args, map[string]bool{"--scope": true})
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 1 {
		return domain.Invalid("usage: project show ID [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	out, err := svc.GetProject(ctx, b, domain.ProjectID(positional[0]))
	if err != nil {
		return err
	}
	c.succeed("project show", out)
	return nil
}

func (c *CLI) capture(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("capture", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	source := fs.String("source", "manual", "source id")
	key := fs.String("key", "", "idempotency key")
	stdin := fs.Bool("stdin", false, "read text from stdin")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	text := strings.Join(fs.Args(), " ")
	if *stdin {
		b, err := io.ReadAll(io.LimitReader(os.Stdin, 64*1024+1))
		if err != nil {
			return domain.NewError(domain.IOError, "read stdin: %v", err)
		}
		text = string(b)
	}
	if strings.TrimSpace(text) == "" {
		return domain.Invalid("capture text is required")
	}
	if *key == "" {
		*key = newKey("capture")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	cap, err := svc.Capture(ctx, app.CaptureCmd{Binding: b, Key: *key, Text: text, SourceID: *source})
	if err != nil {
		return err
	}
	c.succeed("capture", cap)
	return nil
}

func (c *CLI) inbox(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "next" {
		return domain.Invalid("usage: inbox next [flags]")
	}
	fs := flag.NewFlagSet("inbox next", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	cap, err := svc.InboxNext(ctx, b)
	if err != nil {
		return err
	}
	c.succeed("inbox next", cap)
	return nil
}

func (c *CLI) process(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("process", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	key := fs.String("key", "", "idempotency key")
	expected := fs.Int64("expected", 0, "expected capture revision")
	outcome := fs.String("outcome", "", "work_items|reference|immediate|discard|defer")
	project := fs.String("project", "", "project id")
	area := fs.String("area", "", "area id")
	contextID := fs.String("context", "", "context id")
	waiting := fs.String("waiting-on", "", "waiting on")
	reviewAfter := fs.String("review-after", "", "YYYY-MM-DD")
	reason := fs.String("reason", "", "reason")
	evidence := fs.String("evidence", "", "result evidence")
	var titles stringList
	fs.Var(&titles, "title", "work item title (repeatable)")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 1 {
		// Go's flag package stops at the first non-flag, so flags precede the ID.
		return domain.Invalid("usage: process [flags] <capture-id>")
	}
	if *key == "" {
		*key = newKey("process")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	o := domain.Outcome{Kind: domain.OutcomeKind(*outcome), Titles: titles, WaitingOn: *waiting, Reason: *reason, ResultEvidence: *evidence}
	if *project != "" {
		p := domain.ProjectID(*project)
		o.ProjectID = &p
	}
	if *area != "" {
		a := domain.AreaID(*area)
		o.AreaID = &a
	}
	if *contextID != "" {
		x := domain.ContextID(*contextID)
		o.ContextID = &x
	}
	if *reviewAfter != "" {
		t, err := time.Parse("2006-01-02", *reviewAfter)
		if err != nil {
			return domain.Invalid("review-after must be YYYY-MM-DD")
		}
		t = t.UTC()
		o.ReviewAfter = &t
	}
	res, err := svc.Process(ctx, app.ProcessCmd{Binding: b, Key: *key, ID: domain.CaptureID(fs.Arg(0)), Expected: domain.Revision(*expected), Outcome: o})
	if err != nil {
		return err
	}
	c.succeed("process", res)
	return nil
}

func (c *CLI) show(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("show", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 1 {
		return domain.Invalid("usage: show <id> [flags]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	id := fs.Arg(0)
	if strings.HasPrefix(id, "C-") {
		cap, err := st.GetCapture(ctx, b, domain.CaptureID(id))
		if err != nil {
			return err
		}
		c.succeed("show", cap)
		return nil
	}
	item, err := svc.Repo.GetWorkItem(ctx, b, domain.WorkItemID(id))
	if err != nil {
		return err
	}
	c.succeed("show", item)
	return nil
}

func (c *CLI) find(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("find", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	limit := fs.Int("limit", 10, "max results")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() == 0 {
		return domain.Invalid("usage: find <query> [flags]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	items, err := svc.Repo.Find(ctx, b, strings.Join(fs.Args(), " "), *limit)
	if err != nil {
		return err
	}
	c.succeed("find", items)
	return nil
}

// list shows one list of work items, or the inbox with --list inbox. Text
// output is one line per item: id, lifecycle and title.
func (c *CLI) list(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	name := fs.String("list", "next", "inbox|next|waiting|someday|archive")
	contextName := fs.String("context", "", "context name")
	project := fs.String("project", "", "project id")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: list [--list L] [--context C] [--project P] [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	if *name == "inbox" {
		caps, err := svc.ListInbox(ctx, b)
		if err != nil {
			return err
		}
		if caps == nil {
			caps = []domain.Capture{}
		}
		if !c.JSON {
			for _, cap := range caps {
				fmt.Fprintf(c.Out, "%s %s %s\n", cap.ID, cap.State, firstLine(cap.OriginalText))
			}
			return nil
		}
		c.succeed("list", caps)
		return nil
	}
	var lifecycle domain.Lifecycle
	switch *name {
	case "next":
		lifecycle = domain.Next
	case "waiting":
		lifecycle = domain.Waiting
	case "someday":
		lifecycle = domain.Someday
	case "archive":
		lifecycle = domain.Archived
	default:
		return domain.Invalid("--list must be inbox, next, waiting, someday or archive, got %q", *name)
	}
	items, err := svc.ListWorkItemsFiltered(ctx, b, app.ListWorkItemsFilter{
		Lifecycle: lifecycle, Context: *contextName, Project: domain.ProjectID(*project),
	})
	if err != nil {
		return err
	}
	if items == nil {
		items = []domain.WorkItem{}
	}
	if !c.JSON {
		for _, item := range items {
			fmt.Fprintf(c.Out, "%s %s %s\n", item.ID, item.Lifecycle, item.Title)
		}
		return nil
	}
	c.succeed("list", items)
	return nil
}

// firstLine keeps one-line text output readable for multi-line capture text.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// moveValueFlags are the move flags that consume the next argument. Flags and
// positionals are split before parsing because Go's flag package stops at the
// first non-flag, while the documented form puts the flags after ID LIST.
var moveValueFlags = map[string]bool{
	"--scope": true, "--text": true, "--field": true, "--waiting-on": true,
	"--resolution": true, "--closure": true, "--expected": true, "--key": true,
}

func splitMoveArgs(args []string) (flagArgs, positional []string) {
	return splitFlagArgs(args, moveValueFlags)
}

// flagSet reports whether the user actually passed a flag, so an explicitly
// empty value is rejected instead of silently ignored.
func flagSet(fs *flag.FlagSet, name string) bool {
	set := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			set = true
		}
	})
	return set
}

// move moves one work item to another list: next, waiting, someday or archive.
// Custom fields travel as repeatable --field key:value; waiting_on and
// resolution keep their own flags because they are columns, not fields.
func (c *CLI) move(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("move", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	text := fs.String("text", "", "new title")
	var fields stringList
	fs.Var(&fields, "field", "key:value custom field (repeatable)")
	waitingOn := fs.String("waiting-on", "", "waiting on")
	resolution := fs.String("resolution", "", "resolution")
	closure := fs.String("closure", "", "completed|cancelled|unspecified")
	expected := fs.Int64("expected", 0, "expected work item revision")
	key := fs.String("key", "", "idempotency key")
	flagArgs, positional := splitMoveArgs(args)
	if err := fs.Parse(flagArgs); err != nil {
		return domain.Invalid("%v", err)
	}
	if len(positional) != 2 {
		return domain.Invalid("usage: move [flags] ID LIST, where LIST is next|waiting|someday|archive")
	}
	var target domain.Lifecycle
	switch positional[1] {
	case "next":
		target = domain.Next
	case "waiting":
		target = domain.Waiting
	case "someday":
		target = domain.Someday
	case "archive":
		target = domain.Archived
	default:
		return domain.Invalid("LIST must be next, waiting, someday or archive, got %q (inbox is not a move target)", positional[1])
	}
	var waitingVal, resolutionVal *string
	custom := make(map[string]string, len(fields))
	for _, raw := range fields {
		parts := strings.SplitN(raw, ":", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			return domain.Invalid("--field %q must be key:value", raw)
		}
		fieldKey := strings.TrimSpace(parts[0])
		// Legacy callers send these as fields; map them to their columns.
		switch fieldKey {
		case "waiting_on":
			v := parts[1]
			waitingVal = &v
			continue
		case "resolution":
			v := parts[1]
			resolutionVal = &v
			continue
		}
		if domain.IsReservedField(fieldKey) {
			return domain.Invalid("--field %q is reserved: context, client, project, captured_at and closed_at have their own columns", fieldKey)
		}
		custom[fieldKey] = parts[1]
	}
	var textVal *string
	if flagSet(fs, "text") {
		textVal = text
	}
	if flagSet(fs, "waiting-on") {
		waitingVal = waitingOn
	}
	if flagSet(fs, "resolution") {
		resolutionVal = resolution
	}
	if *key == "" {
		*key = newKey("move")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	item, err := svc.MoveWorkItem(ctx, app.MoveWorkItemCmd{
		Binding: b, Key: *key, ID: domain.WorkItemID(positional[0]), Target: target,
		Text: textVal, WaitingOn: waitingVal, Resolution: resolutionVal,
		ClosureKind: domain.ClosureKind(*closure), Fields: custom,
		Expected: domain.Revision(*expected),
	})
	if err != nil {
		return err
	}
	c.succeed("move", item)
	return nil
}

// statusData is the environment report: where the data lives, which profile
// and actor run, the declared scopes, the binding a command gets with no
// explicit --scope, and the routing hint of this directory.
type statusData struct {
	Database string   `json:"database"`
	Profile  string   `json:"profile"`
	Actor    string   `json:"actor"`
	Scopes   []string `json:"scopes"`
	// EffectiveScopes is the resolved default binding: what a command sees
	// without an explicit --scope, after ZTD_SCOPES and the .ztd.json hint.
	EffectiveScopes []string `json:"effective_scopes"`
	Binding         any      `json:"binding"`
	Warning         string   `json:"warning,omitempty"`
}

// status reports the local environment. It never creates the database: an
// absent database just reports no scopes.
func (c *CLI) status(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: status")
	}
	data := statusData{
		Database: c.DB, Profile: implicitProfile, Actor: c.Actor,
		Scopes: []string{}, EffectiveScopes: []string{}, Binding: nil,
	}
	if _, err := os.Stat(c.DB); err == nil {
		st, svc, err := c.open()
		if err != nil {
			return err
		}
		defer st.Close()
		scopes, err := svc.ListScopes(ctx)
		if err != nil {
			return err
		}
		for _, sc := range scopes {
			data.Scopes = append(data.Scopes, string(sc.ID))
		}
		owned, err := svc.Repo.ProfileScopes(ctx, implicitProfile)
		switch {
		case err == nil:
			effective, err := resolveScopes(owned, scopes, nil)
			if err != nil {
				return err
			}
			for _, id := range effective {
				data.EffectiveScopes = append(data.EffectiveScopes, string(id))
			}
		case domain.Of(err, domain.NotFound):
			// No profile yet: there is no binding to report.
		default:
			return err
		}
	}
	data.Binding, data.Warning = readBindingHint(".ztd.json")
	c.succeed("status", data)
	return nil
}

// readBindingHint reads .ztd.json from the working directory. The file is a
// routing hint, never a source of authorization: a missing or malformed file
// comes back as null plus a warning instead of a failure.
func readBindingHint(path string) (any, string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, path + " not found in the current directory"
		}
		return nil, fmt.Sprintf("read %s: %v", path, err)
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, fmt.Sprintf("%s is not a valid JSON object: %v", path, err)
	}
	if obj == nil {
		return nil, path + " is not a JSON object"
	}
	return obj, ""
}

func (c *CLI) prepare(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("prepare", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	date := fs.String("date", "", "YYYY-MM-DD")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	brief, err := svc.Prepare(ctx, b, *date)
	if err != nil {
		return err
	}
	c.succeed("prepare", brief)
	return nil
}

func (c *CLI) goal(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: goal set|show [flags]")
	}
	switch args[0] {
	case "set":
		return c.goalSet(ctx, args[1:])
	case "show":
		return c.goalShow(ctx, args[1:])
	default:
		return domain.Invalid("usage: goal set|show [flags]")
	}
}

func (c *CLI) goalSet(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("goal set", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	key := fs.String("key", "", "idempotency key")
	kind := fs.String("kind", "primary", "primary|subgoal")
	startOn := fs.String("start-on", "", "YYYY-MM-DD")
	endOn := fs.String("end-on", "", "YYYY-MM-DD")
	statement := fs.String("statement", "", "goal statement")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	text := *statement
	if text == "" {
		text = strings.Join(fs.Args(), " ")
	}
	if *key == "" {
		*key = newKey("goal")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	goal, err := svc.SetGoal(ctx, app.GoalCmd{
		Binding: b, Key: *key, Kind: *kind,
		StartOn: *startOn, EndOn: *endOn, Statement: text,
	})
	if err != nil {
		return err
	}
	c.succeed("goal set", goal)
	return nil
}

func (c *CLI) goalShow(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("goal show", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	goal, err := svc.ActiveGoal(ctx, b)
	if err != nil {
		return err
	}
	c.succeed("goal show", goal)
	return nil
}

func (c *CLI) plan(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "commit" {
		return c.planRead(ctx, args)
	}
	fs := flag.NewFlagSet("plan commit", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "daily", "daily|weekly")
	period := fs.String("period", "", "YYYY-MM-DD or YYYY-Www")
	expected := fs.Int64("expected", 0, "expected plan revision")
	override := fs.String("override", "", "daily limit override id")
	key := fs.String("key", "", "idempotency key")
	var items stringList
	fs.Var(&items, "item", "ID:role (repeatable; role mit|big_rock|batch)")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if *period == "" {
		return domain.Invalid("--period is required")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	parsed := make([]domain.PlanItem, 0, len(items))
	for i, raw := range items {
		parts := strings.SplitN(raw, ":", 2)
		if len(parts) != 2 {
			return domain.Invalid("item %q must be ID:role", raw)
		}
		parsed = append(parsed, domain.PlanItem{WorkItemID: domain.WorkItemID(parts[0]), Role: domain.PlanRole(parts[1]), Position: i})
	}
	if *key == "" {
		*key = newKey("plan")
	}
	plan, err := svc.CommitPlan(ctx, app.CommitPlanCmd{Binding: b, Key: *key, Kind: domain.PlanKind(*kind), Period: *period, Expected: domain.Revision(*expected), Items: parsed, OverrideID: *override})
	if err != nil {
		return err
	}
	c.succeed("plan commit", plan)
	return nil
}

// planRead is the legacy `plan --context` read path: it returns the prepare
// brief without choosing or writing anything. --context filters the three
// item lists by context name; --client is accepted for old callers and ignored.
func (c *CLI) planRead(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("plan", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	contextName := fs.String("context", "", "context name")
	fs.String("client", "", "legacy filter (ignored)")
	date := fs.String("date", "", "YYYY-MM-DD")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: plan [--context C] [--date D] [--scope S]")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	brief, err := svc.Prepare(ctx, b, *date)
	if err != nil {
		return err
	}
	if *contextName != "" {
		brief.MITs = filterByContext(brief.MITs, *contextName)
		brief.Next = filterByContext(brief.Next, *contextName)
		brief.Waiting = filterByContext(brief.Waiting, *contextName)
	}
	c.succeed("plan", brief)
	return nil
}

func filterByContext(items []domain.WorkItem, name string) []domain.WorkItem {
	out := make([]domain.WorkItem, 0, len(items))
	suffix := ":" + name
	for _, item := range items {
		if item.ContextID != nil && strings.HasSuffix(string(*item.ContextID), suffix) {
			out = append(out, item)
		}
	}
	return out
}

func (c *CLI) focus(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: focus start|checkpoint|finish [flags]")
	}
	sub := args[0]
	fs := flag.NewFlagSet("focus "+sub, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	key := fs.String("key", "", "idempotency key")
	result := fs.String("result", "", "checkpoint result")
	next := fs.String("next", "", "next action")
	evidence := fs.String("evidence", "", "evidence reference")
	outcome := fs.String("outcome", "", "finish outcome")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	if *key == "" {
		*key = newKey(sub)
	}
	switch sub {
	case "start":
		if fs.NArg() != 1 {
			return domain.Invalid("usage: focus start [flags] <work-item-id>")
		}
		f, cps, err := svc.StartFocus(ctx, app.FocusStartCmd{Binding: b, Key: *key, Item: domain.WorkItemID(fs.Arg(0))})
		if err != nil {
			return err
		}
		c.succeed("focus start", map[string]any{"focus": f, "checkpoints": cps})
	case "checkpoint":
		if fs.NArg() != 1 {
			return domain.Invalid("usage: focus checkpoint [flags] <work-item-id>")
		}
		ev := []string{}
		if *evidence != "" {
			ev = append(ev, *evidence)
		}
		cp, err := svc.Checkpoint(ctx, app.CheckpointCmd{Binding: b, Key: *key, Item: domain.WorkItemID(fs.Arg(0)), Result: *result, Evidence: ev, NextAction: *next})
		if err != nil {
			return err
		}
		c.succeed("focus checkpoint", cp)
	case "finish":
		if fs.NArg() != 1 {
			return domain.Invalid("usage: focus finish [flags] <focus-id>")
		}
		f, err := svc.FinishFocus(ctx, app.FocusFinishCmd{Binding: b, Key: *key, Focus: domain.FocusID(fs.Arg(0)), Outcome: *outcome})
		if err != nil {
			return err
		}
		c.succeed("focus finish", f)
	default:
		return domain.Invalid("unknown focus subcommand %q", sub)
	}
	return nil
}

func (c *CLI) review(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: review daily|weekly|monthly|yearly [flags]")
	}
	kind := args[0]
	fs := flag.NewFlagSet("review "+kind, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	key := fs.String("key", "", "idempotency key")
	period := fs.String("period", "", "period label")
	outcomes := fs.String("outcomes", "", "review outcomes")
	coverage := fs.String("coverage", "", "declared coverage")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	if *key == "" {
		*key = newKey("review")
	}
	r, err := svc.Repo.RecordReview(ctx, app.ReviewCmd{Binding: b, Key: *key, Kind: kind, Period: *period, Outcomes: *outcomes, Coverage: *coverage, Complete: true}, time.Now().UTC())
	if err != nil {
		return err
	}
	c.succeed("review", r)
	return nil
}

func (c *CLI) source(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: source add|apply|list|review [flags]")
	}
	switch args[0] {
	case "add":
		return c.sourceAdd(ctx, args[1:])
	case "apply":
		return c.sourceApply(ctx, args[1:])
	case "list":
		return c.sourceList(ctx, args[1:])
	case "review":
		return c.sourceReview(ctx, args[1:])
	default:
		return domain.Invalid("usage: source add|apply|list|review [flags]")
	}
}

// sourceApply synchronizes a user-owned source configuration file. ZTD does
// not know providers or run retrieval; the file only describes generic source
// identity, scope and connector settings. It is an operator command: the
// binding is the union of the scopes the file declares, and a scope that does
// not exist fails before any write.
func (c *CLI) sourceApply(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("source apply", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("file", DefaultSourcesPath(), "source configuration JSON file")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	raw, err := os.ReadFile(*file)
	if err != nil {
		return domain.NewError(domain.IOError, "read source configuration: %v", err)
	}
	var cfg struct {
		Sources []struct {
			ID             string `json:"id"`
			Name           string `json:"name"`
			Scope          string `json:"scope"`
			Kind           string `json:"kind"`
			Connector      string `json:"connector"`
			Provider       string `json:"provider"`
			ConnectionRef  string `json:"connection_ref"`
			NonSecretQuery string `json:"non_secret_query"`
			Cadence        string `json:"cadence"`
		} `json:"sources"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return domain.Invalid("parse source configuration: %v", err)
	}
	// One binding over the union of the declared scopes, in first-seen order.
	seen := make(map[string]bool, len(cfg.Sources))
	union := make([]string, 0, len(cfg.Sources))
	for _, s := range cfg.Sources {
		if s.Scope == "" || seen[s.Scope] {
			continue
		}
		seen[s.Scope] = true
		union = append(union, s.Scope)
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	declared, err := svc.Repo.ListScopes(ctx)
	if err != nil {
		return err
	}
	known := make(map[string]bool, len(declared))
	for _, sc := range declared {
		known[string(sc.ID)] = true
	}
	for _, id := range union {
		if !known[id] {
			return domain.Invalid("unknown scope reference %s", id)
		}
	}
	b := domain.ScopeBinding{Profile: operatorProfile, Actor: domain.ActorID(c.Actor), Scopes: scopeIDs(union)}
	cmds := make([]app.SourceCmd, 0, len(cfg.Sources))
	for _, s := range cfg.Sources {
		cmds = append(cmds, app.SourceCmd{
			Binding: b, ID: s.ID, Name: s.Name, Scope: domain.ScopeID(s.Scope),
			Kind: domain.SourceKind(s.Kind), Connector: domain.SourceConnector(s.Connector),
			Provider: s.Provider, ConnectionRef: s.ConnectionRef,
			NonSecretQuery: s.NonSecretQuery, Cadence: s.Cadence,
		})
	}
	sources, err := svc.ApplySources(ctx, cmds)
	if err != nil {
		return err
	}
	if sources == nil {
		sources = []domain.Source{}
	}
	c.succeed("source apply", sources)
	return nil
}

// sourceAdd registers one source in an explicitly declared scope. There is no
// profile axis here: the operator names the scope, and the store checks that
// it exists.
func (c *CLI) sourceAdd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("source add", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	id := fs.String("id", "", "source id")
	name := fs.String("name", "", "source name")
	scope := fs.String("scope", "", "scope")
	kind := fs.String("kind", "", "capture or calendar")
	connector := fs.String("connector", "", "manual, directory or host_mcp")
	provider := fs.String("provider", "", "provider name")
	connectionRef := fs.String("connection-ref", "", "host connection reference")
	query := fs.String("query", "", "non-secret query")
	cadence := fs.String("cadence", "", "cadence")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *scope == "" {
		return domain.Invalid("--scope is required")
	}
	b := domain.ScopeBinding{
		Profile: operatorProfile, Actor: domain.ActorID(c.Actor),
		Scopes: []domain.ScopeID{domain.ScopeID(*scope)},
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	src, err := svc.AddSource(ctx, app.SourceCmd{
		Binding: b, ID: *id, Name: *name, Scope: domain.ScopeID(*scope),
		Kind: domain.SourceKind(*kind), Connector: domain.SourceConnector(*connector),
		Provider: *provider, ConnectionRef: *connectionRef,
		NonSecretQuery: *query, Cadence: *cadence,
	})
	if err != nil {
		return err
	}
	c.succeed("source add", src)
	return nil
}

// sourceList filters the registry. --all (the default) is the operator view of
// every declared scope and repeated --scope narrows to those scopes. Only one
// selector may be given, so a listing can never silently widen past what was
// asked for.
func (c *CLI) sourceList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("source list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	all := fs.Bool("all", false, "list every registered source")
	var scopes stringList
	fs.Var(&scopes, "scope", "scope to list (repeatable)")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *all && len(scopes) > 0 {
		return domain.Invalid("source list takes either --all or --scope, not both")
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	var b domain.ScopeBinding
	if len(scopes) > 0 {
		b = domain.ScopeBinding{Profile: operatorProfile, Actor: domain.ActorID(c.Actor), Scopes: scopeIDs(scopes)}
	} else {
		declared, err := svc.Repo.ListScopes(ctx)
		if err != nil {
			return err
		}
		ids := make([]domain.ScopeID, 0, len(declared))
		for _, sc := range declared {
			ids = append(ids, sc.ID)
		}
		b = domain.ScopeBinding{Profile: operatorProfile, Actor: domain.ActorID(c.Actor), Scopes: ids}
	}
	if err := b.Validate(); err != nil {
		return err
	}
	sources, err := svc.ListSources(ctx, b)
	if err != nil {
		return err
	}
	if sources == nil {
		sources = []domain.Source{}
	}
	c.succeed("source list", sources)
	return nil
}

// sourceReview feeds one batch file into the registry. Flags win over the
// file's identity fields so an operator can correct them without editing the
// batch; result_kind defaults to reported and observed never passes the
// service, which reserves it for a trusted host adapter.
func (c *CLI) sourceReview(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("source review", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	sourceID := fs.String("source", "", "source id")
	batch := fs.String("batch", "", "batch id")
	key := fs.String("key", "", "idempotency key")
	file := fs.String("file", "", "batch JSON file")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *file == "" {
		return domain.Invalid("--file is required")
	}
	raw, err := os.ReadFile(*file)
	if err != nil {
		return domain.NewError(domain.IOError, "read batch file: %v", err)
	}
	var batchFile struct {
		SourceID   string                 `json:"source_id"`
		BatchID    string                 `json:"batch_id"`
		Key        string                 `json:"idempotency_key"`
		ResultKind string                 `json:"result_kind"`
		Retrieval  domain.SourceRetrieval `json:"retrieval"`
		Items      []domain.SourceItem    `json:"items"`
	}
	if err := json.Unmarshal(raw, &batchFile); err != nil {
		return domain.Invalid("parse batch file: %v", err)
	}
	if *sourceID == "" {
		*sourceID = batchFile.SourceID
	}
	if *batch == "" {
		*batch = batchFile.BatchID
	}
	if *key == "" {
		*key = batchFile.Key
	}
	if *sourceID == "" {
		return domain.Invalid("--source is required")
	}
	if *batch == "" {
		return domain.Invalid("--batch is required")
	}
	if *key == "" {
		*key = newKey("source-review")
	}
	resultKind := batchFile.ResultKind
	if resultKind == "" {
		resultKind = "reported"
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	review, captures, err := svc.RecordSourceReview(ctx, app.SourceReviewCmd{
		Binding: b, SourceID: *sourceID, BatchID: *batch, Key: *key,
		ResultKind: resultKind, Retrieval: batchFile.Retrieval, Items: batchFile.Items,
	})
	if err != nil {
		return err
	}
	if captures == nil {
		captures = []domain.Capture{}
	}
	c.succeed("source review", map[string]any{"review": review, "captures": captures})
	return nil
}

func (c *CLI) routines(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: routines due|done [flags]")
	}
	sub := args[0]
	fs := flag.NewFlagSet("routines "+sub, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	date := fs.String("date", "", "YYYY-MM-DD")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if *date == "" {
		*date = time.Now().UTC().Format("2006-01-02")
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	switch sub {
	case "due":
		rs, err := svc.Repo.DueRoutines(ctx, b, *date)
		if err != nil {
			return err
		}
		c.succeed("routines due", rs)
	case "done":
		if fs.NArg() != 1 {
			return domain.Invalid("usage: routines done [flags] <routine-id>")
		}
		r, err := svc.Repo.CompleteRoutine(ctx, b, domain.RoutineID(fs.Arg(0)), *date)
		if err != nil {
			return err
		}
		c.succeed("routines done", r)
	default:
		return domain.Invalid("unknown routines subcommand %q", sub)
	}
	return nil
}

// install publishes an embedded bundle with a no-clobber preflight: the
// whole bundle is classified before the first write, and any conflict
// aborts with no files written. `opencode` lands in $HOME/.config/opencode,
// `templates` in the store root (the directory of --db), which must exist.
func (c *CLI) install(args []string) error {
	if len(args) == 0 {
		return domain.Invalid(installUsage)
	}
	target := args[0]
	flags := flag.NewFlagSet("install "+target, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	dryRun := flags.Bool("dry-run", false, "classify and report without writing")
	if err := flags.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if flags.NArg() != 0 {
		return domain.Invalid(installUsage)
	}
	var fsys fs.FS
	cfg := install.Config{Version: Version, DryRun: *dryRun}
	switch target {
	case "opencode":
		home, err := os.UserHomeDir()
		if err != nil {
			return domain.NewError(domain.IOError, "resolve home directory: %v", err)
		}
		fsys, cfg.Prefix, cfg.Root = ztd.OpencodeFS, "integrations/opencode",
			filepath.Join(home, ".config", "opencode")
	case "templates":
		fsys, cfg.Prefix, cfg.Root = ztd.TemplatesFS, "method", filepath.Dir(c.DB)
		cfg.RequireRoot = true
	default:
		return domain.Invalid(installUsage)
	}
	report, err := install.Run(fsys, cfg)
	if err != nil {
		if errors.Is(err, install.ErrMissingRoot) {
			return domain.Invalid("%v", err)
		}
		return err
	}
	if len(report.Conflicts) > 0 {
		c.data = report
		return domain.NewError(domain.Conflict, "install aborted, no files written:\n%s",
			strings.Join(report.Conflicts, "\n"))
	}
	if c.JSON {
		c.succeed("install", report)
		return nil
	}
	summary := fmt.Sprintf("installed %d, updated %d, unchanged %d",
		report.Installed, report.Updated, report.Unchanged)
	if *dryRun {
		summary += " (dry run, nothing written)"
	}
	c.succeed("install", summary)
	return nil
}

const installUsage = "usage: install opencode|templates [--dry-run]"

func (c *CLI) migrate(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return domain.Invalid("usage: migrate import|verify|documents [flags]")
	}
	sub := args[0]
	if sub == "documents" {
		return c.migrateDocuments(ctx, args[1:])
	}
	fs := flag.NewFlagSet("migrate "+sub, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	source := fs.String("source", "", "legacy store copy")
	agentExport := fs.String("agent-export", "", "agent export JSON")
	target := fs.String("target", "", "staging database")
	report := fs.String("report", "", "report path")
	mapping := fs.String("mapping", "", "mapping JSON")
	check := fs.String("legacy-check", "", "legacy check result (must be 'ok')")
	version := fs.String("legacy-version", "", "legacy format version")
	if err := fs.Parse(args[1:]); err != nil {
		return domain.Invalid("%v", err)
	}
	if *source == "" {
		return domain.Invalid("--source is required")
	}
	if *target == "" {
		*target = c.DB
	}
	if *check != "ok" && sub == "import" {
		return domain.Invalid("--legacy-check ok is required: run the legacy check on the quiescent copy first")
	}
	if *version == "" {
		*version = "2"
	}
	c.DB = *target
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	cmd := app.ImportCmd{
		SourceCopy: *source, AgentExport: *agentExport, Target: *target,
		ReportPath: *report, MappingPath: *mapping,
		LegacyCheck: *check, LegacyVersion: *version, Actor: c.Actor,
	}
	var mr app.MigrationReport
	if sub == "import" {
		mr, err = svc.Repo.Import(ctx, cmd, time.Now().UTC())
	} else if sub == "verify" {
		mr, err = svc.Repo.VerifyImport(ctx, cmd)
	} else {
		return domain.Invalid("unknown migrate subcommand %q", sub)
	}
	if err != nil {
		return err
	}
	c.succeed("migrate "+sub, mr)
	return nil
}

// migrateDocuments populates the document layer from a verified copy of the
// legacy Markdown store. It writes to the --db database only; the source copy
// is read, never modified, and never ~/.ztd itself.
func (c *CLI) migrateDocuments(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("migrate documents", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	source := fs.String("source", "", "legacy store copy")
	mapping := fs.String("mapping", "", "mapping JSON")
	workspace := fs.String("workspace", "", "directory for relative clone paths")
	dryRun := fs.Bool("dry-run", false, "plan and report without writing")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: migrate documents --source COPY [--mapping FILE] [--workspace DIR] [--dry-run]")
	}
	if *source == "" {
		return domain.Invalid("--source is required")
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	report, err := svc.ImportDocuments(ctx, app.ImportDocumentsCmd{
		Source: *source, MappingPath: *mapping, Workspace: *workspace, DryRun: *dryRun,
	})
	if err != nil {
		return err
	}
	c.succeed("migrate documents", report)
	return nil
}

func (c *CLI) export(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	out := fs.String("out", "", "output JSON path")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *out == "" {
		return domain.Invalid("--out is required")
	}
	st, _, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.Export(ctx, *out); err != nil {
		return err
	}
	c.succeed("export", map[string]string{"path": *out})
	return nil
}

func (c *CLI) restore(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("restore", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	from := fs.String("from", "", "export JSON path")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *from == "" {
		return domain.Invalid("--from is required")
	}
	st, _, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	r, err := st.Restore(ctx, *from)
	if err != nil {
		return err
	}
	c.succeed("restore", r)
	return nil
}

func (c *CLI) snapshot(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("snapshot", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	out := fs.String("out", "", "snapshot path")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if *out == "" {
		return domain.Invalid("--out is required")
	}
	st, _, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.Snapshot(ctx, *out); err != nil {
		return err
	}
	c.succeed("snapshot", map[string]string{"path": *out})
	return nil
}

// recover is a compatibility no-op: the SQLite store has no Markdown journal.
func (c *CLI) recover(args []string) error {
	if len(args) != 0 {
		return domain.Invalid("usage: recover")
	}
	c.succeed("recover", map[string]any{"recovered": false})
	return nil
}

func (c *CLI) check(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	bindings := fs.Bool("bindings", false, "validate the .ztd.json routing hint")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	if fs.NArg() != 0 {
		return domain.Invalid("usage: check [--scope S] [--bindings]")
	}
	if *bindings {
		return c.checkBindings(ctx)
	}
	st, svc, err := c.open()
	if err != nil {
		return err
	}
	defer st.Close()
	var b *domain.ScopeBinding
	if *scope != "" {
		v, err := c.binding(ctx, svc, oneScope(*scope))
		if err != nil {
			return err
		}
		b = &v
	}
	report, err := st.Check(ctx, b)
	if err != nil {
		return err
	}
	c.succeed("check", report)
	if !report.OK {
		return domain.NewError(domain.Conflict, "check reported errors")
	}
	return nil
}

// checkBindings validates the .ztd.json routing hint of the current directory:
// the file shape, the scope it resolves to, and that the project exists in
// that scope. It reads nothing outside the working directory and the database,
// and writes nothing.
func (c *CLI) checkBindings(ctx context.Context) error {
	raw, err := os.ReadFile(".ztd.json")
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return domain.Invalid(".ztd.json not found")
		}
		return domain.NewError(domain.IOError, "read .ztd.json: %v", err)
	}
	var hint map[string]any
	if err := json.Unmarshal(raw, &hint); err != nil {
		return domain.Invalid(".ztd.json is not valid JSON: %v", err)
	}
	if hint == nil {
		return domain.Invalid(".ztd.json must be a JSON object")
	}
	for key := range hint {
		switch key {
		case "context", "client", "project":
		default:
			return domain.Invalid(".ztd.json has unexpected field %q (want context, client, project)", key)
		}
	}
	strField := func(name string, required bool) (string, error) {
		v, ok := hint[name]
		if !ok {
			if required {
				return "", domain.Invalid(".ztd.json is missing %q", name)
			}
			return "", nil
		}
		s, ok := v.(string)
		if !ok {
			return "", domain.Invalid(".ztd.json field %q must be a string", name)
		}
		if required && strings.TrimSpace(s) == "" {
			return "", domain.Invalid(".ztd.json field %q must be non-empty", name)
		}
		return s, nil
	}
	contextVal, err := strField("context", true)
	if err != nil {
		return err
	}
	clientVal, err := strField("client", false)
	if err != nil {
		return err
	}
	projectVal, err := strField("project", true)
	if err != nil {
		return err
	}

	// Resolve the scope against the declared scopes; a missing database has
	// none, so resolution fails the same way as an unknown scope. The database
	// is only opened when it already exists: this command never creates it.
	var scopes []domain.Scope
	var st *store.Store
	var svc *app.Service
	if _, statErr := os.Stat(c.DB); statErr == nil {
		st, svc, err = c.open()
		if err != nil {
			return err
		}
		defer st.Close()
		scopes, err = svc.ListScopes(ctx)
		if err != nil {
			return err
		}
	}
	declared := make(map[domain.ScopeID]bool, len(scopes))
	for _, sc := range scopes {
		declared[sc.ID] = true
	}
	var resolved domain.ScopeID
	switch {
	case declared[domain.ScopeID(contextVal)]:
		resolved = domain.ScopeID(contextVal)
	case strings.TrimSpace(clientVal) != "" && declared[domain.ScopeID("client:"+clientVal)]:
		resolved = domain.ScopeID("client:" + clientVal)
	case declared["personal"]:
		resolved = "personal"
	default:
		return domain.Invalid("no scope matches .ztd.json (context %q, client %q)", contextVal, clientVal)
	}
	if svc == nil {
		return domain.NewError(domain.NotFound, "project %s not found", projectVal)
	}
	binding := domain.ScopeBinding{
		Profile: implicitProfile, Actor: domain.ActorID(c.Actor),
		Scopes: []domain.ScopeID{resolved},
	}
	proj, err := svc.GetProject(ctx, binding, domain.ProjectID(projectVal))
	if err != nil {
		return err
	}
	c.succeed("check", map[string]any{
		"ok":      true,
		"binding": hint,
		"scope":   string(resolved),
		"project": string(proj.ID),
	})
	return nil
}

// mcp serves JSON-RPC on stdout, so it never calls succeed: stdout is the
// protocol stream and failures go back through the CLI's stderr path.
// Without --scope (or ZTD_SCOPES) the server starts with the default
// personal binding, so a client session must select its scope explicitly:
// `ztd mcp --scope client:<name>`.
func (c *CLI) mcp(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	scope := fs.String("scope", "", "scope")
	if err := fs.Parse(args); err != nil {
		return domain.Invalid("%v", err)
	}
	st, svc, b, err := c.bound(ctx, oneScope(*scope))
	if err != nil {
		return err
	}
	defer st.Close()
	return mcpserver.Serve(ctx, svc, b, Version)
}

func newKey(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, time.Now().UTC().UnixNano())
}

const usage = `ztd — local ZTD

  ztd [--db PATH] [--json] [--actor NAME] COMMAND ...

  init [--actor A] [--non-interactive] [--scope DECL]...
        DECL = id=salud,kind=personal,name=Salud
  install opencode [--dry-run]   (publish skills/commands to ~/.config/opencode)
  install templates [--dry-run]  (publish method templates to <store>/templates)
  scope add --id ID --kind KIND [--name NAME] | scope list
  capture TEXT... [--scope S] [--source ID] [--key K]
  inbox next [--scope S]
  process --outcome K [--title T] [--expected N] ID
  show ID
  find QUERY
  list [--list inbox|next|waiting|someday|archive] [--context C] [--project P] [--scope S]
  move [--text T] [--field k:v]... [--waiting-on W] [--resolution R]
       [--closure completed|cancelled|unspecified] [--expected N] [--key K] ID LIST
       LIST = next|waiting|someday|archive
  status [--json]                  (database, profile, actor, scopes, effective scopes,
                                    .ztd.json binding)
  due [--date YYYY-MM-DD]          (alias of routines due)
  routine done ID [--date YYYY-MM-DD]  (alias of routines done ID)
  prepare [--scope S] [--date YYYY-MM-DD]
  goal set --statement S | goal show
  plan [--context C] [--date D] [--scope S]   (read-only prepare brief)
  plan commit --period P --item ID:role
  focus start ID | focus checkpoint ID | focus finish FOCUS
  review daily|weekly|monthly|yearly
  source add --id ID --name NAME --scope S --kind capture|calendar --connector manual|directory|host_mcp
  source apply [--file PATH]        (default ~/.ztd/sources.json, or ZTD_SOURCES)
  source list [--all | --scope S...]
  source review --source ID --batch B --key K --file FILE
  routines due|done ID
  context add NAME [--scope S] | context list [--scope S]
  doc put --kind K --slug S [--scope X] [--title T] [--body TEXT | --file PATH]
       [--status draft|verified|superseded] [--expected N]
  doc get --kind K --slug S [--scope X] | doc list [--kind K] [--scope X]
  doc search --query Q [--kind K] [--scope X] [--limit N]
  doc related --kind K --slug S [--scope X]
  doc log [--scope X] [--kind K] [--slug S] [--limit N]
  doc lint [--scope X] [--strict]
  doc archive --slug S [--title T] [--question Q] [--body TEXT | --file PATH]
       [--scope X] [--expected N]
  project add ID [--scope S] [--desired-outcome TEXT]
       [--status active|paused|completed|cancelled] [--repo-url URL] [--clone-path PATH]
  project list [--scope S] | project show ID [--scope S]
  migrate import|verify --source COPY --legacy-check ok
  migrate documents --source COPY [--mapping FILE] [--workspace DIR] [--dry-run]
  export --out FILE | restore --from FILE | snapshot --out FILE
  check [--scope S] [--bindings]  (--bindings validates the .ztd.json hint)
  recover                            (compatibility no-op; no Markdown journal)
  mcp [--scope S]

  Scope binding (one store, one set of tasks; the binding only narrows the view):
  --scope, then ZTD_SCOPES, then .ztd.json, else the profile scopes
  without client:* and work.`
