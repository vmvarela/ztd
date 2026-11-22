// Package integration drives the real ztd binary as separate processes against
// a throwaway database: one build in TestMain, one os/exec call per command.
package integration

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

var binPath string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "ztd-integration-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "temp dir:", err)
		os.Exit(1)
	}
	name := "ztd"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	binPath = filepath.Join(dir, name)
	build := exec.Command("go", "build", "-o", binPath, "./cmd/ztd")
	build.Dir = repoRoot()
	if out, err := build.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "go build: %v\n%s", err, out)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// repoRoot walks up from this file (test/integration/cli_test.go) so the build
// runs in the module root regardless of the test working directory.
func repoRoot() string {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		panic("runtime.Caller failed")
	}
	return filepath.Dir(filepath.Dir(filepath.Dir(file)))
}

type errorShape struct {
	Family string `json:"family"`
	Detail string `json:"detail"`
}

type envelope struct {
	OK      bool            `json:"ok"`
	Command string          `json:"command"`
	Data    json.RawMessage `json:"data"`
	Error   *errorShape     `json:"error"`
}

type result struct {
	code   int
	stdout string
	stderr string
	env    envelope
}

// run executes one ztd invocation with a fresh HOME so nothing can fall back
// to the real user profile.
func run(t *testing.T, db string, args ...string) result {
	t.Helper()
	return runHome(t, t.TempDir(), db, args...)
}

// runHome is run with a fixed HOME, for commands whose default path lives
// under the user's home (for example ~/.ztd/sources.json).
func runHome(t *testing.T, home, db string, args ...string) result {
	t.Helper()
	return runIn(t, home, "", db, args...)
}

// runIn is run with a fixed HOME and working directory; an empty dir keeps the
// test process directory. The working directory matters for commands that read
// .ztd.json from it.
func runIn(t *testing.T, home, dir, db string, args ...string) result {
	t.Helper()
	full := append([]string{"--json", "--db", db}, args...)
	cmd := exec.Command(binPath, full...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + home,
		// Windows resolves the home directory from USERPROFILE only.
		"USERPROFILE=" + home,
		"TMPDIR=" + t.TempDir(),
		"USER=ztd-test",
	}
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("run %v: %v (stderr: %s)", full, err, stderr.String())
		}
		code = ee.ExitCode()
	}
	r := result{code: code, stdout: stdout.String(), stderr: stderr.String()}
	if err := json.Unmarshal([]byte(strings.TrimSpace(r.stdout)), &r.env); err != nil {
		t.Fatalf("run %v: decode envelope: %v\nstdout: %s\nstderr: %s", full, err, r.stdout, r.stderr)
	}
	return r
}

// wantOK asserts exit 0 plus a success envelope and returns data for decoding.
func (r result) wantOK(t *testing.T, command string) json.RawMessage {
	t.Helper()
	if r.code != 0 {
		t.Fatalf("exit = %d, want 0\nstdout: %s\nstderr: %s", r.code, r.stdout, r.stderr)
	}
	if !r.env.OK || r.env.Error != nil {
		t.Fatalf("ok = false, want success envelope\nstdout: %s", r.stdout)
	}
	if r.env.Command != command {
		t.Fatalf("command = %q, want %q", r.env.Command, command)
	}
	return r.env.Data
}

// wantErr asserts a failure envelope with the given exit status and error family.
func (r result) wantErr(t *testing.T, code int, command, family string) {
	t.Helper()
	if r.code != code {
		t.Fatalf("exit = %d, want %d\nstdout: %s\nstderr: %s", r.code, code, r.stdout, r.stderr)
	}
	if r.env.OK || r.env.Error == nil {
		t.Fatalf("want failure envelope, got ok=true\nstdout: %s", r.stdout)
	}
	if r.env.Command != command {
		t.Fatalf("command = %q, want %q", r.env.Command, command)
	}
	if r.env.Error.Family != family {
		t.Fatalf("error family = %q (%s), want %q", r.env.Error.Family, r.env.Error.Detail, family)
	}
}

func decode[T any](t *testing.T, data json.RawMessage) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("decode data %s: %v", data, err)
	}
	return v
}

// initArgs is the standard test declaration: the personal and opensource
// scopes. init creates the implicit personal profile over them.
var initArgs = []string{
	"init",
	"--scope", "id=personal,kind=personal",
	"--scope", "id=opensource,kind=opensource",
}

func initDB(t *testing.T, db string) {
	t.Helper()
	run(t, db, initArgs...).wantOK(t, "init")
}

type configEntry struct {
	ID      string `json:"id"`
	Existed bool   `json:"existed"`
}

type initData struct {
	Database string        `json:"database"`
	Actor    string        `json:"actor"`
	Scopes   []configEntry `json:"scopes"`
	Profiles []configEntry `json:"profiles"`
}

type scopeData struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
}

type captureData struct {
	ID           string `json:"id"`
	Scope        string `json:"scope"`
	OriginalText string `json:"original_text"`
	State        string `json:"processing_state"`
	Revision     int64  `json:"revision"`
}

type workItemData struct {
	ID              string            `json:"id"`
	Scope           string            `json:"scope"`
	Title           string            `json:"title"`
	OriginCaptureID string            `json:"origin_capture_id"`
	Lifecycle       string            `json:"lifecycle"`
	WaitingOn       string            `json:"waiting_on"`
	Resolution      string            `json:"resolution"`
	ClosureKind     string            `json:"closure_kind"`
	Revision        int64             `json:"revision"`
	CustomFields    map[string]string `json:"custom_fields"`
}

type processData struct {
	Capture   captureData    `json:"capture"`
	WorkItems []workItemData `json:"work_items"`
}

type planData struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	Revision int64  `json:"revision"`
	Items    []struct {
		WorkItemID string `json:"work_item_id"`
		Role       string `json:"role"`
	} `json:"items"`
}

type prepareData struct {
	Date string         `json:"date"`
	Next []workItemData `json:"next"`
	Plan *planData      `json:"plan"`
}

type focusStartData struct {
	Focus struct {
		ID         string `json:"id"`
		WorkItemID string `json:"work_item_id"`
	} `json:"focus"`
}

type focusData struct {
	ID         string  `json:"id"`
	WorkItemID string  `json:"work_item_id"`
	EndedAt    *string `json:"ended_at"`
}

type checkpointData struct {
	ID         string `json:"id"`
	WorkItemID string `json:"work_item_id"`
	Result     string `json:"result"`
}

type reviewData struct {
	ID              string `json:"id"`
	Kind            string `json:"kind"`
	CompletionState string `json:"completion_state"`
}

type sourceData struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Scope     string `json:"scope"`
	Kind      string `json:"kind"`
	Connector string `json:"connector"`
	Provider  string `json:"provider"`
	Cadence   string `json:"cadence"`
	Coverage  string `json:"coverage"`
	Cursor    string `json:"cursor"`
}

type sourceReviewData struct {
	Review struct {
		ID         string `json:"id"`
		SourceID   string `json:"source_id"`
		BatchID    string `json:"batch_id"`
		ResultKind string `json:"result_kind"`
		Coverage   string `json:"coverage"`
	} `json:"review"`
	Captures []captureData `json:"captures"`
}

type checkData struct {
	OK     bool     `json:"ok"`
	Errors []string `json:"errors"`
}

type statusData struct {
	Database        string   `json:"database"`
	Profile         string   `json:"profile"`
	Actor           string   `json:"actor"`
	Scopes          []string `json:"scopes"`
	EffectiveScopes []string `json:"effective_scopes"`
	Binding         any      `json:"binding"`
	Warning         string   `json:"warning"`
}

type routineData struct {
	ID string `json:"id"`
}

type restoreData struct {
	Tables map[string]int `json:"tables"`
}

var (
	captureIDRe  = regexp.MustCompile(`^C-\d{8}-\d{3,}$`)
	workItemIDRe = regexp.MustCompile(`^T-\d{8}-\d{3,}$`)
	focusIDRe    = regexp.MustCompile(`^F-\d{8}-\d{3,}$`)
)

// TestPass2Journey walks the whole Pass 2 flow through separate processes:
// capture -> inbox -> process -> prepare -> plan -> focus -> review -> find ->
// check -> export -> restore -> check.
func TestPass2Journey(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	period := time.Now().UTC().Format("2006-01-02")

	initD := decode[initData](t, run(t, db, initArgs...).wantOK(t, "init"))
	if initD.Database != db || initD.Actor != "ztd-test" {
		t.Fatalf("init data = %+v, want database %q actor ztd-test", initD, db)
	}
	if len(initD.Scopes) != 2 || len(initD.Profiles) != 1 || initD.Profiles[0].ID != "personal" {
		t.Fatalf("init scopes/profiles = %+v, want two scopes and profile personal", initD)
	}

	cap := decode[captureData](t, run(t, db, "capture", "write the quarterly report").wantOK(t, "capture"))
	if !captureIDRe.MatchString(cap.ID) {
		t.Fatalf("capture id = %q, want C-YYYYMMDD-NNN", cap.ID)
	}
	if cap.State != "pending" || cap.Revision != 1 || cap.Scope != "personal" {
		t.Fatalf("capture = %+v, want pending revision 1 in personal", cap)
	}
	if cap.OriginalText != "write the quarterly report" {
		t.Fatalf("original_text = %q", cap.OriginalText)
	}

	next := decode[captureData](t, run(t, db, "inbox", "next").wantOK(t, "inbox next"))
	if next.ID != cap.ID {
		t.Fatalf("inbox next id = %q, want the captured %q", next.ID, cap.ID)
	}

	// Flags must precede the positional ID: Go's flag package stops parsing at
	// the first non-flag argument.
	pr := decode[processData](t, run(t, db, "process",
		"--outcome", "work_items", "--title", "Draft quarterly report", cap.ID).wantOK(t, "process"))
	if pr.Capture.ID != cap.ID || pr.Capture.State != "processed" || pr.Capture.Revision != 2 {
		t.Fatalf("processed capture = %+v, want %s processed revision 2", pr.Capture, cap.ID)
	}
	if len(pr.WorkItems) != 1 {
		t.Fatalf("work items = %d, want 1", len(pr.WorkItems))
	}
	item := pr.WorkItems[0]
	if !workItemIDRe.MatchString(item.ID) || item.Lifecycle != "next" {
		t.Fatalf("work item = %+v, want a next T-YYYYMMDD-NNN", item)
	}
	if item.OriginCaptureID != cap.ID || item.Title != "Draft quarterly report" {
		t.Fatalf("work item origin/title = %q/%q", item.OriginCaptureID, item.Title)
	}

	brief := decode[prepareData](t, run(t, db, "prepare", "--date", period).wantOK(t, "prepare"))
	if brief.Date != period || brief.Plan != nil {
		t.Fatalf("prepare = %+v, want date %s and no plan yet", brief, period)
	}
	if !containsID(brief.Next, item.ID) {
		t.Fatalf("prepare next = %+v, want %s", brief.Next, item.ID)
	}

	plan := decode[planData](t, run(t, db, "plan", "commit",
		"--period", period, "--item", item.ID+":mit").wantOK(t, "plan commit"))
	if plan.ID != "P-personal-daily-"+period || plan.Status != "committed" || plan.Revision != 1 {
		t.Fatalf("plan = %+v, want committed revision 1 for %s", plan, period)
	}
	if len(plan.Items) != 1 || plan.Items[0].WorkItemID != item.ID || plan.Items[0].Role != "mit" {
		t.Fatalf("plan items = %+v, want [%s mit]", plan.Items, item.ID)
	}

	fs := decode[focusStartData](t, run(t, db, "focus", "start", item.ID).wantOK(t, "focus start"))
	if !focusIDRe.MatchString(fs.Focus.ID) || fs.Focus.WorkItemID != item.ID {
		t.Fatalf("focus start = %+v, want F-YYYYMMDD-NNN on %s", fs.Focus, item.ID)
	}

	cp := decode[checkpointData](t, run(t, db, "focus", "checkpoint",
		"--result", "halfway through", item.ID).wantOK(t, "focus checkpoint"))
	if cp.WorkItemID != item.ID || cp.Result != "halfway through" {
		t.Fatalf("checkpoint = %+v, want result on %s", cp, item.ID)
	}

	fin := decode[focusData](t, run(t, db, "focus", "finish",
		"--outcome", "done for now", fs.Focus.ID).wantOK(t, "focus finish"))
	if fin.ID != fs.Focus.ID || fin.EndedAt == nil {
		t.Fatalf("focus finish = %+v, want %s with ended_at", fin, fs.Focus.ID)
	}

	rev := decode[reviewData](t, run(t, db, "review", "daily",
		"--period", period, "--outcomes", "captured and planned", "--coverage", "inbox+next").wantOK(t, "review"))
	if rev.Kind != "daily" || rev.CompletionState != "complete" {
		t.Fatalf("review = %+v, want a complete daily review", rev)
	}

	found := decode[[]workItemData](t, run(t, db, "find", "quarterly").wantOK(t, "find"))
	if !containsID(found, item.ID) {
		t.Fatalf("find = %+v, want %s", found, item.ID)
	}

	chk := decode[checkData](t, run(t, db, "check").wantOK(t, "check"))
	if !chk.OK {
		t.Fatalf("check errors: %v", chk.Errors)
	}

	exportPath := filepath.Join(t.TempDir(), "export.json")
	run(t, db, "export", "--out", exportPath).wantOK(t, "export")
	if st, err := os.Stat(exportPath); err != nil || st.Size() == 0 {
		t.Fatalf("export file missing or empty: %v", err)
	}

	restoredDB := filepath.Join(t.TempDir(), "restored.db")
	rest := decode[restoreData](t, run(t, restoredDB, "restore", "--from", exportPath).wantOK(t, "restore"))
	for table, want := range map[string]int{
		"scopes": 2, "profiles": 1, "captures": 1, "work_items": 1,
		"plans": 1, "plan_items": 1, "reviews": 1, "focus_sessions": 1, "checkpoints": 1,
	} {
		if rest.Tables[table] != want {
			t.Errorf("restored %s = %d, want %d", table, rest.Tables[table], want)
		}
	}

	chk = decode[checkData](t, run(t, restoredDB, "check").wantOK(t, "check"))
	if !chk.OK {
		t.Fatalf("check on restored db: %v", chk.Errors)
	}
}

// TestPlanCommitRejectsFourMITs pins the daily MIT limit: a fourth MIT without
// an override fails, rolls back nothing because no plan row exists yet, and a
// three-MIT commit then succeeds.
func TestPlanCommitRejectsFourMITs(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	period := time.Now().UTC().Format("2006-01-02")

	initDB(t, db)
	cap := decode[captureData](t, run(t, db, "capture", "four things to plan").wantOK(t, "capture"))
	pr := decode[processData](t, run(t, db, "process",
		"--outcome", "work_items",
		"--title", "mit one", "--title", "mit two", "--title", "mit three", "--title", "mit four",
		cap.ID).wantOK(t, "process"))
	if len(pr.WorkItems) != 4 {
		t.Fatalf("work items = %d, want 4", len(pr.WorkItems))
	}
	items := make([]string, 0, 4)
	for _, w := range pr.WorkItems {
		items = append(items, w.ID)
	}

	four := []string{"plan", "commit", "--period", period}
	for _, id := range items {
		four = append(four, "--item", id+":mit")
	}
	// app.Service rejects a fourth MIT as rules_acknowledgement_required — the
	// override rule, not malformed input — and the failed commit writes nothing.
	run(t, db, four...).wantErr(t, 1, "plan", "rules_acknowledgement_required")

	brief := decode[prepareData](t, run(t, db, "prepare", "--date", period).wantOK(t, "prepare"))
	if brief.Plan != nil {
		t.Fatalf("rejected commit left a plan: %+v", brief.Plan)
	}

	three := []string{"plan", "commit", "--period", period}
	for _, id := range items[:3] {
		three = append(three, "--item", id+":mit")
	}
	plan := decode[planData](t, run(t, db, three...).wantOK(t, "plan commit"))
	if plan.Revision != 1 || len(plan.Items) != 3 {
		t.Fatalf("three-MIT plan = %+v, want revision 1 with 3 items", plan)
	}
}

// TestScopeIsolation proves a capture taken in one scope is invisible to
// commands bound to another scope of the implicit profile.
func TestScopeIsolation(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	cap := decode[captureData](t, run(t, db, "capture", "--scope", "opensource", "unique os note").wantOK(t, "capture"))
	if cap.Scope != "opensource" {
		t.Fatalf("capture scope = %q, want opensource", cap.Scope)
	}

	// The personal inbox cannot see the pending opensource capture.
	run(t, db, "inbox", "next", "--scope", "personal").wantErr(t, 1, "inbox", "not_found")
	next := decode[captureData](t, run(t, db, "inbox", "next", "--scope", "opensource").wantOK(t, "inbox next"))
	if next.ID != cap.ID {
		t.Fatalf("opensource inbox next = %q, want %q", next.ID, cap.ID)
	}

	// Existing rows stay out of scope rather than leaking as not_found.
	run(t, db, "show", "--scope", "personal", cap.ID).wantErr(t, 1, "show", "scope_denied")

	pr := decode[processData](t, run(t, db, "process", "--scope", "opensource",
		"--outcome", "work_items", "--title", "os-only task", cap.ID).wantOK(t, "process"))
	itemID := pr.WorkItems[0].ID
	run(t, db, "show", "--scope", "personal", itemID).wantErr(t, 1, "show", "scope_denied")

	personal := decode[[]workItemData](t, run(t, db, "find", "--scope", "personal", "os-only").wantOK(t, "find"))
	if len(personal) != 0 {
		t.Fatalf("personal find = %+v, want empty", personal)
	}
	scoped := decode[[]workItemData](t, run(t, db, "find", "--scope", "opensource", "os-only").wantOK(t, "find"))
	if len(scoped) != 1 || scoped[0].ID != itemID {
		t.Fatalf("opensource find = %+v, want [%s]", scoped, itemID)
	}
}

func containsID(items []workItemData, id string) bool {
	for _, it := range items {
		if it.ID == id {
			return true
		}
	}
	return false
}

// TestSourceFlow walks the operator-facing source boundary: register a
// source, list it, feed one reported batch from a temp JSON file, and prove
// that observed coverage is refused by the service.
func TestSourceApply(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	writeConfig := func(body string) string {
		path := filepath.Join(t.TempDir(), "sources.json")
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("write sources: %v", err)
		}
		return path
	}
	config := `{"sources":[
	  {"id":"github","name":"GitHub notifications","scope":"personal","kind":"capture","connector":"host_mcp","provider":"github","connection_ref":"github-main","cadence":"daily"},
	  {"id":"notes","name":"Notes directory","scope":"personal","kind":"capture","connector":"directory","non_secret_query":"~/notes"}
	]}`
	path := writeConfig(config)
	applied := decode[[]sourceData](t, run(t, db, "source", "apply", "--file", path).wantOK(t, "source apply"))
	if len(applied) != 2 || applied[0].ID != "github" || applied[1].ID != "notes" {
		t.Fatalf("apply = %+v, want github and notes", applied)
	}
	list := decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 2 || list[0].Provider != "github" || list[1].Connector != "directory" {
		t.Fatalf("list = %+v, want configured sources", list)
	}

	// Reapplying a changed name updates in place; reapplying unchanged data
	// stays a no-op and never duplicates.
	config = strings.Replace(config, `"name":"GitHub notifications"`, `"name":"GitHub triage"`, 1)
	path = writeConfig(config)
	run(t, db, "source", "apply", "--file", path).wantOK(t, "source apply")
	run(t, db, "source", "apply", "--file", path).wantOK(t, "source apply")
	list = decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 2 || list[0].Name != "GitHub triage" {
		t.Fatalf("list after update = %+v, want two sources and renamed github", list)
	}

	// Provider-specific code does not exist: an unknown connector is rejected
	// as generic invalid input.
	bad := writeConfig(`{"sources":[{"id":"bad","name":"Bad","scope":"personal","kind":"capture","connector":"carrier_pigeon"}]}`)
	run(t, db, "source", "apply", "--file", bad).wantErr(t, 1, "source", "invalid_input")
}

func TestSourceApplyDefaultsToHome(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	home := t.TempDir()
	runHome(t, home, db, initArgs...).wantOK(t, "init")

	dir := filepath.Join(home, ".ztd")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(dir, "sources.json")
	if err := os.WriteFile(path, []byte(`{"sources":[{"id":"notes","name":"Notes","scope":"personal","kind":"capture","connector":"directory"}]}`), 0o644); err != nil {
		t.Fatalf("write sources: %v", err)
	}
	runHome(t, home, db, "source", "apply").wantOK(t, "source apply")
	list := decode[[]sourceData](t, runHome(t, home, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 1 || list[0].ID != "notes" {
		t.Fatalf("list = %+v, want notes from ~/.ztd/sources.json", list)
	}
}

func TestSourceFlow(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	add := decode[sourceData](t, run(t, db, "source", "add",
		"--id", "notes-dir", "--name", "Notes directory",
		"--scope", "personal", "--kind", "capture", "--connector", "directory",
		"--cadence", "daily").wantOK(t, "source add"))
	if add.ID != "notes-dir" || add.Name != "Notes directory" || add.Scope != "personal" {
		t.Fatalf("source = %+v, want notes-dir in personal", add)
	}
	if add.Kind != "capture" || add.Connector != "directory" || add.Cadence != "daily" {
		t.Fatalf("source = %+v, want capture/directory/daily", add)
	}
	if add.Coverage != "unknown" {
		t.Fatalf("coverage = %q, want unknown before any batch", add.Coverage)
	}

	list := decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 1 || list[0].ID != "notes-dir" {
		t.Fatalf("source list = %+v, want [notes-dir]", list)
	}

	batchPath := filepath.Join(t.TempDir(), "batch.json")
	batch := `{
  "source_id": "notes-dir",
  "batch_id": "batch-1",
  "idempotency_key": "cli-source-1",
  "result_kind": "reported",
  "retrieval": {
    "window": "2026-11-20",
    "cursor": "",
    "requested_limit": 50,
    "provider_returned_limit": 1,
    "complete_window": true,
    "truncated": false,
    "failures": []
  },
  "items": [
    {
      "external_id": "note-001",
      "external_revision": "1",
      "original_text": "renew the parking permit before the trip",
      "source_uri": "file:///notes/note-001.md"
    }
  ]
}`
	if err := os.WriteFile(batchPath, []byte(batch), 0o644); err != nil {
		t.Fatalf("write batch: %v", err)
	}

	rev := decode[sourceReviewData](t, run(t, db, "source", "review",
		"--source", "notes-dir", "--batch", "batch-1", "--key", "cli-source-1",
		"--file", batchPath).wantOK(t, "source review"))
	if rev.Review.SourceID != "notes-dir" || rev.Review.ResultKind != "reported" {
		t.Fatalf("review = %+v, want a reported review for notes-dir", rev.Review)
	}
	if rev.Review.Coverage != "unverified" {
		t.Fatalf("coverage = %q, want unverified", rev.Review.Coverage)
	}
	if len(rev.Captures) != 1 || rev.Captures[0].OriginalText != "renew the parking permit before the trip" {
		t.Fatalf("captures = %+v, want one capture of the reported item", rev.Captures)
	}

	// The batch updated the source coverage to unverified.
	list = decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(list) != 1 || list[0].Coverage != "unverified" {
		t.Fatalf("source list after batch = %+v, want coverage unverified", list)
	}

	// observed is refused: no trusted host adapter exists on this path.
	observedPath := filepath.Join(t.TempDir(), "observed.json")
	observed := `{
  "source_id": "notes-dir",
  "batch_id": "batch-2",
  "idempotency_key": "cli-source-observed",
  "result_kind": "observed",
  "retrieval": {"window": "", "cursor": "", "requested_limit": 0, "provider_returned_limit": 0, "complete_window": false, "truncated": false, "failures": []},
  "items": []
}`
	if err := os.WriteFile(observedPath, []byte(observed), 0o644); err != nil {
		t.Fatalf("write observed batch: %v", err)
	}
	// The error envelope carries the top-level command, like plan commit.
	run(t, db, "source", "review",
		"--source", "notes-dir", "--batch", "batch-2", "--key", "cli-source-observed",
		"--file", observedPath).wantErr(t, 1, "source", "invalid_input")
}

// fourScopeArgs declares four scopes — personal, opensource, trabajo and
// salud — so a test can exercise multi-scope bindings; init creates the
// implicit personal profile over all of them.
var fourScopeArgs = []string{
	"init",
	"--scope", "id=personal,kind=personal",
	"--scope", "id=opensource,kind=opensource",
	"--scope", "id=trabajo,kind=work",
	"--scope", "id=salud,kind=personal,name=Salud",
}

func initFourScopes(t *testing.T, db string) {
	t.Helper()
	run(t, db, fourScopeArgs...).wantOK(t, "init")
}

// writeSources writes one throwaway source configuration file.
func writeSources(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sources.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write sources: %v", err)
	}
	return path
}

// TestInitNonInteractive pins the flag-driven init: no prompt, the implicit
// personal profile over the declared scopes, everything applied as one batch.
func TestInitNonInteractive(t *testing.T) {
	t.Run("no flags and no terminal fails without creating a database", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "ztd.db")
		run(t, db, "init").wantErr(t, 1, "init", "invalid_input")
		run(t, db, "init", "--non-interactive").wantErr(t, 1, "init", "invalid_input")
		if _, err := os.Stat(db); !os.IsNotExist(err) {
			t.Fatalf("init without declarations created %s (err %v)", db, err)
		}
	})

	t.Run("a --profile flag is rejected", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "ztd.db")
		run(t, db, "init",
			"--scope", "id=personal,kind=personal",
			"--profile", "id=personal,kind=personal,scopes=personal").
			wantErr(t, 1, "init", "invalid_input")
		if _, err := os.Stat(db); !os.IsNotExist(err) {
			t.Fatalf("rejected init created %s (err %v)", db, err)
		}
	})

	t.Run("an existing database is preserved and a repeat is idempotent", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "ztd.db")
		first := decode[initData](t, run(t, db, initArgs...).wantOK(t, "init"))
		if len(first.Scopes) != 2 || first.Scopes[0].Existed ||
			len(first.Profiles) != 1 || first.Profiles[0].ID != "personal" || first.Profiles[0].Existed {
			t.Fatalf("first init = %+v, want two new scopes and the new implicit profile personal", first)
		}
		second := decode[initData](t, run(t, db, initArgs...).wantOK(t, "init"))
		for _, e := range append(second.Scopes, second.Profiles...) {
			if !e.Existed {
				t.Fatalf("repeat init entry %s = new, want it to already exist", e.ID)
			}
		}

		// A further scope is added with scope add; it does not rewrite the
		// existing scopes or the implicit profile.
		run(t, db, "scope", "add", "--id", "salud", "--kind", "personal").wantOK(t, "scope add")
		scopes := decode[[]scopeData](t, run(t, db, "scope", "list").wantOK(t, "scope list"))
		want := []string{"opensource", "personal", "salud"}
		if len(scopes) != len(want) {
			t.Fatalf("scopes = %+v, want %v", scopes, want)
		}
		for i, id := range want {
			if scopes[i].ID != id {
				t.Fatalf("scopes[%d] = %s, want %s", i, scopes[i].ID, id)
			}
		}
		// The original declaration still applies unchanged.
		run(t, db, initArgs...).wantOK(t, "init")
	})

	t.Run("a new scope extends the implicit profile", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "ztd.db")
		initDB(t, db)

		run(t, db, "init", "--scope", "id=salud,kind=personal").wantOK(t, "init")
		run(t, db, "capture", "--scope", "salud", "health capture").
			wantOK(t, "capture")
	})

	t.Run("a conflicting entry rolls back the whole batch", func(t *testing.T) {
		db := filepath.Join(t.TempDir(), "ztd.db")
		initDB(t, db)

		// The new scope is declared before the conflicting kind is detected,
		// so a partial write would leave it behind.
		run(t, db, "init", "--scope", "id=salud,kind=personal",
			"--scope", "id=personal,kind=work").
			wantErr(t, 1, "init", "conflict")
		scopes := decode[[]scopeData](t, run(t, db, "scope", "list").wantOK(t, "scope list"))
		if len(scopes) != 2 || scopes[0].ID != "opensource" || scopes[1].ID != "personal" {
			t.Fatalf("scopes after conflict = %+v, want the original two", scopes)
		}
		// The original declaration still applies: nothing was clobbered.
		run(t, db, initArgs...).wantOK(t, "init")
	})
}

// TestScopeCommands covers the operator-facing scope command: create,
// idempotent re-add, conflicts and ordered listings. The profile subcommands
// are gone: an implicit personal profile is the only planning profile.
func TestScopeCommands(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")

	add := decode[scopeData](t, run(t, db, "scope", "add",
		"--id", "salud", "--kind", "personal", "--name", "Salud").wantOK(t, "scope add"))
	if add.ID != "salud" || add.Kind != "personal" || add.Name != "Salud" {
		t.Fatalf("scope = %+v, want salud/personal/Salud", add)
	}
	// The identical declaration again is a no-op; another kind or name is
	// conflict, and neither rewrites the row.
	run(t, db, "scope", "add", "--id", "salud", "--kind", "personal", "--name", "Salud").wantOK(t, "scope add")
	run(t, db, "scope", "add", "--id", "salud", "--kind", "work").wantErr(t, 1, "scope", "conflict")
	run(t, db, "scope", "add", "--id", "salud", "--kind", "personal", "--name", "Health").wantErr(t, 1, "scope", "conflict")

	run(t, db, "scope", "add", "--id", "personal", "--kind", "personal").wantOK(t, "scope add")
	run(t, db, "scope", "add", "--id", "client:prisamedia", "--kind", "client").wantOK(t, "scope add")
	list := decode[[]scopeData](t, run(t, db, "scope", "list").wantOK(t, "scope list"))
	want := []string{"client:prisamedia", "personal", "salud"}
	if len(list) != len(want) {
		t.Fatalf("scope list = %+v, want %v", list, want)
	}
	for i, id := range want {
		if list[i].ID != id {
			t.Fatalf("scope list[%d] = %s, want %s (ordered by id)", i, list[i].ID, id)
		}
	}

	// There is no profile command any more: the dispatcher refuses it.
	run(t, db, "profile", "list").wantErr(t, 1, "profile", "invalid_input")
	run(t, db, "profile", "add",
		"--id", "personal", "--kind", "personal", "--scope", "personal").
		wantErr(t, 1, "profile", "invalid_input")
	run(t, db, "profile", "set", "--id", "personal", "--scope", "personal").
		wantErr(t, 1, "profile", "invalid_input")
}

// TestSourceApplyMultiScope walks the operator path: one file spanning four
// scopes, a missing scope refused before any write, and no --profile axis.
func TestSourceApplyMultiScope(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initFourScopes(t, db)

	path := writeSources(t, `{"sources":[
	  {"id":"gh","name":"GitHub","scope":"personal","kind":"capture","connector":"host_mcp","provider":"github"},
	  {"id":"os-notes","name":"OS notes","scope":"opensource","kind":"capture","connector":"directory"},
	  {"id":"jira","name":"Jira","scope":"trabajo","kind":"capture","connector":"host_mcp","provider":"jira"},
	  {"id":"health","name":"Health notes","scope":"salud","kind":"capture","connector":"directory"}
	]}`)
	applied := decode[[]sourceData](t, run(t, db, "source", "apply", "--file", path).wantOK(t, "source apply"))
	if len(applied) != 4 {
		t.Fatalf("apply = %+v, want four sources", applied)
	}
	byID := map[string]string{}
	for _, s := range applied {
		byID[s.ID] = s.Scope
	}
	for id, scope := range map[string]string{
		"gh": "personal", "os-notes": "opensource", "jira": "trabajo", "health": "salud",
	} {
		if byID[id] != scope {
			t.Errorf("source %s scope = %q, want %q", id, byID[id], scope)
		}
	}

	// A scope the file invents fails before anything is written.
	bad := writeSources(t, `{"sources":[
	  {"id":"ghost","name":"Ghost","scope":"ghost","kind":"capture","connector":"directory"}
	]}`)
	run(t, db, "source", "apply", "--file", bad).wantErr(t, 1, "source", "invalid_input")
	all := decode[[]sourceData](t, run(t, db, "source", "list", "--all").wantOK(t, "source list"))
	if len(all) != 4 {
		t.Fatalf("list after refused apply = %+v, want the original four", all)
	}

	// There is no --profile axis: the binding comes from the file.
	run(t, db, "source", "apply", "--file", path, "--profile", "personal").
		wantErr(t, 1, "source", "invalid_input")
}

// TestSourceAddScope pins the operator-facing add: the scope is explicit,
// unknown scopes are refused, and the listing honours the requested scope.
func TestSourceAddScope(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initFourScopes(t, db)

	add := decode[sourceData](t, run(t, db, "source", "add",
		"--id", "notes-dir", "--name", "Notes directory",
		"--scope", "salud", "--kind", "capture", "--connector", "directory").wantOK(t, "source add"))
	if add.ID != "notes-dir" || add.Scope != "salud" {
		t.Fatalf("source = %+v, want notes-dir in salud", add)
	}

	run(t, db, "source", "add",
		"--id", "ghost-dir", "--name", "Ghost",
		"--scope", "ghost", "--kind", "capture", "--connector", "directory").
		wantErr(t, 1, "source", "invalid_input")

	inside := decode[[]sourceData](t, run(t, db, "source", "list", "--scope", "salud").wantOK(t, "source list"))
	if len(inside) != 1 || inside[0].ID != "notes-dir" {
		t.Fatalf("salud list = %+v, want [notes-dir]", inside)
	}
	outside := decode[[]sourceData](t, run(t, db, "source", "list", "--scope", "personal").wantOK(t, "source list"))
	if len(outside) != 0 {
		t.Fatalf("personal list = %+v, want empty", outside)
	}
}

// TestSourceListFilters pins the two selectors: --all (also the default) and
// repeated --scope. They never combine, and --profile is gone.
func TestSourceListFilters(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initFourScopes(t, db)
	for _, s := range []struct{ id, scope string }{
		{"in-personal", "personal"},
		{"in-opensource", "opensource"},
		{"in-trabajo", "trabajo"},
		{"in-salud", "salud"},
	} {
		run(t, db, "source", "add", "--id", s.id, "--name", s.id,
			"--scope", s.scope, "--kind", "capture", "--connector", "directory").
			wantOK(t, "source add")
	}

	all := decode[[]sourceData](t, run(t, db, "source", "list", "--all").wantOK(t, "source list"))
	if len(all) != 4 {
		t.Fatalf("--all = %+v, want four sources", all)
	}
	bare := decode[[]sourceData](t, run(t, db, "source", "list").wantOK(t, "source list"))
	if len(bare) != 4 {
		t.Fatalf("bare list = %+v, want the operator view of every scope", bare)
	}
	one := decode[[]sourceData](t, run(t, db, "source", "list", "--scope", "trabajo").wantOK(t, "source list"))
	if len(one) != 1 || one[0].ID != "in-trabajo" {
		t.Fatalf("--scope trabajo = %+v, want [in-trabajo]", one)
	}
	two := decode[[]sourceData](t, run(t, db, "source", "list",
		"--scope", "personal", "--scope", "salud").wantOK(t, "source list"))
	if len(two) != 2 || two[0].ID != "in-personal" || two[1].ID != "in-salud" {
		t.Fatalf("two scopes = %+v, want in-personal and in-salud", two)
	}
	run(t, db, "source", "list", "--all", "--scope", "personal").wantErr(t, 1, "source", "invalid_input")
	// --profile is gone: the flag is rejected outright.
	run(t, db, "source", "list", "--profile", "personal").wantErr(t, 1, "source", "invalid_input")
	run(t, db, "source", "list", "--profile", "personal", "--scope", "salud").wantErr(t, 1, "source", "invalid_input")
}

// TestMCPUsesImplicitProfile pins the mcp command: it takes no --profile, a
// database without the implicit profile fails with not_found, and an unknown
// --profile flag is rejected before the server starts. Starting the server
// without flags is covered by mcp_test.go's mcpConnect.
func TestMCPUsesImplicitProfile(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	run(t, db, "mcp").wantErr(t, 1, "mcp", "not_found")
	run(t, db, "mcp", "--profile", "personal").wantErr(t, 1, "mcp", "invalid_input")

	// With the implicit profile in place the same bare command passes the
	// binding step; --scope still narrows it.
	initDB(t, db)
	run(t, db, "mcp", "--scope", "ghost").wantErr(t, 1, "mcp", "scope_denied")
	run(t, db, "mcp", "--profile", "personal").wantErr(t, 1, "mcp", "invalid_input")
}

// TestListMoveStatusAndAliases walks the compatibility slice end to end:
// list, move through waiting and archive, status, and the due/routine done
// aliases of the routines commands.
func TestListMoveStatusAndAliases(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)

	cap := decode[captureData](t, run(t, db, "capture", "renew the passport").wantOK(t, "capture"))
	pr := decode[processData](t, run(t, db, "process",
		"--outcome", "work_items", "--title", "call the passport office", cap.ID).wantOK(t, "process"))
	itemID := pr.WorkItems[0].ID

	// list --list next shows the fresh item; an empty list is an empty array.
	next := decode[[]workItemData](t, run(t, db, "list", "--list", "next").wantOK(t, "list"))
	if !containsID(next, itemID) {
		t.Fatalf("list --list next = %+v, want %s", next, itemID)
	}
	if got := decode[[]workItemData](t, run(t, db, "list", "--list", "someday").wantOK(t, "list")); len(got) != 0 {
		t.Fatalf("list --list someday = %+v, want empty", got)
	}
	if got := decode[[]captureData](t, run(t, db, "list", "--list", "inbox").wantOK(t, "list")); len(got) != 0 {
		t.Fatalf("list --list inbox = %+v, want empty", got)
	}
	run(t, db, "list", "--list", "trash").wantErr(t, 1, "list", "invalid_input")

	// Move to waiting: flags may follow the positionals, as documented.
	waiting := decode[workItemData](t, run(t, db, "move", itemID, "waiting",
		"--waiting-on", "the office", "--field", "siguiente:draft section 2").wantOK(t, "move"))
	if waiting.Lifecycle != "waiting" || waiting.Revision != 2 {
		t.Fatalf("move to waiting = %+v, want waiting revision 2", waiting)
	}
	if waiting.CustomFields["siguiente"] != "draft section 2" {
		t.Fatalf("custom fields after move = %v", waiting.CustomFields)
	}
	inWaiting := decode[[]workItemData](t, run(t, db, "list", "--list", "waiting").wantOK(t, "list"))
	if !containsID(inWaiting, itemID) {
		t.Fatalf("list --list waiting = %+v, want %s", inWaiting, itemID)
	}
	if stillNext := decode[[]workItemData](t, run(t, db, "list", "--list", "next").wantOK(t, "list")); containsID(stillNext, itemID) {
		t.Fatalf("moved item still in next: %+v", stillNext)
	}

	// Rejections: waiting needs waiting_on, structural field keys are refused,
	// inbox is not a move target.
	run(t, db, "move", itemID, "waiting").wantErr(t, 1, "move", "invalid_input")
	run(t, db, "move", itemID, "next", "--field", "context:personal").
		wantErr(t, 1, "move", "invalid_input")
	run(t, db, "move", itemID, "inbox").wantErr(t, 1, "move", "invalid_input")

	// Back to next (flags first this time), then exercise the legacy field
	// spelling that maps waiting_on/resolution to their columns.
	back := decode[workItemData](t, run(t, db, "move", "--key", "back-to-next", itemID, "next").wantOK(t, "move"))
	if back.Lifecycle != "next" || back.Revision != 3 || back.WaitingOn != "" {
		t.Fatalf("move back to next = %+v, want next revision 3 without waiting_on", back)
	}
	fieldWaiting := decode[workItemData](t, run(t, db, "move", "--key", "field-waiting", itemID,
		"waiting", "--field", "waiting_on:someone").wantOK(t, "move"))
	if fieldWaiting.Lifecycle != "waiting" || fieldWaiting.Revision != 4 || fieldWaiting.WaitingOn != "someone" {
		t.Fatalf("move with waiting_on field = %+v, want waiting revision 4", fieldWaiting)
	}
	fieldNext := decode[workItemData](t, run(t, db, "move", "--key", "field-next", itemID, "next").wantOK(t, "move"))
	if fieldNext.Lifecycle != "next" || fieldNext.Revision != 5 {
		t.Fatalf("move back to next = %+v, want next revision 5", fieldNext)
	}
	// plan without a subcommand is the read-only brief; --context filters it.
	if brief := decode[prepareData](t, run(t, db, "plan").wantOK(t, "plan")); !containsID(brief.Next, itemID) {
		t.Fatalf("plan next = %+v, want %s", brief.Next, itemID)
	}
	if brief := decode[prepareData](t, run(t, db, "plan", "--context", "familia").wantOK(t, "plan")); containsID(brief.Next, itemID) {
		t.Fatalf("plan --context familia = %+v, want no unfiltered item", brief.Next)
	}
	if rec := decode[map[string]any](t, run(t, db, "recover").wantOK(t, "recover")); rec["recovered"] != false {
		t.Fatalf("recover = %+v, want recovered false", rec)
	}
	run(t, db, "move", itemID, "archive").wantErr(t, 1, "move", "invalid_input")
	archived := decode[workItemData](t, run(t, db, "move", itemID, "archive",
		"--field", "resolution:done at the counter").wantOK(t, "move"))
	if archived.Lifecycle != "archived" || archived.Revision != 6 || archived.Resolution != "done at the counter" {
		t.Fatalf("move to archive = %+v, want archived revision 6", archived)
	}
	// A stale --expected writes nothing.
	stale := run(t, db, "move", "--expected", "99", itemID, "next")
	stale.wantErr(t, 1, "move", "stale_revision")
	// A replayed key with a different payload conflicts.
	run(t, db, "move", "--key", "back-to-next", itemID, "someday").
		wantErr(t, 1, "move", "idempotency_conflict")

	// status reports the environment and null binding without .ztd.json.
	status := decode[statusData](t, run(t, db, "status").wantOK(t, "status"))
	if status.Database != db || status.Profile != "personal" || status.Actor != "ztd-test" {
		t.Fatalf("status = %+v, want database %q profile personal actor ztd-test", status, db)
	}
	if len(status.Scopes) != 2 || status.Scopes[0] != "opensource" || status.Scopes[1] != "personal" {
		t.Fatalf("status scopes = %v, want [opensource personal]", status.Scopes)
	}
	// effective_scopes is the default binding: the profile's scopes, in
	// declaration order, for a command with no explicit --scope.
	if len(status.EffectiveScopes) != 2 ||
		status.EffectiveScopes[0] != "personal" || status.EffectiveScopes[1] != "opensource" {
		t.Fatalf("status effective scopes = %v, want [personal opensource]", status.EffectiveScopes)
	}
	if status.Binding != nil {
		t.Fatalf("status binding = %+v, want null without .ztd.json", status.Binding)
	}
	if !strings.Contains(status.Warning, ".ztd.json") {
		t.Fatalf("status warning = %q, want the .ztd.json hint", status.Warning)
	}

	// The aliases drive the routines commands. Successes report the routines
	// command they ran; a failure reports the top-level command, like plan
	// commit and source review.
	if due := decode[[]routineData](t, run(t, db, "due").wantOK(t, "routines due")); len(due) != 0 {
		t.Fatalf("due = %+v, want an empty list", due)
	}
	run(t, db, "routine", "done", "nope").wantErr(t, 1, "routine", "not_found")
}
