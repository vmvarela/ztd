// v3_test.go pins the acceptance surface of the Zig-only v3 features:
// provenance, decision packets, measurement, overrides, calendar assertions,
// decisions, learnings, output caps, the directory connector and export v2.
// None of them exists in the Go v2 binary, so every test skips unless ZTD_BIN
// points at the Zig build. Assertions read parsed JSON only: ids, timestamps,
// counts, key sets, error families, exit codes and byte caps.
package corpus

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var v3ID = regexp.MustCompile(`^[A-Z]+-\d{8}-\d{3}$`)

// TestV3 runs one subtest per feature group; each group owns a throwaway DB.
func TestV3(t *testing.T) {
	if os.Getenv("ZTD_BIN") == "" {
		t.Skip("v3 features do not exist in the Go v2 binary; set ZTD_BIN to the Zig build")
	}
	t.Run("provenance", v3Provenance)
	t.Run("prepare_packet", v3PreparePacket)
	t.Run("measurement", v3Measurement)
	t.Run("overrides", v3Overrides)
	t.Run("calendar_assertion", v3CalendarAssertion)
	t.Run("decisions", v3Decisions)
	t.Run("learn", v3Learn)
	t.Run("token_caps", v3TokenCaps)
	t.Run("directory_connector", v3DirectoryConnector)
	t.Run("export_v2", v3ExportV2)
}

// ----------------------------------------------------------------- envelope

type v3Error struct {
	Family string `json:"family"`
	Detail string `json:"detail"`
}

type v3Envelope struct {
	OK      bool            `json:"ok"`
	Command string          `json:"command"`
	Data    json.RawMessage `json:"data"`
	Error   *v3Error        `json:"error"`
}

// v3Env decodes the unnormalized envelope (observation.value would see the
// same bytes, but data is not a string field).
func v3Env(t *testing.T, o observation) v3Envelope {
	t.Helper()
	if o.raw == nil {
		t.Fatalf("no JSON envelope on stdout (exit %d, stderr %q)", o.Exit, o.Stderr)
	}
	var e v3Envelope
	if err := json.Unmarshal(o.raw, &e); err != nil {
		t.Fatalf("envelope is not valid JSON: %v\n%s", err, o.raw)
	}
	return e
}

// v3OK asserts the success envelope: exit 0, ok:true, command and data.
func v3OK(t *testing.T, o observation) v3Envelope {
	t.Helper()
	e := v3Env(t, o)
	if o.Exit != 0 || !e.OK {
		t.Fatalf("want success, got exit %d: %s", o.Exit, o.raw)
	}
	if e.Command == "" || len(e.Data) == 0 {
		t.Fatalf("success envelope lacks command or data: %s", o.raw)
	}
	return e
}

// v3Fail asserts the failure envelope: exit 1, ok:false and the error family.
func v3Fail(t *testing.T, o observation, family string) v3Envelope {
	t.Helper()
	e := v3Env(t, o)
	if o.Exit != 1 || e.OK {
		t.Fatalf("want failure exit 1 with family %q, got exit %d: %s", family, o.Exit, o.raw)
	}
	if e.Error == nil || e.Error.Family != family {
		got := "no error object"
		if e.Error != nil {
			got = e.Error.Family + ": " + e.Error.Detail
		}
		t.Fatalf("want error family %q, got %s", family, got)
	}
	return e
}

// v3Data decodes a data object.
func v3Data(t *testing.T, e v3Envelope) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(e.Data, &m); err != nil {
		t.Fatalf("data is not an object: %v\n%s", err, e.Data)
	}
	return m
}

// v3DataArr decodes a data array (doc search, for instance).
func v3DataArr(t *testing.T, e v3Envelope) []any {
	t.Helper()
	var a []any
	if err := json.Unmarshal(e.Data, &a); err != nil {
		t.Fatalf("data is not an array: %v\n%s", err, e.Data)
	}
	return a
}

func v3Str(t *testing.T, m map[string]any, key string) string {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("missing field %q in %v", key, m)
	}
	s, ok := v.(string)
	if !ok {
		t.Fatalf("field %q is %T (%v), want string", key, v, v)
	}
	return s
}

func v3Num(t *testing.T, m map[string]any, key string) float64 {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("missing field %q in %v", key, m)
	}
	n, ok := v.(float64)
	if !ok {
		t.Fatalf("field %q is %T (%v), want number", key, v, v)
	}
	return n
}

func v3Obj(t *testing.T, m map[string]any, key string) map[string]any {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("missing field %q in %v", key, m)
	}
	o, ok := v.(map[string]any)
	if !ok {
		t.Fatalf("field %q is %T, want object", key, v)
	}
	return o
}

func v3Arr(t *testing.T, m map[string]any, key string) []any {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("missing field %q in %v", key, m)
	}
	a, ok := v.([]any)
	if !ok {
		t.Fatalf("field %q is %T, want array", key, v)
	}
	return a
}

// v3Keys asserts the exact key set of an object.
func v3Keys(t *testing.T, m map[string]any, want ...string) {
	t.Helper()
	if len(m) != len(want) {
		t.Fatalf("keys %v, want %v", sortedKeys(m), want)
	}
	for _, k := range want {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing key %q (got %v)", k, sortedKeys(m))
		}
	}
}

func v3RFC3339(t *testing.T, s string) {
	t.Helper()
	if _, err := time.Parse(time.RFC3339, s); err != nil {
		t.Fatalf("timestamp %q is not RFC3339: %v", s, err)
	}
}

func v3Today(offset int) string {
	return time.Now().AddDate(0, 0, offset).Format("2006-01-02")
}

func v3Week() string {
	y, w := time.Now().ISOWeek()
	return fmt.Sprintf("%d-W%02d", y, w)
}

// v3New creates a runner with an initialized database.
func v3New(t *testing.T) *runner {
	t.Helper()
	r := newRunner(t)
	v3OK(t, r.run("init", "--non-interactive", "--scope", "id=personal,kind=personal"))
	return r
}

// v3WorkItem captures one entry and processes it into a work item.
func v3WorkItem(t *testing.T, r *runner, key, title string) string {
	t.Helper()
	got := v3OK(t, r.run("capture", "--key", key, "input for "+title))
	cid := v3Str(t, v3Data(t, got), "id")
	p := v3OK(t, r.run("process", "--outcome", "work_items", "--title", title, cid))
	items := v3Arr(t, v3Data(t, p), "work_items")
	if len(items) == 0 {
		t.Fatalf("process %s produced no work item", cid)
	}
	item, ok := items[0].(map[string]any)
	if !ok {
		t.Fatalf("work item is %T", items[0])
	}
	return v3Str(t, item, "id")
}

// v3HasEdge reports whether the edge list contains the relation.
func v3HasEdge(edges []any, relation, fromType, fromID, toType, toID string) bool {
	for _, raw := range edges {
		e, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if e["relation"] == relation && e["from_type"] == fromType &&
			e["from_id"] == fromID && e["to_type"] == toType && e["to_id"] == toID {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- features

// 1. Provenance: capture -> work item is a produced edge; unknown ids fail
// with not_found.
func v3Provenance(t *testing.T) {
	r := v3New(t)

	c := v3OK(t, r.run("capture", "--key", "v3-cap", "renew the parking permit"))
	cd := v3Data(t, c)
	cid := v3Str(t, cd, "id")
	if !v3ID.MatchString(cid) {
		t.Fatalf("capture id %q does not match %s", cid, v3ID)
	}
	v3RFC3339(t, v3Str(t, cd, "captured_at"))

	p := v3OK(t, r.run("process", "--outcome", "work_items", "--title", "X", cid))
	items := v3Arr(t, v3Data(t, p), "work_items")
	if len(items) != 1 {
		t.Fatalf("process produced %d work items, want 1", len(items))
	}
	item, ok := items[0].(map[string]any)
	if !ok {
		t.Fatalf("work item is %T", items[0])
	}
	tid := v3Str(t, item, "id")
	if !v3ID.MatchString(tid) {
		t.Fatalf("work item id %q does not match %s", tid, v3ID)
	}

	tr := v3OK(t, r.run("trace", tid))
	td := v3Data(t, tr)
	if kind := v3Str(t, td, "kind"); kind != "work_item" {
		t.Fatalf("trace kind %q, want work_item", kind)
	}
	edges := v3Arr(t, td, "edges")
	if !v3HasEdge(edges, "produced", "capture", cid, "work_item", tid) {
		t.Fatalf("trace edges %v lack capture->work_item produced edge", edges)
	}

	// An id that does not exist is not_found.
	v3Fail(t, r.run("trace", "T-19990101-999"), "not_found")
}

// 2. prepare --packet stays under its byte cap and is smaller than the
// uncapped brief.
func v3PreparePacket(t *testing.T) {
	r := v3New(t)

	long := strings.Repeat("long title ", 30) // 330 chars, clipped in the packet
	v3WorkItem(t, r, "p1", long)
	for i := 2; i <= 4; i++ {
		v3WorkItem(t, r, fmt.Sprintf("p%d", i), fmt.Sprintf("errand number %d", i))
	}
	v3OK(t, r.run("capture", "--key", "p-pending", "still sitting in the inbox"))

	date := v3Today(0)
	pk := v3OK(t, r.run("prepare", "--packet", "--date", date))
	if n := len(pk.Data); n > 1536 {
		t.Fatalf("packet data is %d bytes, want <= 1536", n)
	}
	pd := v3Data(t, pk)
	for _, key := range []string{"profile", "date", "candidates", "pending_captures", "waiting"} {
		if _, ok := pd[key]; !ok {
			t.Fatalf("packet lacks %q: %s", key, pk.Data)
		}
	}
	if got := v3Str(t, pd, "date"); got != date {
		t.Fatalf("packet date %q, want %q", got, date)
	}
	cands := v3Arr(t, pd, "candidates")
	if len(cands) == 0 || len(cands) > 3 {
		t.Fatalf("packet has %d candidates, want 1..3", len(cands))
	}
	for _, raw := range cands {
		cand, _ := raw.(map[string]any)
		title := v3Str(t, cand, "title")
		if len(title) > 120 {
			t.Fatalf("candidate title is %d chars, want <= 120: %q", len(title), title)
		}
	}
	if pending := v3Num(t, pd, "pending_captures"); pending < 1 {
		t.Fatalf("pending_captures %v, want >= 1", pending)
	}
	if _, ok := pd["waiting"]; !ok {
		t.Fatalf("packet lacks waiting: %s", pk.Data)
	}

	full := v3OK(t, r.run("prepare", "--date", date))
	if len(full.Data) <= len(pk.Data) {
		t.Fatalf("packet (%d bytes) is not smaller than the uncapped brief (%d bytes)",
			len(pk.Data), len(full.Data))
	}
}

var v3MetricKeys = []string{
	"captures_processed", "captures_received", "completed_items",
	"focus_minutes", "focus_sessions", "mit_completed", "mit_planned",
	"overdue_routines", "plan_items",
}

// 3. Measurement: --derive writes the metrics object, review show reads it
// back and a missing period is not_found.
func v3Measurement(t *testing.T) {
	r := v3New(t)
	date := v3Today(0)

	rev := v3OK(t, r.run("review", "daily", "--period", date,
		"--outcomes", "shipped the release", "--coverage", "1", "--derive"))
	rd := v3Data(t, rev)
	v3RFC3339(t, v3Str(t, rd, "created_at"))
	v3Keys(t, v3Obj(t, rd, "metrics"), v3MetricKeys...)

	show := v3OK(t, r.run("review", "show", "--period", date))
	sd := v3Data(t, show)
	v3Keys(t, sd, "id", "kind", "period", "metrics")
	if id := v3Str(t, sd, "id"); !v3ID.MatchString(id) {
		t.Fatalf("review id %q does not match %s", id, v3ID)
	}
	if kind := v3Str(t, sd, "kind"); kind != "daily" {
		t.Fatalf("review kind %q, want daily", kind)
	}
	if period := v3Str(t, sd, "period"); period != date {
		t.Fatalf("review period %q, want %q", period, date)
	}
	v3Keys(t, v3Obj(t, sd, "metrics"), v3MetricKeys...)

	v3Fail(t, r.run("review", "show", "--period", "1999-01-01"), "not_found")
}

// 4. Overrides: a mit override is addressed by actor, an unknown rule is
// invalid_input, and the row lets a daily plan carry four MITs while a
// weekly commit with --override is invalid_input.
func v3Overrides(t *testing.T) {
	r := v3New(t)
	date := v3Today(0)

	ov := v3OK(t, r.run("override", "add", "--rule", "mit", "--date", date, "--reason", "travel day"))
	od := v3Data(t, ov)
	want := "override:" + v3Str(t, od, "actor") + ":mit:" + date
	if id := v3Str(t, od, "id"); id != want {
		t.Fatalf("override id %q, want %q", id, want)
	}
	if d := v3Str(t, od, "local_date"); d != date {
		t.Fatalf("override local_date %q, want %q", d, date)
	}
	v3RFC3339(t, v3Str(t, od, "created_at"))

	v3Fail(t, r.run("override", "add", "--rule", "bogus", "--date", date, "--reason", "r"),
		"invalid_input")

	args := []string{"plan", "commit", "--period", date}
	var first string
	for i := 1; i <= 4; i++ {
		item := v3WorkItem(t, r, fmt.Sprintf("o%d", i), fmt.Sprintf("errand number %d", i))
		if i == 1 {
			first = item
		}
		args = append(args, "--item", item+":mit")
	}
	v3OK(t, r.run(args...))

	v3Fail(t, r.run("plan", "commit", "--kind", "weekly", "--period", v3Week(),
		"--override", want, "--item", first+":mit"), "invalid_input")
}

// 5. Calendar assertions: once a profile asserts its calendar, every other
// daily review without an assertion shows up in check.
func v3CalendarAssertion(t *testing.T) {
	r := v3New(t)
	d1, d2 := v3Today(0), v3Today(-1)

	first := v3OK(t, r.run("review", "daily", "--period", d1, "--outcomes", "shipped it",
		"--coverage", "1", "--calendar-assert", "the release went out"))
	id1 := v3Str(t, v3Data(t, first), "id")
	if !v3ID.MatchString(id1) {
		t.Fatalf("review id %q does not match %s", id1, v3ID)
	}

	clean := v3OK(t, r.run("check", "--scope", "personal"))
	if ok := v3Data(t, clean)["ok"]; ok != true {
		t.Fatalf("check data.ok = %v, want true (raw %s)", ok, clean.Data)
	}

	second := v3OK(t, r.run("review", "daily", "--period", d2, "--outcomes", "kept the lights on",
		"--coverage", "1"))
	id2 := v3Str(t, v3Data(t, second), "id")

	bad := r.run("check", "--scope", "personal")
	if bad.Exit != 0 {
		t.Fatalf("check exit %d, want 0: %s", bad.Exit, bad.raw)
	}
	be := v3Env(t, bad)
	bd := v3Data(t, be)
	if ok := bd["ok"]; ok != false {
		t.Fatalf("check data.ok = %v, want false (raw %s)", ok, be.Data)
	}
	want := "daily review " + id2 + " has no calendar assertion"
	found := false
	for _, raw := range v3Arr(t, bd, "errors") {
		if raw == want {
			found = true
		}
	}
	if !found {
		t.Fatalf("check errors lack %q: %v", want, bd["errors"])
	}
}

// 6. Decision records: verification requires an approver, search filters by
// record kind, and supersede links the generations.
func v3Decisions(t *testing.T) {
	r := v3New(t)
	tid := v3WorkItem(t, r, "d1", "decide the migration path")
	body := "Body of one covers the migration decision"

	put := v3OK(t, r.run("doc", "put", "--kind", "knowledge", "--slug", "d/one",
		"--body", body, "--record-kind", "decision", "--rationale", "the evidence points here",
		"--evidence", tid))
	pd := v3Data(t, put)
	if rk := v3Str(t, pd, "record_kind"); rk != "decision" {
		t.Fatalf("record_kind %q, want decision", rk)
	}
	if rev := pd["revision"]; rev != float64(1) {
		t.Fatalf("revision %v, want 1", rev)
	}
	v3RFC3339(t, v3Str(t, pd, "created_at"))
	docID := v3Str(t, pd, "id")

	verifying := []string{"doc", "put", "--kind", "knowledge", "--slug", "d/one",
		"--body", body, "--record-kind", "decision", "--rationale", "r",
		"--status", "verified", "--expected", "1"}
	v3Fail(t, r.run(verifying...), "invalid_input")
	verified := v3OK(t, r.run(append(verifying, "--approved-by", "alice")...))
	if status := v3Str(t, v3Data(t, verified), "status"); status != "verified" {
		t.Fatalf("status %q, want verified", status)
	}

	hits := v3DataArr(t, v3OK(t, r.run("doc", "search", "--query", body, "--record-kind", "decision")))
	found := false
	for _, raw := range hits {
		hit, _ := raw.(map[string]any)
		doc, _ := hit["document"].(map[string]any)
		if doc != nil && v3Str(t, doc, "id") == docID {
			found = true
		}
	}
	if !found {
		t.Fatalf("doc search %v does not contain %s", hits, docID)
	}
	v3Fail(t, r.run("doc", "search", "--query", body, "--record-kind", "bogus"), "invalid_input")

	v3OK(t, r.run("doc", "put", "--kind", "knowledge", "--slug", "d/two",
		"--body", "Body of two", "--record-kind", "decision", "--rationale", "second opinion"))
	sup := v3OK(t, r.run("doc", "supersede", "d/one", "d/two"))
	if got := v3Str(t, v3Data(t, sup), "supersedes_id"); got != docID {
		t.Fatalf("supersedes_id %q, want %q", got, docID)
	}
	old := v3Data(t, v3OK(t, r.run("doc", "get", "--kind", "knowledge", "--slug", "d/one")))
	if status := v3Str(t, old, "status"); status != "superseded" {
		t.Fatalf("old doc status %q, want superseded", status)
	}
	v3Fail(t, r.run("doc", "supersede", "d/two", "d/two"), "invalid_input")
}

// 7. learn propose writes a draft tied to its review by a learned edge, is
// idempotent, and refuses to touch a verified document.
func v3Learn(t *testing.T) {
	r := v3New(t)
	rev := v3OK(t, r.run("review", "daily", "--period", v3Today(0),
		"--outcomes", "ran the retrospective", "--coverage", "1"))
	rid := v3Str(t, v3Data(t, rev), "id")
	lesson := "Always pin the toolchain before the build"

	propose := func() v3Envelope {
		return v3OK(t, r.run("learn", "propose", "--review", rid,
			"--slug", "lessons/x", "--body", lesson))
	}
	p1 := v3Data(t, propose())
	if status := v3Str(t, p1, "status"); status != "draft" {
		t.Fatalf("learned document status %q, want draft", status)
	}
	if kind := v3Str(t, p1, "kind"); kind != "knowledge" {
		t.Fatalf("learned document kind %q, want knowledge", kind)
	}
	if rev := p1["revision"]; rev != float64(1) {
		t.Fatalf("revision %v, want 1", rev)
	}
	docID := v3Str(t, p1, "id")

	td := v3Data(t, v3OK(t, r.run("trace", rid)))
	edges := v3Arr(t, td, "edges")
	if !v3HasEdge(edges, "learned", "review", rid, "document", docID) {
		t.Fatalf("trace %s edges %v lack review->document learned edge", rid, edges)
	}

	p2 := v3Data(t, propose())
	if rev := p2["revision"]; rev != float64(1) {
		t.Fatalf("re-running learn propose raised the revision to %v, want 1", rev)
	}

	v3OK(t, r.run("doc", "put", "--kind", "knowledge", "--slug", "lessons/x",
		"--body", lesson, "--status", "verified", "--expected", "1", "--approved-by", "alice"))
	v3Fail(t, r.run("learn", "propose", "--review", rid,
		"--slug", "lessons/x", "--body", lesson), "invalid_transition")
}

// 8. Output caps: inbox next, doc search and source review all stay inside
// their byte budgets and say when they cut content.
func v3TokenCaps(t *testing.T) {
	r := v3New(t)

	v3OK(t, r.run("capture", "--key", "v3-long", strings.Repeat("z", 5000)))
	inbox := v3OK(t, r.run("inbox", "next"))
	if n := len(inbox.Data); n > 1024 {
		t.Fatalf("inbox next data is %d bytes, want <= 1024", n)
	}
	ind := v3Data(t, inbox)
	if text := v3Str(t, ind, "original_text"); len(text) > 280 {
		t.Fatalf("inbox next original_text is %d chars, want <= 280", len(text))
	}
	if tr := ind["truncated"]; tr != true {
		t.Fatalf("inbox next truncated = %v, want true (raw %s)", tr, inbox.Data)
	}

	for i := 1; i <= 10; i++ {
		body := fmt.Sprintf("matchable haystack body number %d with filler words so that ten results comfortably exceed the two kilobyte cap", i)
		v3OK(t, r.run("doc", "put", "--kind", "knowledge", "--slug", fmt.Sprintf("cap/%d", i),
			"--title", fmt.Sprintf("Doc %d", i), "--body", body))
	}
	ds := v3OK(t, r.run("doc", "search", "--query", "matchable"))
	if n := len(ds.Data); n > 2048 {
		t.Fatalf("doc search data is %d bytes, want <= 2048", n)
	}
	if hits := v3DataArr(t, ds); len(hits) == 0 {
		t.Fatalf("doc search returned no hits for %q", "matchable")
	}

	v3OK(t, r.run("source", "add", "--id", "feed", "--name", "Feed", "--scope", "personal",
		"--kind", "capture", "--connector", "manual"))
	items := make([]string, 0, 20)
	for i := 1; i <= 20; i++ {
		items = append(items, fmt.Sprintf(
			`{"external_id":"note-%03d","external_revision":"1","original_text":"incoming note %d long enough to push the review output over the cap","source_uri":"file:///notes/note-%03d.md"}`,
			i, i, i))
	}
	batch := fmt.Sprintf(
		`{"batch_id":"b1","idempotency_key":"r1","result_kind":"reported","retrieval":{"window":%q,"cursor":"","requested_limit":50,"provider_returned_limit":20,"complete_window":true,"truncated":false,"failures":[]},"items":[%s]}`,
		v3Today(0), strings.Join(items, ","))
	file := r.write("batch20.json", batch)

	sr := v3OK(t, r.run("source", "review", "--source", "feed", "--batch", "b1",
		"--key", "r1", "--file", file))
	if n := len(sr.Data); n > 1024 {
		t.Fatalf("source review data is %d bytes, want <= 1024", n)
	}
	review := v3Obj(t, v3Data(t, sr), "review")
	if tr := review["truncated"]; tr != true {
		t.Fatalf("source review truncated = %v, want true (raw %s)", tr, sr.Data)
	}
	if omitted := v3Num(t, review, "omitted"); omitted <= 0 {
		t.Fatalf("source review omitted = %v, want > 0", omitted)
	}

	full := v3OK(t, r.run("source", "review", "--source", "feed", "--batch", "b1",
		"--key", "r1", "--file", file, "--full"))
	if caps := v3Arr(t, v3Data(t, full), "captures"); len(caps) != 20 {
		t.Fatalf("--full returned %d captures, want all 20", len(caps))
	}
}

// 9. Directory connector: scans observe every file, rescan finds nothing new,
// a symlink escaping the root turns the coverage partial without advancing
// the cursor, and a non-absolute root is refused.
func v3DirectoryConnector(t *testing.T) {
	r := v3New(t)

	tree := r.path("tree")
	if err := os.MkdirAll(tree, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", tree, err)
	}
	for name, body := range map[string]string{"a.md": "alpha note\n", "b.md": "beta note\n"} {
		if err := os.WriteFile(filepath.Join(tree, name), []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	outside := r.path("outside.md")
	if err := os.WriteFile(outside, []byte("outside note\n"), 0o644); err != nil {
		t.Fatalf("write outside: %v", err)
	}

	add := v3OK(t, r.run("source", "add", "--id", "dir1", "--name", "D", "--scope", "personal",
		"--kind", "capture", "--connector", "directory",
		"--connection-ref", fmt.Sprintf("[%q]", tree)))
	if connector := v3Str(t, v3Data(t, add), "connector"); connector != "directory" {
		t.Fatalf("connector %q, want directory", connector)
	}

	// The first scan must ask for the full view: the default rendering caps
	// at 1024 bytes and would only show the first capture of the two.
	scan1 := v3Data(t, v3OK(t, r.run("source", "scan", "--id", "dir1", "--full")))
	if got := len(v3Arr(t, scan1, "captures")); got != 2 {
		t.Fatalf("first scan observed %d captures, want 2", got)
	}
	rev1 := v3Obj(t, scan1, "review")
	if kind := v3Str(t, rev1, "result_kind"); kind != "observed" {
		t.Fatalf("result_kind %q, want observed", kind)
	}
	if cov := v3Str(t, rev1, "coverage"); cov != "complete" {
		t.Fatalf("coverage %q, want complete", cov)
	}
	cursor1 := v3Str(t, v3Obj(t, rev1, "retrieval"), "cursor")
	if cursor1 == "" {
		t.Fatalf("scan cursor is empty: %s", scan1)
	}
	v3RFC3339(t, cursor1)

	scan2 := v3Data(t, v3OK(t, r.run("source", "scan", "--id", "dir1")))
	if got := len(v3Arr(t, scan2, "captures")); got != 0 {
		t.Fatalf("rescan reported %d new captures, want 0", got)
	}
	if cov := v3Str(t, v3Obj(t, scan2, "review"), "coverage"); cov != "complete" {
		t.Fatalf("rescan coverage %q, want complete", cov)
	}

	if err := os.Symlink(outside, filepath.Join(tree, "link.md")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	scan3 := v3Data(t, v3OK(t, r.run("source", "scan", "--id", "dir1")))
	rev3 := v3Obj(t, scan3, "review")
	if cov := v3Str(t, rev3, "coverage"); cov != "partial" {
		t.Fatalf("escaping symlink coverage %q, want partial", cov)
	}
	retr3 := v3Obj(t, rev3, "retrieval")
	failures := v3Arr(t, retr3, "failures")
	if len(failures) == 0 {
		t.Fatalf("escaping symlink produced no failure: %s", scan3)
	}
	if msg, _ := failures[0].(string); !strings.Contains(msg, "resolves outside root") {
		t.Fatalf("failure %q does not mention the escaped root", msg)
	}
	if cursor3 := v3Str(t, retr3, "cursor"); cursor3 != cursor1 {
		t.Fatalf("cursor advanced from %s to %s after a partial scan", cursor1, cursor3)
	}

	v3Fail(t, r.run("source", "add", "--id", "dir2", "--name", "D2", "--scope", "personal",
		"--kind", "capture", "--connector", "directory",
		"--connection-ref", `["relative/dir"]`), "invalid_input")
}

// 10. Export v2 carries the links table instead of knowledge_records, and a
// hand-written v1 export still restores.
func v3ExportV2(t *testing.T) {
	r := v3New(t)
	v3OK(t, r.run("capture", "--key", "x1", "exported capture"))
	v3OK(t, r.run("doc", "put", "--kind", "knowledge", "--slug", "e/one", "--body", "portable body"))

	out := r.path("export.json")
	ex := v3OK(t, r.run("export", "--out", out))
	if p := v3Str(t, v3Data(t, ex), "path"); p != out {
		t.Fatalf("export path %q, want %q", p, out)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read export: %v", err)
	}
	var exp struct {
		Format  string                     `json:"format"`
		Version int                        `json:"version"`
		Tables  map[string]json.RawMessage `json:"tables"`
	}
	if err := json.Unmarshal(raw, &exp); err != nil {
		t.Fatalf("export is not valid JSON: %v", err)
	}
	if exp.Format != "ztd-export" {
		t.Fatalf("export format %q, want ztd-export", exp.Format)
	}
	if exp.Version != 2 {
		t.Fatalf("export version %d, want 2", exp.Version)
	}
	if _, ok := exp.Tables["links"]; !ok {
		t.Fatalf("export lacks a links table: %v", sortedTableNames(exp.Tables))
	}
	if _, ok := exp.Tables["knowledge_records"]; ok {
		t.Fatalf("v2 export still carries knowledge_records: %v", sortedTableNames(exp.Tables))
	}
	wantCaptures := rawCount(t, exp.Tables["captures"])

	restore := newRunner(t)
	rd := v3Data(t, v3OK(t, restore.run("restore", "--from", out)))
	tables := v3Obj(t, rd, "tables")
	if got := v3Num(t, tables, "captures"); got != wantCaptures {
		t.Fatalf("restore counted %v captures, want %v", got, wantCaptures)
	}
	if _, ok := tables["links"]; !ok {
		t.Fatalf("restore report lacks links: %v", tables)
	}

	// A version 1 export: same tables minus links, plus knowledge_records.
	v1Tables := make(map[string]json.RawMessage, len(exp.Tables)+1)
	for name, rows := range exp.Tables {
		if name == "links" {
			continue
		}
		v1Tables[name] = rows
	}
	v1Tables["knowledge_records"] = json.RawMessage("[]")
	v1Body, err := json.Marshal(map[string]any{
		"format":  exp.Format,
		"version": 1,
		"tables":  v1Tables,
	})
	if err != nil {
		t.Fatalf("marshal v1 export: %v", err)
	}
	v1Path := r.write("export_v1.json", string(v1Body))

	v1Restore := newRunner(t)
	v1Data := v3Data(t, v3OK(t, v1Restore.run("restore", "--from", v1Path)))
	if got := v3Num(t, v3Obj(t, v1Data, "tables"), "captures"); got != wantCaptures {
		t.Fatalf("v1 restore counted %v captures, want %v", got, wantCaptures)
	}
}

func sortedTableNames(tables map[string]json.RawMessage) []string {
	names := make([]string, 0, len(tables))
	for name := range tables {
		names = append(names, name)
	}
	return names
}

func rawCount(t *testing.T, rows json.RawMessage) float64 {
	t.Helper()
	var a []any
	if err := json.Unmarshal(rows, &a); err != nil {
		t.Fatalf("export table is not an array: %v", err)
	}
	return float64(len(a))
}
