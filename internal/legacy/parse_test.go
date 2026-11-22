package legacy

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"ztd/internal/domain"
)

// fixtureRoot is the committed synthetic store the importer must accept.
func fixtureRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..", "test", "fixtures", "legacy")
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("fixture root: %v", err)
	}
	return root
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		t.Fatalf("copy fixture: %v", err)
	}
}

// copyFixture clones the committed fixture into a writable temp dir so each
// subtest can corrupt its own copy.
func copyFixture(t *testing.T) string {
	t.Helper()
	dst := filepath.Join(t.TempDir(), "store")
	copyTree(t, fixtureRoot(t), dst)
	return dst
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustParse(t *testing.T, root string) *Store {
	t.Helper()
	store, err := ParseStore(root)
	if err != nil {
		t.Fatalf("ParseStore(%s): %v", root, err)
	}
	return store
}

func taskByID(t *testing.T, store *Store, id string) *Task {
	t.Helper()
	for i := range store.Tasks {
		if store.Tasks[i].ID == id {
			return &store.Tasks[i]
		}
	}
	t.Fatalf("task %s not found (have %d tasks)", id, len(store.Tasks))
	return nil
}

func hasIssue(t *testing.T, issues []string, sub string) {
	t.Helper()
	for _, s := range issues {
		if strings.Contains(s, sub) {
			return
		}
	}
	t.Fatalf("no issue containing %q in %v", sub, issues)
}

func storeIssue(store *Store, sub string) bool {
	for _, is := range store.Issues {
		if strings.Contains(is.Detail, sub) {
			return true
		}
	}
	return false
}

// snapshotTree records every file and directory (path → size/mtime/sha256) so
// a parse can be proven not to touch the source tree.
func snapshotTree(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		key := filepath.ToSlash(rel)
		if d.IsDir() {
			key += "/"
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			out[key] = fmt.Sprintf("dir:%d", info.ModTime().UnixNano())
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(b)
		out[key] = fmt.Sprintf("%d:%d:%x", info.Size(), info.ModTime().UnixNano(), sum)
		return nil
	})
	if err != nil {
		t.Fatalf("snapshot %s: %v", root, err)
	}
	return out
}

func TestParseStoreFixture(t *testing.T) {
	root := fixtureRoot(t)
	store := mustParse(t, root)

	if store.Root != root {
		t.Errorf("Root = %q, want %q", store.Root, root)
	}

	// Config
	if store.Config.Format != 2 {
		t.Errorf("Format = %d, want 2", store.Config.Format)
	}
	if !reflect.DeepEqual(store.Config.RequireFor, []string{"work"}) {
		t.Errorf("RequireFor = %v", store.Config.RequireFor)
	}
	if !reflect.DeepEqual(store.Config.ClientOnly, []string{"work"}) {
		t.Errorf("ClientOnly = %v", store.Config.ClientOnly)
	}

	// Contexts: header and separator skipped, generic column layout.
	if len(store.Contexts) != 2 || store.Contexts[0].Name != "familia" || store.Contexts[1].Name != "work" {
		t.Errorf("Contexts = %+v, want [familia work]", store.Contexts)
	}

	// Exact task counts per list.
	counts := map[string]int{}
	for _, task := range store.Tasks {
		counts[task.List]++
	}
	wantCounts := map[string]int{"inbox": 2, "next": 1, "waiting": 1, "someday": 1, "archive": 1}
	if !reflect.DeepEqual(counts, wantCounts) {
		t.Errorf("task counts = %v, want %v", counts, wantCounts)
	}
	if len(store.Tasks) != 6 {
		t.Errorf("len(Tasks) = %d, want 6", len(store.Tasks))
	}

	// A clean fixture parses with zero issues anywhere.
	if len(store.Issues) != 0 {
		t.Errorf("store issues = %+v, want none", store.Issues)
	}
	for _, task := range store.Tasks {
		if len(task.Issues) != 0 {
			t.Errorf("task %s issues = %v, want none", task.ID, task.Issues)
		}
	}

	// Inbox: fields, original text, provenance.
	one := taskByID(t, store, "T-20261119-001")
	if one.Title != "call plumber" || one.Checkbox != " " || one.List != "inbox" {
		t.Errorf("task 001 = %+v", one)
	}
	if one.SourcePath != "inbox.md" || one.Line != 3 {
		t.Errorf("task 001 provenance = %s:%d", one.SourcePath, one.Line)
	}
	if want := "- [ ] T-20261119-001 | call plumber"; one.Original != want {
		t.Errorf("task 001 Original = %q, want %q", one.Original, want)
	}
	two := taskByID(t, store, "T-20261119-002")
	if two.Line != 4 || two.Field("captured_at") != "2026-11-19" {
		t.Errorf("task 002 = line %d, captured_at %q", two.Line, two.Field("captured_at"))
	}

	// Next: field order, custom field, original text.
	next := taskByID(t, store, "T-20261118-003")
	if next.Title != "write spec" || next.List != "next" || next.Checkbox != " " {
		t.Errorf("next task = %+v", next)
	}
	if next.SourcePath != "lists/next.md" || next.Line != 3 {
		t.Errorf("next provenance = %s:%d", next.SourcePath, next.Line)
	}
	wantNext := `- [ ] T-20261118-003 | write spec | context: work | client: acme | project: work/acme/demo | captured_at: 2026-11-18 | siguiente: draft section 2`
	if next.Original != wantNext {
		t.Errorf("next Original = %q", next.Original)
	}
	wantKeys := []string{"context", "client", "project", "captured_at", "siguiente"}
	gotKeys := make([]string, len(next.Fields))
	for i, f := range next.Fields {
		gotKeys[i] = f.Key
	}
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Errorf("next field order = %v, want %v", gotKeys, wantKeys)
	}
	if next.Field("project") != "work/acme/demo" || next.Field("siguiente") != "draft section 2" {
		t.Errorf("next fields = %+v", next.Fields)
	}

	waiting := taskByID(t, store, "T-20261118-004")
	if waiting.Field("waiting_on") != "builder @2026-11-25" || waiting.List != "waiting" {
		t.Errorf("waiting task = %+v", waiting)
	}
	someday := taskByID(t, store, "T-20261118-005")
	if someday.Title != "learn Go generics" || someday.Field("context") != "familia" {
		t.Errorf("someday task = %+v", someday)
	}

	// Archive: checkbox, closure fields, custom field, original text.
	arch := taskByID(t, store, "T-20261026-006")
	if arch.Checkbox != "x" || arch.List != "archive" {
		t.Errorf("archive task = %+v", arch)
	}
	wantArch := `- [x] T-20261026-006 | renew permit | context: familia | captured_at: 2026-10-26 | closed_at: 2026-11-02 | resolution: done at counter | resultado: renewed`
	if arch.Original != wantArch {
		t.Errorf("archive Original = %q", arch.Original)
	}
	if arch.Field("resolution") != "done at counter" || arch.Field("closed_at") != "2026-11-02" || arch.Field("resultado") != "renewed" {
		t.Errorf("archive fields = %+v", arch.Fields)
	}

	// Projects: index.md skipped as a document, the two real projects parsed.
	if len(store.Projects) != 2 {
		t.Fatalf("len(Projects) = %d, want 2", len(store.Projects))
	}
	byID := map[string]Project{}
	for _, p := range store.Projects {
		byID[p.ID] = p
	}
	casa, ok := byID["familia/casa"]
	if !ok {
		t.Fatalf("project familia/casa missing: %+v", store.Projects)
	}
	if casa.Context != "familia" || casa.Client != "" || casa.Status != "active" || casa.DesiredOutcome != "maintenance plan" {
		t.Errorf("casa = %+v", casa)
	}
	if casa.SourcePath != "lists/projects/familia/casa.md" || !strings.Contains(casa.Original, "- ID: familia/casa") {
		t.Errorf("casa provenance = %s original %q", casa.SourcePath, casa.Original)
	}
	demo, ok := byID["work/acme/demo"]
	if !ok {
		t.Fatalf("project work/acme/demo missing")
	}
	if demo.Context != "work" || demo.Client != "acme" || demo.Status != "active" || demo.DesiredOutcome != "shipped specification" {
		t.Errorf("demo = %+v", demo)
	}
	if !strings.Contains(demo.Original, "- Completion criteria: review passed") {
		t.Errorf("demo Original lost unread lines: %q", demo.Original)
	}

	// Routines.
	if len(store.Routines) != 2 {
		t.Fatalf("len(Routines) = %d, want 2", len(store.Routines))
	}
	r0, r1 := store.Routines[0], store.Routines[1]
	if r0.ID != "inbox" || r0.Kind != "daily" || r0.Cadence != "daily" || r0.LastCompletedAt == nil || r0.LastCompletedAt.Format("2006-01-02") != "2026-11-19" {
		t.Errorf("routine 0 = %+v", r0)
	}
	if r0.Original != "| inbox | daily | 2026-11-19 |" || r0.SourcePath != "routines/state.md" {
		t.Errorf("routine 0 provenance = %q %q", r0.Original, r0.SourcePath)
	}
	if r1.ID != "review" || r1.Kind != "weekly" || r1.Cadence != "weekly:sat" || r1.LastCompletedAt == nil || r1.LastCompletedAt.Format("2006-01-02") != "2026-11-14" {
		t.Errorf("routine 1 = %+v", r1)
	}

	// Plans: daily → all MITs; weekly "Big rocks" section → BigRocks.
	if len(store.Plans) != 2 {
		t.Fatalf("len(Plans) = %d, want 2", len(store.Plans))
	}
	var daily, weekly *Plan
	for i := range store.Plans {
		switch store.Plans[i].Kind {
		case "daily":
			daily = &store.Plans[i]
		case "weekly":
			weekly = &store.Plans[i]
		}
	}
	if daily == nil || weekly == nil {
		t.Fatalf("missing plan kind: %+v", store.Plans)
	}
	if daily.Period != "2026-11-19" || daily.SourcePath != "plans/daily/2026-11-19.md" {
		t.Errorf("daily plan = %+v", daily)
	}
	if !reflect.DeepEqual(daily.MITs, []string{"T-20261118-003", "T-20261118-004"}) {
		t.Errorf("daily.MITs = %v", daily.MITs)
	}
	if len(daily.IDs) != 0 || len(daily.BigRocks) != 0 {
		t.Errorf("daily buckets = IDs %v BigRocks %v, want empty", daily.IDs, daily.BigRocks)
	}
	if weekly.Period != "2026-W47" || weekly.SourcePath != "plans/weekly/2026-W47.md" {
		t.Errorf("weekly plan = %+v", weekly)
	}
	if !reflect.DeepEqual(weekly.BigRocks, []string{"T-20261118-003"}) {
		t.Errorf("weekly.BigRocks = %v", weekly.BigRocks)
	}
	if len(weekly.IDs) != 0 || len(weekly.MITs) != 0 {
		t.Errorf("weekly buckets = IDs %v MITs %v, want empty", weekly.IDs, weekly.MITs)
	}

	// Documents: every non-parsed regular file, raw bytes, keyed by POSIX path.
	wantDocs := map[string]bool{
		"agent-export.json":            true,
		"lists/projects/index.md":      true,
		"reviews/2026-11-14-weekly.md": true,
	}
	gotDocs := map[string]bool{}
	for k := range store.Documents {
		gotDocs[k] = true
	}
	if !reflect.DeepEqual(gotDocs, wantDocs) {
		t.Errorf("Documents = %v, want %v", gotDocs, wantDocs)
	}
	review := readFile(t, filepath.Join(root, "reviews", "2026-11-14-weekly.md"))
	if string(store.Documents["reviews/2026-11-14-weekly.md"]) != review {
		t.Errorf("review document bytes differ from source")
	}
	reviewDocs := 0
	for k := range store.Documents {
		if strings.HasPrefix(k, "reviews/") {
			reviewDocs++
		}
	}
	if reviewDocs != 1 {
		t.Errorf("review documents = %d, want 1", reviewDocs)
	}
	// Parsed entities never leak into Documents.
	for _, parsed := range []string{"config.json", "contexts.md", "inbox.md", "lists/next.md", "routines/state.md", "plans/daily/2026-11-19.md", "lists/projects/familia/casa.md"} {
		if _, ok := store.Documents[parsed]; ok {
			t.Errorf("parsed file %s unexpectedly in Documents", parsed)
		}
	}
}

func TestParseStoreDoesNotModifySourceTree(t *testing.T) {
	root := fixtureRoot(t)
	before := snapshotTree(t, root)
	if _, err := ParseStore(root); err != nil {
		t.Fatalf("ParseStore: %v", err)
	}
	after := snapshotTree(t, root)
	if !reflect.DeepEqual(before, after) {
		for k, v := range before {
			if after[k] != v {
				t.Errorf("changed %s: before %q after %q", k, v, after[k])
			}
		}
		for k := range after {
			if _, ok := before[k]; !ok {
				t.Errorf("new entry %s", k)
			}
		}
		t.Fatal("ParseStore modified the source tree")
	}
}

func TestParseStoreRefusals(t *testing.T) {
	cases := []struct {
		name   string
		family domain.Family
		mutate func(t *testing.T, dir string)
	}{
		{"pending journal", domain.PendingTransaction, func(t *testing.T, dir string) {
			writeFile(t, filepath.Join(dir, ".state", "pending.json"), "{}\n")
		}},
		{"format 1", domain.UnsupportedFormat, func(t *testing.T, dir string) {
			writeFile(t, filepath.Join(dir, "config.json"), `{"format":1}`)
		}},
		{"missing config", domain.UnsupportedFormat, func(t *testing.T, dir string) {
			if err := os.Remove(filepath.Join(dir, "config.json")); err != nil {
				t.Fatal(err)
			}
		}},
		{"missing canonical list", domain.UnsupportedFormat, func(t *testing.T, dir string) {
			if err := os.Remove(filepath.Join(dir, "lists", "next.md")); err != nil {
				t.Fatal(err)
			}
		}},
		{"missing routines state", domain.UnsupportedFormat, func(t *testing.T, dir string) {
			if err := os.Remove(filepath.Join(dir, "routines", "state.md")); err != nil {
				t.Fatal(err)
			}
		}},
		{"format-1 contexts header", domain.UnsupportedFormat, func(t *testing.T, dir string) {
			path := filepath.Join(dir, "contexts.md")
			content := strings.Replace(readFile(t, path), "| Context |", "| Contexto |", 1)
			writeFile(t, path, content)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := copyFixture(t)
			tc.mutate(t, dir)
			_, err := ParseStore(dir)
			if !domain.Of(err, tc.family) {
				t.Fatalf("error = %v, want family %s", err, tc.family)
			}
		})
	}

	t.Run("nonexistent root", func(t *testing.T) {
		_, err := ParseStore(filepath.Join(t.TempDir(), "nope"))
		if !domain.Of(err, domain.UnsupportedFormat) {
			t.Fatalf("error = %v, want UnsupportedFormat", err)
		}
	})
}

func TestParseStoreTaskIssues(t *testing.T) {
	t.Run("duplicate field key", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "next.md")
		content := strings.Replace(readFile(t, path),
			"siguiente: draft section 2",
			"siguiente: draft section 2 | context: personal", 1)
		writeFile(t, path, content)
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-003")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "duplicate field context")
		// First value wins; the original line retains everything.
		if task.Field("context") != "work" {
			t.Errorf("context = %q, want first value work", task.Field("context"))
		}
		if !strings.Contains(task.Original, "context: personal") {
			t.Errorf("Original lost duplicate segment: %q", task.Original)
		}
	})

	t.Run("ambiguous segment quarantines but keeps task", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "next.md")
		content := strings.Replace(readFile(t, path),
			"siguiente: draft section 2",
			"siguiente: draft section 2 | plain segment", 1)
		writeFile(t, path, content)
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-003")
		hasIssue(t, task.Issues, "ambiguous segment: plain segment")
		if !strings.Contains(task.Original, "plain segment") {
			t.Errorf("Original lost ambiguous segment: %q", task.Original)
		}
		// Not folded into the title.
		if task.Title != "write spec" {
			t.Errorf("title = %q, want write spec", task.Title)
		}
	})

	t.Run("archive unchecked", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "archive.md")
		writeFile(t, path, strings.Replace(readFile(t, path), "- [x]", "- [ ]", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261026-006")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "archive task not checked")
	})

	t.Run("checked task outside archive", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "next.md")
		writeFile(t, path, strings.Replace(readFile(t, path), "- [ ]", "- [x]", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-003")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "checked task outside archive")
	})

	t.Run("waiting without waiting_on", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "waiting.md")
		writeFile(t, path, strings.Replace(readFile(t, path), " | waiting_on: builder @2026-11-25", "", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-004")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "missing waiting_on")
	})

	t.Run("duplicate id across lists", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		line := `- [ ] T-20261118-003 | copy of next | context: work | client: acme`
		writeFile(t, path, readFile(t, path)+line+"\n")
		store := mustParse(t, dir)
		dupes := 0
		for _, task := range store.Tasks {
			if task.ID == "T-20261118-003" {
				dupes++
				hasIssue(t, task.Issues, "duplicate id T-20261118-003")
			}
		}
		if dupes != 2 {
			t.Errorf("tasks with duplicated id = %d, want 2", dupes)
		}
	})

	t.Run("missing context outside inbox", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "next.md")
		writeFile(t, path, readFile(t, path)+"- [ ] T-20261118-077 | no context yet | captured_at: 2026-11-18\n")
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-077")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "missing context")
	})

	t.Run("unknown context", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		writeFile(t, path, readFile(t, path)+"- [ ] T-20261118-078 | mars task | context: mars\n")
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-078")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "unknown context mars")
	})

	t.Run("missing client for work", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "next.md")
		writeFile(t, path, strings.Replace(readFile(t, path), " | client: acme", "", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-003")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "missing client for context work")
	})

	t.Run("client not allowed in context", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		writeFile(t, path, strings.Replace(readFile(t, path),
			"| context: familia", "| context: familia | client: acme", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-005")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "client not allowed in context familia")
	})

	t.Run("archive missing resolution", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "archive.md")
		writeFile(t, path, strings.Replace(readFile(t, path), " | resolution: done at counter", "", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261026-006")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "missing resolution")
	})

	t.Run("invalid captured_at", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		writeFile(t, path, readFile(t, path)+"- [ ] T-20261118-079 | bad date | context: familia | captured_at: not-a-date\n")
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-079")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "invalid captured_at: not-a-date")
	})

	t.Run("invalid closed_at", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "archive.md")
		writeFile(t, path, strings.Replace(readFile(t, path), "closed_at: 2026-11-02", "closed_at: 42", 1))
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261026-006")
		if len(task.Issues) != 1 {
			t.Fatalf("issues = %v, want exactly one", task.Issues)
		}
		hasIssue(t, task.Issues, "invalid closed_at: 42")
	})

	t.Run("captured_at mismatch is only a warning", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		writeFile(t, path, readFile(t, path)+"- [ ] T-20261118-080 | drifted | context: familia | captured_at: 2026-11-01\n")
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-080")
		if len(task.Issues) != 0 {
			t.Errorf("task issues = %v, want none (warning must not quarantine)", task.Issues)
		}
		found := false
		for _, is := range store.Issues {
			if is.ID == "T-20261118-080" && strings.HasPrefix(is.Detail, "warning:") {
				found = true
			}
		}
		if !found {
			t.Errorf("no warning issue for T-20261118-080: %+v", store.Issues)
		}
	})

	t.Run("legacy format-1 field key", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "lists", "someday.md")
		writeFile(t, path, readFile(t, path)+"- [ ] T-20261118-081 | spanish key | context: familia | contexto: personal\n")
		store := mustParse(t, dir)
		task := taskByID(t, store, "T-20261118-081")
		hasIssue(t, task.Issues, "legacy field contexto")
	})

	t.Run("malformed task line is quarantined as store issue", func(t *testing.T) {
		dir := copyFixture(t)
		path := filepath.Join(dir, "inbox.md")
		line := `- [q] T-20261119-099 | bad checkbox char`
		writeFile(t, path, readFile(t, path)+line+"\n")
		store := mustParse(t, dir)
		if len(store.Tasks) != 6 {
			t.Errorf("tasks = %d, want 6 (bad line adds no task)", len(store.Tasks))
		}
		found := false
		for _, is := range store.Issues {
			if is.Entity == "task" && strings.Contains(is.Detail, "malformed task line at inbox.md:") && is.Original == line {
				found = true
			}
		}
		if !found {
			t.Errorf("no malformed-line issue with original: %+v", store.Issues)
		}
	})
}

func TestParseTaskLine(t *testing.T) {
	t.Run("not a task line", func(t *testing.T) {
		task, malformed := parseTaskLine("# Inbox")
		if task != nil || malformed {
			t.Errorf("got (%v, %v), want (nil, false)", task, malformed)
		}
	})

	t.Run("segments optional", func(t *testing.T) {
		task, malformed := parseTaskLine("- [ ] T-20261111-001")
		if malformed || task == nil {
			t.Fatalf("got (%v, %v)", task, malformed)
		}
		if task.ID != "T-20261111-001" || task.Title != "" || len(task.Fields) != 0 || task.Checkbox != " " {
			t.Errorf("task = %+v", task)
		}
	})

	t.Run("escaped pipe stays in title", func(t *testing.T) {
		task, malformed := parseTaskLine(`- [ ] T-20261111-001 | Title with \| pipe | context: work`)
		if malformed || task == nil {
			t.Fatalf("got (%v, %v)", task, malformed)
		}
		if task.Title != "Title with | pipe" {
			t.Errorf("title = %q", task.Title)
		}
		if task.Field("context") != "work" {
			t.Errorf("fields = %+v", task.Fields)
		}
		if len(task.Issues) != 0 {
			t.Errorf("issues = %v", task.Issues)
		}
	})

	t.Run("escaped pipe in field value", func(t *testing.T) {
		task, malformed := parseTaskLine(`- [x] T-20261111-001 | T | waiting_on: a \| b`)
		if malformed || task == nil {
			t.Fatalf("got (%v, %v)", task, malformed)
		}
		if task.Field("waiting_on") != "a | b" {
			t.Errorf("waiting_on = %q", task.Field("waiting_on"))
		}
	})

	t.Run("duplicate field keeps first", func(t *testing.T) {
		task, malformed := parseTaskLine(`- [ ] T-20261111-001 | T | context: work | context: home`)
		if malformed || task == nil {
			t.Fatalf("got (%v, %v)", task, malformed)
		}
		if len(task.Fields) != 1 || task.Field("context") != "work" {
			t.Errorf("fields = %+v", task.Fields)
		}
		hasIssue(t, task.Issues, "duplicate field context")
	})

	t.Run("invalid status char is malformed", func(t *testing.T) {
		if task, malformed := parseTaskLine("- [q] T-20261111-001 | T"); task != nil || !malformed {
			t.Errorf("got (%v, %v), want (nil, true)", task, malformed)
		}
	})

	t.Run("invalid id is malformed", func(t *testing.T) {
		if task, malformed := parseTaskLine("- [ ] not-an-id | T"); task != nil || !malformed {
			t.Errorf("got (%v, %v), want (nil, true)", task, malformed)
		}
	})

	t.Run("missing bracket is malformed", func(t *testing.T) {
		if task, malformed := parseTaskLine("- [ ]T-20261111-001 | T"); task != nil || !malformed {
			t.Errorf("got (%v, %v), want (nil, true)", task, malformed)
		}
	})
}

func TestParseStorePlans(t *testing.T) {
	t.Run("weekly partition and dedup", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "plans", "weekly", "2026-W47.md"), `# Week 2026-W47

Big rocks:

- T-20261118-003

Other stuff:

- T-20261118-005
- T-20261118-005
`)
		store := mustParse(t, dir)
		if len(store.Plans) != 2 {
			t.Fatalf("plans = %d, want 2", len(store.Plans))
		}
		weekly := store.Plans[1]
		if weekly.Kind != "weekly" {
			t.Fatalf("plan kind = %s", weekly.Kind)
		}
		if !reflect.DeepEqual(weekly.BigRocks, []string{"T-20261118-003"}) {
			t.Errorf("BigRocks = %v", weekly.BigRocks)
		}
		if !reflect.DeepEqual(weekly.IDs, []string{"T-20261118-005"}) {
			t.Errorf("IDs = %v, want deduped [T-20261118-005]", weekly.IDs)
		}
	})

	t.Run("weekly markdown heading and bullet label both classify", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "plans", "weekly", "2026-W47.md"), `# Week 2026-W47

## Big Rocks

- T-20261118-003

## Other

- T-20261118-004
`)
		store := mustParse(t, dir)
		weekly := store.Plans[1]
		if !reflect.DeepEqual(weekly.BigRocks, []string{"T-20261118-003"}) {
			t.Errorf("BigRocks = %v", weekly.BigRocks)
		}
		if !reflect.DeepEqual(weekly.IDs, []string{"T-20261118-004"}) {
			t.Errorf("IDs = %v", weekly.IDs)
		}
	})

	t.Run("daily all MITs, unknown ids tolerated", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "plans", "daily", "2026-11-19.md"), `# Day 2026-11-19

- T-20261118-003
- T-20261118-003
- T-99999999-999
`)
		store := mustParse(t, dir)
		daily := store.Plans[0]
		if daily.Kind != "daily" {
			t.Fatalf("plan kind = %s", daily.Kind)
		}
		if !reflect.DeepEqual(daily.MITs, []string{"T-20261118-003", "T-99999999-999"}) {
			t.Errorf("MITs = %v", daily.MITs)
		}
		if len(daily.IDs) != 0 || len(daily.BigRocks) != 0 {
			t.Errorf("buckets = %v %v", daily.IDs, daily.BigRocks)
		}
		// Unknown plan ids are a comparison concern, never a parse failure.
		if len(store.Issues) != 0 {
			t.Errorf("issues = %+v, want none", store.Issues)
		}
	})
}

func TestParseStoreRoutines(t *testing.T) {
	t.Run("zero data rows is an issue", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "routines", "state.md"),
			"| routine | cadence | last |\n| --- | --- | --- |\n")
		store := mustParse(t, dir)
		if len(store.Routines) != 0 {
			t.Errorf("routines = %d, want 0", len(store.Routines))
		}
		if !storeIssue(store, "no routine rows") {
			t.Errorf("missing zero-rows issue: %+v", store.Issues)
		}
	})

	t.Run("malformed rows are issues, valid rows still parse", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "routines", "state.md"), `| routine | cadence | last |
| --- | --- | --- |
| inbox | daily | 2026-11-19 |
| bad id | daily | 2026-11-19 |
| review | hourly | 2026-11-14 |
| other | daily | not-a-date |
| dup | daily | 2026-01-01 |
| dup | daily | 2026-01-02 |
| notclosed | daily | 2026-01-03
`)
		store := mustParse(t, dir)
		if len(store.Routines) != 2 {
			t.Fatalf("routines = %d, want 2 (inbox, dup)", len(store.Routines))
		}
		for _, sub := range []string{
			"invalid id bad id",
			"invalid cadence hourly",
			"invalid last date not-a-date",
			"duplicate routine id dup",
			"missing trailing |",
		} {
			if !storeIssue(store, sub) {
				t.Errorf("missing issue %q: %+v", sub, store.Issues)
			}
		}
	})
}

func TestParseStoreProjects(t *testing.T) {
	t.Run("only index.md registers as project", func(t *testing.T) {
		dir := copyFixture(t)
		if err := os.Remove(filepath.Join(dir, "lists", "projects", "familia", "casa.md")); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(dir, "lists", "projects", "work", "acme", "demo.md")); err != nil {
			t.Fatal(err)
		}
		store := mustParse(t, dir)
		if len(store.Projects) != 1 || store.Projects[0].ID != "index" {
			t.Fatalf("projects = %+v, want only index", store.Projects)
		}
		if !strings.Contains(store.Projects[0].Original, "- work/acme/demo") {
			t.Errorf("index Original = %q", store.Projects[0].Original)
		}
	})

	t.Run("index skipped when other projects exist", func(t *testing.T) {
		dir := copyFixture(t)
		if err := os.Remove(filepath.Join(dir, "lists", "projects", "work", "acme", "demo.md")); err != nil {
			t.Fatal(err)
		}
		store := mustParse(t, dir)
		if len(store.Projects) != 1 || store.Projects[0].ID != "familia/casa" {
			t.Fatalf("projects = %+v, want only familia/casa", store.Projects)
		}
		// Skipped index keeps its bytes as a document instead.
		if _, ok := store.Documents["lists/projects/index.md"]; !ok {
			t.Errorf("index.md not preserved in Documents")
		}
	})
}

func TestParseStoreDocuments(t *testing.T) {
	t.Run("templates and .state never imported", func(t *testing.T) {
		dir := copyFixture(t)
		writeFile(t, filepath.Join(dir, "templates", "task.md"), "template\n")
		// A non-pending file under .state must be skipped, not parsed.
		writeFile(t, filepath.Join(dir, ".state", "other.txt"), "state\n")
		store := mustParse(t, dir)
		for _, key := range []string{"templates/task.md", ".state/other.txt"} {
			if _, ok := store.Documents[key]; ok {
				t.Errorf("%s unexpectedly imported", key)
			}
		}
	})

	t.Run("file above 1 MiB is skipped with an issue", func(t *testing.T) {
		dir := copyFixture(t)
		huge := strings.Repeat("a", 1<<20+1)
		writeFile(t, filepath.Join(dir, "huge.bin"), huge)
		store := mustParse(t, dir)
		if _, ok := store.Documents["huge.bin"]; ok {
			t.Errorf("huge.bin imported")
		}
		if !storeIssue(store, "exceeds 1 MiB") {
			t.Errorf("missing size issue: %+v", store.Issues)
		}
		// Other documents still land.
		if _, ok := store.Documents["reviews/2026-11-14-weekly.md"]; !ok {
			t.Errorf("review document lost after size skip")
		}
	})

	t.Run("8 MiB total budget", func(t *testing.T) {
		dir := copyFixture(t)
		chunk := strings.Repeat("b", 1<<20)
		for i := 1; i <= 9; i++ {
			writeFile(t, filepath.Join(dir, fmt.Sprintf("big%d.bin", i)), chunk)
		}
		store := mustParse(t, dir)
		total := 0
		for _, b := range store.Documents {
			total += len(b)
		}
		if total > 8<<20 {
			t.Errorf("Documents total = %d, over 8 MiB", total)
		}
		if !storeIssue(store, "budget of 8 MiB exceeded") {
			t.Errorf("missing budget issue: %+v", store.Issues)
		}
		if _, ok := store.Documents["big1.bin"]; !ok {
			t.Errorf("big1.bin should fit in the budget")
		}
	})
}
