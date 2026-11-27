// Package corpus records normalized CLI output and database state for fixed
// journeys, then replays them against another binary. ZTD_BIN selects the
// subject (default ./zig-out/bin/ztd); this package catches byte-level
// envelope and schema drift.
package corpus

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

var (
	binPath string
	update  bool
)

func TestMain(m *testing.M) {
	update = os.Getenv("ZTD_UPDATE") == "1"
	if bin := os.Getenv("ZTD_BIN"); bin != "" {
		abs, err := resolveBin(bin)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ZTD_BIN:", err)
			os.Exit(1)
		}
		binPath = abs
	} else {
		// The Go product is retired; the default subject is the Zig build.
		abs, err := resolveBin(filepath.Join(repoRoot(), "zig-out/bin/ztd"))
		if err != nil {
			fmt.Fprintln(os.Stderr, "ZTD_BIN: set it or run `zig build --release=fast` first:", err)
			os.Exit(1)
		}
		binPath = abs
	}
	os.Exit(m.Run())
}

func repoRoot() string {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		panic("runtime.Caller failed")
	}
	return filepath.Dir(filepath.Dir(filepath.Dir(file)))
}

// resolveBin accepts an absolute path or one relative to the repository root,
// because `go test` runs with the package directory as its working directory.
func resolveBin(bin string) (string, error) {
	if !filepath.IsAbs(bin) {
		if p := filepath.Join(repoRoot(), bin); fileExists(p) {
			bin = p
		}
	}
	return filepath.Abs(bin)
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// observation is one normalized invocation: exit status plus the JSON envelope
// the CLI prints, or normalized stderr when it printed no JSON.
type observation struct {
	Exit     int             `json:"exit"`
	Envelope json.RawMessage `json:"envelope,omitempty"`
	Stderr   string          `json:"stderr,omitempty"`

	raw json.RawMessage // unnormalized, for reading generated IDs
}

type session struct {
	Steps []observation                  `json:"steps"`
	DB    map[string][]map[string]string `json:"db,omitempty"`
}

type runner struct {
	t              *testing.T
	db, home, work string
	steps          []observation
}

func newRunner(t *testing.T) *runner {
	t.Helper()
	base := t.TempDir()
	return &runner{t: t, db: filepath.Join(base, "ztd.db"), home: filepath.Join(base, "home"), work: base}
}

// path returns an absolute path inside the runner's work directory.
func (r *runner) path(name string) string { return filepath.Join(r.work, name) }

// write creates a fixture file next to the database.
func (r *runner) write(name, content string) string {
	r.t.Helper()
	p := r.path(name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		r.t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// run executes one invocation with --json and a throwaway HOME.
func (r *runner) run(argv ...string) observation {
	r.t.Helper()
	full := append([]string{"--json", "--db", r.db}, argv...)
	cmd := exec.Command(binPath, full...)
	cmd.Dir = r.work
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + r.home,
		"USERPROFILE=" + r.home,
		"TMPDIR=" + r.t.TempDir(),
		"USER=ztd-corpus",
	}
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	code := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			r.t.Fatalf("run %v: %v (stderr: %s)", full, err, stderr.String())
		}
		code = ee.ExitCode()
	}
	dir := cmd.Env[len(cmd.Env)-2]
	o := observation{Exit: code, Stderr: normalize(stderr.String(), r.work, r.home, strings.TrimPrefix(dir, "TMPDIR="))}
	if trimmed := strings.TrimSpace(stdout.String()); trimmed != "" {
		var buf bytes.Buffer
		if err := json.Compact(&buf, []byte(trimmed)); err != nil {
			r.t.Fatalf("run %v: stdout is not JSON: %v\n%s", full, err, trimmed)
		}
		o.raw = json.RawMessage(buf.String())
		o.Envelope = json.RawMessage(normalize(buf.String(), r.work, r.home, strings.TrimPrefix(dir, "TMPDIR=")))
	}
	r.steps = append(r.steps, o)
	return o
}

// value decodes the envelope and walks a field path; "" when absent.
func (o observation) value(path ...string) string {
	if o.raw == nil {
		return ""
	}
	var v any
	if err := json.Unmarshal(o.raw, &v); err != nil {
		return ""
	}
	for _, p := range path {
		switch x := v.(type) {
		case map[string]any:
			v = x[p]
		case []any:
			var i int
			if _, err := fmt.Sscanf(p, "%d", &i); err != nil || i < 0 || i >= len(x) {
				return ""
			}
			v = x[i]
		default:
			return ""
		}
	}
	s, _ := v.(string)
	return s
}

// id returns data.id for commands that create one.
func (o observation) id() string { return o.value("data", "id") }

func (r *runner) finish(name string) {
	r.t.Helper()
	got := session{Steps: r.steps, DB: dumpDB(r.t, r.db)}
	gotJSON, err := json.MarshalIndent(got, "", "  ")
	if err != nil {
		r.t.Fatalf("marshal golden: %v", err)
	}
	path := filepath.Join(repoRoot(), "test", "corpus", "golden", name+".json")
	if update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			r.t.Fatalf("mkdir golden: %v", err)
		}
		if err := os.WriteFile(path, append(gotJSON, '\n'), 0o644); err != nil {
			r.t.Fatalf("write golden: %v", err)
		}
		r.t.Logf("recorded %s", path)
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		r.t.Fatalf("read golden (run ZTD_UPDATE=1 once): %v", err)
	}
	if diff := compareSession(want, got); diff != "" {
		r.t.Fatalf("golden %s differs: %s", name, diff)
	}
}

// firstDiff reports the first differing line with a little context.
func firstDiff(want, got []byte) string {
	w, g := strings.Split(string(want), "\n"), strings.Split(string(got), "\n")
	for i := 0; i < len(w) || i < len(g); i++ {
		var wl, gl string
		if i < len(w) {
			wl = w[i]
		}
		if i < len(g) {
			gl = g[i]
		}
		if wl == gl {
			continue
		}
		lo := i - 3
		if lo < 0 {
			lo = 0
		}
		hi := i + 4
		if hi > len(w) {
			hi = len(w)
		}
		var ctx strings.Builder
		for j := lo; j < hi; j++ {
			ctx.WriteString("  +" + w[j] + "\n")
		}
		hi = i + 4
		if hi > len(g) {
			hi = len(g)
		}
		for j := lo; j < hi; j++ {
			ctx.WriteString("  -" + g[j] + "\n")
		}
		return fmt.Sprintf("line %d\nwant (+)/got (-):\n%s", i+1, ctx.String())
	}
	return ""
}

var (
	reTimestamp = regexp.MustCompile(`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z`)
	reCaptureID = regexp.MustCompile(`C-\d{8}-\d{3}`)
	reWorkID    = regexp.MustCompile(`T-\d{8}-\d{3}`)
	reFocusID   = regexp.MustCompile(`F-\d{8}-\d{3}`)
	reHash      = regexp.MustCompile(`\b[0-9a-f]{64}\b`)
	reWeek      = regexp.MustCompile(`\b\d{4}-W\d{2}\b`)
	reAutoKey   = regexp.MustCompile(`\b[a-z][a-z_-]*-\d{15,}\b`)
	reDate      = regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}\b`)
)

// normalize erases the parts that legitimately differ between two runs: the
// clock, generated IDs, content hashes and temporary paths.
func normalize(s string, paths ...string) string {
	for _, p := range paths {
		if p != "" {
			s = strings.ReplaceAll(s, p, "<tmp>")
		}
	}
	s = strings.ReplaceAll(s, os.TempDir(), "<tmp>")
	s = reTimestamp.ReplaceAllString(s, "<ts>")
	s = reAutoKey.ReplaceAllString(s, "<key>")
	s = reCaptureID.ReplaceAllString(s, "<cid>")
	s = reWorkID.ReplaceAllString(s, "<tid>")
	s = reFocusID.ReplaceAllString(s, "<fid>")
	s = reHash.ReplaceAllString(s, "<hash>")
	s = reWeek.ReplaceAllString(s, "<week>")
	s = reDate.ReplaceAllString(s, "<date>")
	return s
}

// dumpDB reads every user table in rowid order and normalizes each cell. FTS
// shadow tables are an implementation detail of the index, not stored facts.
func dumpDB(t *testing.T, path string) map[string][]map[string]string {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer db.Close()
	names, err := db.Query(`SELECT name FROM sqlite_master WHERE type='table' ORDER BY name`)
	if err != nil {
		t.Fatalf("list tables: %v", err)
	}
	var tables []string
	for names.Next() {
		var n string
		if err := names.Scan(&n); err != nil {
			t.Fatalf("scan table: %v", err)
		}
		// v3 consolidates knowledge_records into documents and adds the links
		// table; both are schema changes, not data drift.
		if strings.HasPrefix(n, "sqlite_") || strings.Contains(n, "_fts") ||
			n == "links" || n == "knowledge_records" {
			continue
		}
		tables = append(tables, n)
	}
	names.Close()
	out := make(map[string][]map[string]string, len(tables))
	for _, table := range tables {
		rows, err := db.Query(`SELECT * FROM "` + table + `" ORDER BY rowid`)
		if err != nil {
			t.Fatalf("select %s: %v", table, err)
		}
		cols, err := rows.Columns()
		if err != nil {
			t.Fatalf("columns %s: %v", table, err)
		}
		var tableRows []map[string]string
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				t.Fatalf("scan %s: %v", table, err)
			}
			row := make(map[string]string, len(cols))
			for i, v := range vals {
				value := normalize(cell(v))
				// The profile timezone is the machine's local zone, so it differs
				// between the recording host and CI; the shape is what matters.
				if cols[i] == "timezone" {
					value = "<tz>"
				}
				row[cols[i]] = value
			}
			tableRows = append(tableRows, row)
		}
		rows.Close()
		out[table] = tableRows
	}
	return out
}

func cell(v any) string {
	switch x := v.(type) {
	case nil:
		return "<null>"
	case []byte:
		return string(x)
	default:
		return fmt.Sprint(x)
	}
}

// TestJourney covers the full operator loop: capture, all five process
// outcomes, planning, focus, review, knowledge and sources.
func TestJourney(t *testing.T) {
	r := newRunner(t)
	r.run("init", "--non-interactive", "--scope", "id=personal,kind=personal")
	r.run("status")

	permit := r.run("capture", "--key", "cap-1", "renew the parking permit").id()
	notes := r.run("capture", "--key", "cap-2", "read the architecture notes").id()
	bank := r.run("capture", "--key", "cap-3", "call the bank").id()
	sail := r.run("capture", "--key", "cap-4", "learn to sail").id()
	invoice := r.run("capture", "--key", "cap-5", "delegate the invoice").id()
	r.run("list", "--list", "inbox")

	item := r.run("process", "--outcome", "work_items", "--title", "Renew permit", "--waiting-on", "DMV", permit).value("data", "work_items", "0", "id")
	r.run("process", "--outcome", "reference", "--reason", "docs/architecture", notes)
	r.run("process", "--outcome", "immediate", "--evidence", "paid online", bank)
	r.run("process", "--outcome", "discard", "--reason", "duplicate", sail)
	r.run("process", "--outcome", "defer", "--review-after", "2026-12-01", invoice)

	r.run("find", "permit")
	r.run("show", item)
	r.run("move", "--field", "energy:low", item, "next")
	r.run("goal", "set", "--statement", "Ship ztd v3")
	r.run("prepare")
	r.run("plan", "commit", "--period", "2026-W48", "--item", item+":mit")
	focus := r.run("focus", "start", item).value("data", "focus", "id")
	r.run("focus", "checkpoint", "--result", "permit renewed", item)
	r.run("focus", "finish", focus)
	r.run("review", "daily", "--period", "2026-W48", "--outcomes", "1 completed", "--coverage", "0.5")

	r.run("doc", "put", "--kind", "knowledge", "--slug", "notes/architecture", "--title", "Architecture", "--body", "One binary over SQLite.")
	r.run("doc", "get", "--kind", "knowledge", "--slug", "notes/architecture")
	r.run("doc", "search", "--query", "SQLite")
	r.run("doc", "related", "--kind", "knowledge", "--slug", "notes/architecture")
	r.run("doc", "list", "--kind", "knowledge")
	r.run("doc", "log")
	r.run("doc", "lint")

	batch := r.write("batch.json", `{
  "batch_id": "b1",
  "idempotency_key": "r1",
  "result_kind": "reported",
  "retrieval": {"window": "2026-11-20", "cursor": "", "requested_limit": 50, "provider_returned_limit": 1, "complete_window": true, "truncated": false, "failures": []},
  "items": [{"external_id": "note-001", "external_revision": "1", "original_text": "renew the parking permit before the trip", "source_uri": "file:///notes/note-001.md"}]
}`)
	r.run("source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal", "--kind", "capture", "--connector", "manual")
	r.run("source", "list", "--all")
	r.run("source", "review", "--source", "feed", "--batch", "b1", "--key", "r1", "--file", batch)
	r.run("source", "list", "feed")
	r.run("routines", "add", "--id", "weekly", "--cadence", "weekly:mon")
	r.run("routines", "due")
	r.run("check")

	r.finish("journey")
}

// TestErrors pins failures, exit codes and idempotent replays.
func TestErrors(t *testing.T) {
	r := newRunner(t)
	r.run("init", "--non-interactive", "--scope", "id=personal,kind=personal")
	first := r.run("capture", "--key", "cap-1", "renew the parking permit").id()
	r.run("capture", "--key", "cap-1", "renew the parking permit")
	r.run("capture", "--key", "cap-1", "something else entirely")
	r.run("capture")
	r.run("show", "T-19990101-999")
	r.run("process", "--outcome", "nonsense", first)
	r.run("process", "--outcome", "work_items", "C-19990101-999")
	r.run("move", "--text", "Renew permit", "--expected", "99", first, "next")
	r.run("doc", "put", "--kind", "nonsense", "--slug", "x")
	r.run("doc", "get", "--kind", "knowledge", "--slug", "missing")
	r.run("source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal", "--kind", "capture", "--connector", "manual")
	r.run("source", "delete", "--id", "feed")
	r.run("nonsense")
	r.finish("errors")
}

// compareSession keeps the behavioural contract strict (steps) while letting
// the v3 schema add trailing columns to existing tables: a dump row matches
// when every column the baseline recorded is identical.
// diffValue compares a golden JSON document against a produced one. Every key,
// array element and scalar in want must be present and equal in got; object
// keys only present in got are ignored so v3 can add fields to v2 responses.
func diffValue(path string, want, got json.RawMessage) string {
	var w, g any
	if err := json.Unmarshal(want, &w); err != nil {
		return path + ": golden is not valid JSON: " + err.Error()
	}
	if err := json.Unmarshal(got, &g); err != nil {
		return path + ": output is not valid JSON: " + err.Error()
	}
	return diffParsed(path, w, g)
}

func diffParsed(path string, want, got any) string {
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return fmt.Sprintf("%s: want object, got %T", path, got)
		}
		for _, k := range sortedKeys(w) {
			gv, ok := g[k]
			if !ok {
				return fmt.Sprintf("%s.%s: missing", path, k)
			}
			if d := diffParsed(path+"."+k, w[k], gv); d != "" {
				return d
			}
		}
		return ""
	case []any:
		g, ok := got.([]any)
		if !ok {
			return fmt.Sprintf("%s: want array, got %T", path, got)
		}
		if len(g) != len(w) {
			return fmt.Sprintf("%s: array has %d elements, want %d", path, len(g), len(w))
		}
		for i := range w {
			if d := diffParsed(fmt.Sprintf("%s[%d]", path, i), w[i], g[i]); d != "" {
				return d
			}
		}
		return ""
	default:
		if !reflect.DeepEqual(want, got) {
			return fmt.Sprintf("%s: got %v, want %v", path, got, want)
		}
		return ""
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func compareSession(want []byte, got session) string {
	type sessionJSON struct {
		Steps []json.RawMessage
		DB    map[string][]map[string]string
	}
	var w sessionJSON
	if err := json.Unmarshal(want, &w); err != nil {
		return fmt.Sprintf("golden is not valid JSON: %v", err)
	}
	if len(got.Steps) != len(w.Steps) {
		return fmt.Sprintf("steps: got %d steps, want %d", len(got.Steps), len(w.Steps))
	}
	for i := range w.Steps {
		// v3 adds keys to existing responses; every key the golden records must
		// still match exactly, and extra keys are tolerated. Harmless drift in
		// the other direction (a missing key) still fails.
		wantStep, _ := json.Marshal(w.Steps[i])
		gotStep, _ := json.Marshal(got.Steps[i])
		if diff := diffValue(fmt.Sprintf("step %d", i), wantStep, gotStep); diff != "" {
			return "steps: " + diff
		}
	}
	for table, wRows := range w.DB {
		gRows, ok := got.DB[table]
		if !ok {
			return fmt.Sprintf("db: table %s is missing", table)
		}
		if len(gRows) != len(wRows) {
			return fmt.Sprintf("db: table %s has %d rows, want %d", table, len(gRows), len(wRows))
		}
		for i := range wRows {
			for col, want := range wRows[i] {
				got, ok := gRows[i][col]
				if !ok {
					return fmt.Sprintf("db: %s row %d has no column %s", table, i, col)
				}
				if got != want {
					return fmt.Sprintf("db: %s row %d column %s is %q, want %q", table, i, col, got, want)
				}
			}
		}
	}
	for table := range got.DB {
		if _, ok := w.DB[table]; !ok {
			return fmt.Sprintf("db: unexpected table %s", table)
		}
	}
	return ""
}
