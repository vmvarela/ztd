// Package legacy reads the format-2 legacy Markdown store and the legacy
// agent export. Parsing is strictly read-only: nothing here creates, modifies
// or deletes a file, a pending legacy journal is refused instead of recovered,
// and problems on individual entities are recorded as issues rather than
// dropped.
package legacy

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"ztd/internal/domain"
)

const (
	maxDocumentFileBytes  = 1 << 20 // 1 MiB per copied document
	maxDocumentTotalBytes = 8 << 20 // 8 MiB for all copied documents
)

// The five task lists in canonical load order.
var listFiles = []struct{ name, rel string }{
	{"inbox", "inbox.md"},
	{"next", "lists/next.md"},
	{"waiting", "lists/waiting.md"},
	{"someday", "lists/someday.md"},
	{"archive", "lists/archive.md"},
}

// Files a readable store must contain. config.json is gated by loadConfig.
var canonicalFiles = []string{
	"contexts.md",
	"inbox.md",
	"lists/next.md",
	"lists/waiting.md",
	"lists/someday.md",
	"lists/archive.md",
	"routines/state.md",
}

// Format-1 reserved task keys; their presence in a format-2 store is a
// quarantine issue, not a refusal (the refusal signal is the `Contexto`
// contexts header).
var legacyFieldKeys = map[string]bool{
	"contexto": true, "cliente": true, "proyecto": true, "capturada": true,
	"cerrada": true, "espera": true, "resolución": true,
}

var (
	planIDPattern        = regexp.MustCompile(`T-\d{8}-\d{3,}`)
	routineIDPattern     = regexp.MustCompile(`^[a-z][A-Za-z0-9_-]*$`)
	weeklyCadencePattern = regexp.MustCompile(`^weekly:(mon|tue|wed|thu|fri|sat|sun)$`)
)

// ParseStore reads a format-2 legacy store at root without writing anything.
// It refuses (domain.UnsupportedFormat) when config.json is missing or does
// not declare format 2, when a canonical file is missing or unreadable, and
// when contexts.md carries the format-1 `Contexto` header. It refuses with
// domain.PendingTransaction when .state/pending.json exists; recovery belongs
// to the legacy tool and is never run here.
func ParseStore(root string) (*Store, error) {
	store := &Store{Root: root, Documents: map[string][]byte{}}

	// A pending journal means the store is mid-transaction; refuse before
	// reading anything else.
	pending := filepath.Join(root, ".state", "pending.json")
	if _, err := os.Lstat(pending); err == nil {
		return nil, domain.NewError(domain.PendingTransaction, "pending transaction: %s", pending)
	} else if !os.IsNotExist(err) {
		return nil, domain.NewError(domain.UnsupportedFormat, "cannot inspect %s: %v", pending, err)
	}

	cfg, err := loadConfig(root)
	if err != nil {
		return nil, err
	}
	store.Config = cfg

	for _, rel := range canonicalFiles {
		path := filepath.Join(root, filepath.FromSlash(rel))
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			return nil, domain.NewError(domain.UnsupportedFormat, "missing canonical file %s", rel)
		}
	}

	contexts, err := parseContexts(root)
	if err != nil {
		return nil, err
	}
	store.Contexts = contexts

	for _, lf := range listFiles {
		if err := parseList(root, lf.name, lf.rel, store); err != nil {
			return nil, err
		}
	}
	validateTasks(store)

	registeredProjects := parseProjects(root, store)
	parsePlans(root, store)
	if err := parseRoutines(root, store); err != nil {
		return nil, err
	}
	copyDocuments(root, store, registeredProjects)
	return store, nil
}

func loadConfig(root string) (Config, error) {
	b, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		return Config{}, domain.NewError(domain.UnsupportedFormat, "config.json: %v", err)
	}
	var raw struct {
		Format *int `json:"format"`
		Policy struct {
			RequireFor []string `json:"requireClientFor"`
			ClientOnly []string `json:"clientOnlyIn"`
		} `json:"policy"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return Config{}, domain.NewError(domain.UnsupportedFormat, "config.json: %v", err)
	}
	if raw.Format == nil {
		return Config{}, domain.NewError(domain.UnsupportedFormat, "config.json: missing format")
	}
	if *raw.Format != 2 {
		return Config{}, domain.NewError(domain.UnsupportedFormat, "config.json: unsupported format %d", *raw.Format)
	}
	return Config{Format: 2, RequireFor: raw.Policy.RequireFor, ClientOnly: raw.Policy.ClientOnly}, nil
}

// parseContexts reads the first cell of every table row in contexts.md. A
// `Contexto` first cell is the format-1 header signal and refuses the store.
func parseContexts(root string) ([]Context, error) {
	b, err := os.ReadFile(filepath.Join(root, "contexts.md"))
	if err != nil {
		return nil, domain.NewError(domain.UnsupportedFormat, "contexts.md: %v", err)
	}
	var out []Context
	for _, raw := range strings.Split(string(b), "\n") {
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, "|") {
			continue
		}
		end := strings.Index(line[1:], "|")
		if end < 0 {
			continue
		}
		cell := strings.TrimSpace(line[1 : 1+end])
		if cell == "Contexto" {
			return nil, domain.NewError(domain.UnsupportedFormat, "format-1 contexts header in contexts.md")
		}
		if cell == "" || cell == "Context" || isAllDash(cell) {
			continue
		}
		out = append(out, Context{Name: cell})
	}
	return out, nil
}

func parseList(root, name, rel string, store *Store) error {
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return domain.NewError(domain.UnsupportedFormat, "cannot read canonical file %s: %v", rel, err)
	}
	for i, raw := range strings.Split(string(b), "\n") {
		line := strings.TrimSuffix(raw, "\r")
		task, malformed := parseTaskLine(line)
		if malformed {
			store.Issues = append(store.Issues, Issue{
				Entity:   "task",
				Detail:   fmt.Sprintf("malformed task line at %s:%d", rel, i+1),
				Original: line,
			})
			continue
		}
		if task == nil {
			continue
		}
		task.List = name
		task.SourcePath = rel
		task.Line = i + 1
		store.Tasks = append(store.Tasks, *task)
	}
	return nil
}

// parseTaskLine returns (nil, false) for a line that is not a task line,
// (nil, true) for a line that starts like a task but breaks the grammar, and a
// populated task otherwise. Segments split only on unescaped " | "; a later
// segment without ": " (or with an empty key) quarantines the task with an
// issue instead of being folded into the title, and a duplicate field key is
// an issue that keeps the first value.
func parseTaskLine(line string) (*Task, bool) {
	if !strings.HasPrefix(line, "- [") {
		return nil, false
	}
	if len(line) < 7 || line[4] != ']' || line[5] != ' ' {
		return nil, true
	}
	switch line[3] {
	case ' ', 'x', 'X':
	default:
		return nil, true
	}
	rest := line[6:]
	var id, body string
	if sep := findSeparator(rest); sep >= 0 {
		id, body = strings.TrimSpace(rest[:sep]), rest[sep+3:]
	} else {
		id = strings.TrimSpace(rest)
	}
	if !domain.ValidTaskID(id) {
		return nil, true
	}
	task := &Task{
		ID:       id,
		Checkbox: string(line[3]),
		Original: line,
	}
	segments := splitSegments(body)
	task.Title = unescapePipe(segments[0])
	seen := map[string]bool{}
	for _, segment := range segments[1:] {
		at := strings.Index(segment, ": ")
		// A segment with no key (": " at the start) is as ambiguous as one
		// without a separator; the legacy parser folded both into the title,
		// which this importer refuses to reproduce.
		if at <= 0 {
			task.Issues = append(task.Issues, "ambiguous segment: "+segment)
			continue
		}
		key := unescapePipe(segment[:at])
		if seen[key] {
			task.Issues = append(task.Issues, "duplicate field "+key)
			continue
		}
		seen[key] = true
		task.Fields = append(task.Fields, Field{Key: key, Value: unescapePipe(segment[at+2:])})
	}
	return task, false
}

// isEscaped reports whether the '|' at index i is escaped by an odd number of
// preceding backslashes, mirroring the Zig parser.
func isEscaped(s string, i int) bool {
	n := 0
	for j := i; j > 0 && s[j-1] == '\\'; j-- {
		n++
	}
	return n%2 == 1
}

func findSeparator(s string) int {
	for i := 0; i+3 <= len(s); i++ {
		if s[i] == ' ' && s[i+1] == '|' && s[i+2] == ' ' && !isEscaped(s, i+1) {
			return i
		}
	}
	return -1
}

func splitSegments(s string) []string {
	var out []string
	for {
		i := findSeparator(s)
		if i < 0 {
			return append(out, s)
		}
		out = append(out, s[:i])
		s = s[i+3:]
	}
}

// unescapePipe turns the only legacy escape, "\|", into a literal '|'.
func unescapePipe(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) && s[i+1] == '|' {
			b.WriteByte('|')
			i++
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// validateTasks records every per-task problem in Task.Issues without ever
// dropping a task. Warnings that do not quarantine go to store.Issues with a
// "warning:" Detail prefix.
func validateTasks(store *Store) {
	registered := make(map[string]bool, len(store.Contexts))
	for _, c := range store.Contexts {
		registered[c.Name] = true
	}
	counts := make(map[string]int, len(store.Tasks))
	for _, t := range store.Tasks {
		counts[t.ID]++
	}

	for i := range store.Tasks {
		t := &store.Tasks[i]
		add := func(msg string) { t.Issues = append(t.Issues, msg) }

		if counts[t.ID] > 1 {
			add("duplicate id " + t.ID)
		}
		for _, f := range t.Fields {
			if legacyFieldKeys[f.Key] {
				add("legacy field " + f.Key)
			}
		}

		ctx := strings.TrimSpace(t.Field("context"))
		client := strings.TrimSpace(t.Field("client"))
		if t.List != "inbox" && ctx == "" {
			add("missing context")
		}
		if ctx != "" {
			if !registered[ctx] {
				add("unknown context " + ctx)
			}
			if client != "" && !contains(store.Config.ClientOnly, ctx) {
				add("client not allowed in context " + ctx)
			}
			if client == "" && contains(store.Config.RequireFor, ctx) {
				add("missing client for context " + ctx)
			}
		}

		if t.List == "waiting" && strings.TrimSpace(t.Field("waiting_on")) == "" {
			add("missing waiting_on")
		}

		if t.List == "archive" {
			if t.Checkbox != "x" && t.Checkbox != "X" {
				add("archive task not checked")
			}
			if strings.TrimSpace(t.Field("resolution")) == "" {
				add("missing resolution")
			}
			if strings.TrimSpace(t.Field("closed_at")) == "" {
				add("missing closed_at")
			}
		} else {
			if t.Checkbox != " " {
				add("checked task outside archive")
			}
			if fieldPresent(t, "resolution") || fieldPresent(t, "closed_at") {
				add("closed fields outside archive")
			}
		}

		if v, ok := lookupField(t, "captured_at"); ok {
			date, parsed := parseDate(v)
			if !parsed {
				add("invalid captured_at: " + v)
			} else if idDate, ok := idDate(t.ID); ok && !date.Equal(idDate) {
				store.Issues = append(store.Issues, Issue{
					Entity:   "task",
					ID:       t.ID,
					Detail:   "warning: captured_at does not match id date",
					Original: t.Original,
				})
			}
		}
		if v, ok := lookupField(t, "closed_at"); ok {
			if _, parsed := parseDate(v); !parsed {
				add("invalid closed_at: " + v)
			}
		}
	}
}

// parseProjects registers every .md file under lists/projects by its relative
// POSIX path without the extension. index.md is not a project document unless
// it is the only project file, in which case its id registers too. The
// returned set holds the registered paths (relative to the store root) so
// copyDocuments can keep the bytes of project documents out of Documents.
func parseProjects(root string, store *Store) map[string]bool {
	registered := map[string]bool{}
	base := filepath.Join(root, "lists", "projects")
	if _, err := os.Stat(base); err != nil {
		return registered
	}
	var docs []string
	err := filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			rel, _ := filepath.Rel(root, path)
			store.Issues = append(store.Issues, Issue{Entity: "project", Detail: "unreadable: " + filepath.ToSlash(rel)})
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(path, ".md") {
			return nil
		}
		rel, err := filepath.Rel(base, path)
		if err != nil {
			return nil
		}
		docs = append(docs, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return registered
	}

	var indexes []string
	var projects []string
	for _, rel := range docs {
		if filepath.Base(rel) == "index.md" {
			indexes = append(indexes, rel)
			continue
		}
		projects = append(projects, rel)
	}
	// index.md registers only when it is the only match.
	if len(projects) == 0 && len(indexes) == 1 {
		projects = indexes
	}
	sort.Strings(projects)

	for _, rel := range projects {
		b, err := os.ReadFile(filepath.Join(base, filepath.FromSlash(rel)))
		if err != nil {
			store.Issues = append(store.Issues, Issue{
				Entity: "project",
				ID:     strings.TrimSuffix(rel, ".md"),
				Detail: "unreadable: " + err.Error(),
			})
			continue
		}
		// The path is the authoritative id; the optional "- ID:" line is
		// recognized but never overrides it.
		p := Project{
			ID:         strings.TrimSuffix(rel, ".md"),
			SourcePath: "lists/projects/" + rel,
			Original:   string(b),
		}
		for _, line := range strings.Split(string(b), "\n") {
			trimmed := strings.TrimSpace(line)
			switch {
			case strings.HasPrefix(trimmed, "- ID:"):
			case strings.HasPrefix(trimmed, "- Context:"):
				p.Context = strings.TrimSpace(strings.TrimPrefix(trimmed, "- Context:"))
			case strings.HasPrefix(trimmed, "- Client:"):
				p.Client = strings.TrimSpace(strings.TrimPrefix(trimmed, "- Client:"))
			case strings.HasPrefix(trimmed, "- Status:"):
				p.Status = strings.TrimSpace(strings.TrimPrefix(trimmed, "- Status:"))
			case strings.HasPrefix(trimmed, "- Desired outcome:"):
				p.DesiredOutcome = strings.TrimSpace(strings.TrimPrefix(trimmed, "- Desired outcome:"))
			}
		}
		key := "lists/projects/" + rel
		registered[key] = true
		store.Projects = append(store.Projects, p)
	}
	return registered
}

// parsePlans reads plans/daily and plans/weekly. Every T- id in a daily plan
// is an MIT. In a weekly plan the ids under a heading containing "Big rock"
// are BigRocks and all other ids are plain ids. The three buckets are a
// partition: each id lands in exactly one, in order of first appearance.
func parsePlans(root string, store *Store) {
	for _, kind := range []string{"daily", "weekly"} {
		dir := filepath.Join(root, "plans", kind)
		if _, err := os.Stat(dir); err != nil {
			continue // plans are optional
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			store.Issues = append(store.Issues, Issue{Entity: "plan", Detail: "unreadable directory plans/" + kind})
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			info, err := e.Info()
			if err != nil || !info.Mode().IsRegular() {
				continue
			}
			rel := "plans/" + kind + "/" + e.Name()
			b, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				store.Issues = append(store.Issues, Issue{Entity: "plan", Detail: "unreadable: " + rel})
				continue
			}
			period := strings.TrimSuffix(e.Name(), ".md")
			store.Plans = append(store.Plans, parsePlan(kind, period, rel, string(b)))
		}
	}
}

func parsePlan(kind, period, rel, content string) Plan {
	plan := Plan{Kind: kind, Period: period, SourcePath: rel}
	seen := map[string]bool{}
	inBigRock := false
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSuffix(raw, "\r")
		trim := strings.TrimSpace(line)
		lower := strings.ToLower(trim)
		// Heading detection: markdown headings ("## Big Rocks") plus bare
		// section labels ("Big rocks:"). Lines carrying a T- id never change
		// the section, so a task whose title mentions big rocks cannot
		// reclassify what follows.
		if strings.HasPrefix(trim, "#") || (strings.HasSuffix(trim, ":") && !strings.Contains(trim, "T-")) {
			inBigRock = strings.Contains(lower, "big rock")
		}
		for _, id := range planIDPattern.FindAllString(line, -1) {
			if seen[id] {
				continue
			}
			seen[id] = true
			switch kind {
			case "daily":
				plan.MITs = append(plan.MITs, id)
			default:
				if inBigRock {
					plan.BigRocks = append(plan.BigRocks, id)
				} else {
					plan.IDs = append(plan.IDs, id)
				}
			}
		}
	}
	return plan
}

// parseRoutines reads routines/state.md exactly: rows need a leading and
// trailing '|', exactly three cells, a lowercase id, a daily or weekly:mon…
// sun cadence and a YYYY-MM-DD date. Every malformed row and an empty table
// are issues; the parse never fails on row content.
func parseRoutines(root string, store *Store) error {
	const rel = "routines/state.md"
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		return domain.NewError(domain.UnsupportedFormat, "cannot read canonical file %s: %v", rel, err)
	}
	seen := map[string]bool{}
	rows := 0
	for _, raw := range strings.Split(string(b), "\n") {
		line := strings.TrimSuffix(raw, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || !strings.HasPrefix(trimmed, "|") {
			continue
		}
		problem := func(detail string) {
			store.Issues = append(store.Issues, Issue{Entity: "routine", Detail: detail, Original: line})
		}
		if !strings.HasSuffix(trimmed, "|") {
			problem("malformed routine row: missing trailing |")
			continue
		}
		cells := strings.Split(strings.TrimSuffix(strings.TrimPrefix(trimmed, "|"), "|"), "|")
		if len(cells) != 3 {
			problem("malformed routine row: expected 3 cells")
			continue
		}
		for i := range cells {
			cells[i] = strings.TrimSpace(cells[i])
		}
		id, cadence, last := cells[0], cells[1], cells[2]
		if id == "routine" || isAllDash(id) {
			continue // header and separator rows
		}
		if !routineIDPattern.MatchString(id) {
			problem("malformed routine row: invalid id " + id)
			continue
		}
		if cadence != "daily" && !weeklyCadencePattern.MatchString(cadence) {
			problem("malformed routine row: invalid cadence " + cadence)
			continue
		}
		date, ok := parseDate(last)
		if !ok {
			problem("malformed routine row: invalid last date " + last)
			continue
		}
		if seen[id] {
			problem("duplicate routine id " + id)
			continue
		}
		seen[id] = true
		rows++
		kind := "daily"
		if strings.HasPrefix(cadence, "weekly:") {
			kind = "weekly"
		}
		store.Routines = append(store.Routines, Routine{
			ID:              id,
			Kind:            kind,
			Cadence:         cadence,
			LastCompletedAt: &date,
			Original:        line,
			SourcePath:      rel,
		})
	}
	if rows == 0 {
		store.Issues = append(store.Issues, Issue{
			Entity: "routine",
			Detail: rel + ": no routine rows",
		})
	}
	return nil
}

// copyDocuments copies every other regular file under the store root into
// Documents as raw bytes: files already parsed into entities, templates/ and
// hidden tooling directories (.state, .git, …) are excluded. Files above 1 MiB
// or beyond the 8 MiB total budget are skipped with an issue and never parsed.
func copyDocuments(root string, store *Store, registeredProjects map[string]bool) {
	var total int64
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			rel, _ := filepath.Rel(root, path)
			store.Issues = append(store.Issues, Issue{Entity: "document", Detail: "unreadable: " + filepath.ToSlash(rel)})
			return nil
		}
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			// Never import tooling state: the top-level templates/ subtree
			// and top-level dot-directories (.state, .git, …). The store root
			// itself is never skipped, even when its basename starts with a
			// dot (e.g. ~/.ztd).
			if rel != "." && !strings.Contains(rel, "/") && (rel == "templates" || strings.HasPrefix(rel, ".")) {
				return fs.SkipDir
			}
			return nil
		}
		info, infoErr := d.Info()
		if infoErr != nil || !info.Mode().IsRegular() {
			return nil
		}
		if documentExcluded(rel, registeredProjects) {
			return nil
		}
		problem := func(detail string) {
			store.Issues = append(store.Issues, Issue{Entity: "document", ID: rel, Detail: detail})
		}
		if info.Size() > maxDocumentFileBytes {
			problem("document exceeds 1 MiB")
			return nil
		}
		if total+info.Size() > maxDocumentTotalBytes {
			problem("document budget of 8 MiB exceeded")
			return nil
		}
		b, readErr := os.ReadFile(path)
		if readErr != nil {
			problem("unreadable: " + readErr.Error())
			return nil
		}
		store.Documents[rel] = b
		total += int64(len(b))
		return nil
	})
}

// documentExcluded reports whether rel already lives in an entity of the
// store. Skipped index.md files produce no entity, so their bytes are kept as
// a document.
func documentExcluded(rel string, registeredProjects map[string]bool) bool {
	switch rel {
	case "config.json", "contexts.md", "inbox.md", "routines/state.md",
		"lists/next.md", "lists/waiting.md", "lists/someday.md", "lists/archive.md":
		return true
	}
	if registeredProjects[rel] {
		return true
	}
	// Only plan files the parser actually reads are excluded; anything in a
	// subdirectory of plans/ was never parsed and must keep its bytes.
	if after, ok := strings.CutPrefix(rel, "plans/daily/"); ok {
		return !strings.Contains(after, "/") && strings.HasSuffix(after, ".md")
	}
	if after, ok := strings.CutPrefix(rel, "plans/weekly/"); ok {
		return !strings.Contains(after, "/") && strings.HasSuffix(after, ".md")
	}
	return false
}

func lookupField(t *Task, key string) (string, bool) {
	for _, f := range t.Fields {
		if f.Key == key {
			return f.Value, true
		}
	}
	return "", false
}

func fieldPresent(t *Task, key string) bool {
	_, ok := lookupField(t, key)
	return ok
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// parseDate accepts exactly YYYY-MM-DD.
func parseDate(s string) (time.Time, bool) {
	t, err := time.Parse("2006-01-02", strings.TrimSpace(s))
	return t, err == nil
}

// idDate extracts T-YYYYMMDD-NNN's date; ok is false when it is not a real
// date, in which case captured_at comparison is skipped.
func idDate(id string) (time.Time, bool) {
	if len(id) < 10 {
		return time.Time{}, false
	}
	return parseDate(id[2:6] + "-" + id[6:8] + "-" + id[8:10])
}

func isAllDash(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] != '-' {
			return false
		}
	}
	return true
}
