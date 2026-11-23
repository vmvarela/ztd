package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

func (e *testEnv) sourceCmd(id string, scope domain.ScopeID) app.SourceCmd {
	return app.SourceCmd{
		Binding: e.binding, ID: id, Name: "source " + id, Scope: scope,
		Kind: domain.SourceKindCapture, Connector: domain.SourceConnectorManual,
	}
}

func (e *testEnv) mustAddSource(id string, scope domain.ScopeID) domain.Source {
	e.t.Helper()
	src, err := e.s.AddSource(e.ctx(), e.sourceCmd(id, scope), e.now)
	if err != nil {
		e.t.Fatalf("AddSource(%s): %v", id, err)
	}
	return src
}

func (e *testEnv) sourceRow(id string) (coverage, cursor, lastAttempt, lastSuccess string) {
	e.t.Helper()
	var attempt, success any
	err := e.s.db.QueryRowContext(e.ctx(),
		`SELECT coverage_state, cursor, last_attempt_at, last_success_at FROM sources WHERE id = ?`, id).
		Scan(&coverage, &cursor, &attempt, &success)
	if err != nil {
		e.t.Fatalf("source row %s: %v", id, err)
	}
	return coverage, cursor, fmtAny(attempt), fmtAny(success)
}

func fmtAny(v any) string {
	switch t := v.(type) {
	case nil:
		return "<nil>"
	case string:
		return t
	default:
		return ""
	}
}

// TestAddSourceValidationTable pins the shared precondition checks on both
// entry points: the service wrapper and the store behind it. Rejected input
// writes nothing at all.
func TestAddSourceValidationTable(t *testing.T) {
	e := newTestEnv(t)
	svc := app.New(e.s)
	cases := []struct {
		name   string
		mutate func(app.SourceCmd) app.SourceCmd
		want   domain.Family // empty means success
	}{
		{"manual capture source", func(c app.SourceCmd) app.SourceCmd { return c }, ""},
		{"calendar directory source", func(c app.SourceCmd) app.SourceCmd {
			c.ID, c.Kind, c.Connector = "cal", domain.SourceKindCalendar, domain.SourceConnectorDirectory
			return c
		}, ""},
		{"id with uppercase", func(c app.SourceCmd) app.SourceCmd {
			c.ID = "GitHub"
			return c
		}, domain.InvalidInput},
		{"id starting with a digit", func(c app.SourceCmd) app.SourceCmd {
			c.ID = "1source"
			return c
		}, domain.InvalidInput},
		{"id too short", func(c app.SourceCmd) app.SourceCmd {
			c.ID = "a"
			return c
		}, domain.InvalidInput},
		{"id too long", func(c app.SourceCmd) app.SourceCmd {
			c.ID = "a" + strings.Repeat("b", 64)
			return c
		}, domain.InvalidInput},
		{"missing name", func(c app.SourceCmd) app.SourceCmd {
			c.Name = "  "
			return c
		}, domain.InvalidInput},
		{"unknown kind", func(c app.SourceCmd) app.SourceCmd {
			c.Kind = "email"
			return c
		}, domain.InvalidInput},
		{"unknown connector", func(c app.SourceCmd) app.SourceCmd {
			c.Connector = "carrier_pigeon"
			return c
		}, domain.InvalidInput},
		{"scope outside binding", func(c app.SourceCmd) app.SourceCmd {
			c.Scope = "work"
			return c
		}, domain.ScopeDenied},
		{"missing scope", func(c app.SourceCmd) app.SourceCmd {
			c.Scope = ""
			return c
		}, domain.InvalidInput},
		{"scope absent from store", func(c app.SourceCmd) app.SourceCmd {
			c.Binding = domain.ScopeBinding{Profile: "personal", Actor: "tester",
				Scopes: []domain.ScopeID{"personal", "ghost"}}
			c.Scope = "ghost"
			return c
		}, domain.InvalidInput},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cmd := tc.mutate(e.sourceCmd("src", "personal"))
			before := e.counts()
			_, err := svc.AddSource(e.ctx(), cmd)
			if tc.want == "" {
				if err != nil {
					t.Fatalf("service AddSource: %v", err)
				}
			} else {
				wantFamily(t, err, tc.want)
			}
			_, err = e.s.AddSource(e.ctx(), cmd, e.now)
			if tc.want == "" {
				if err != nil {
					t.Fatalf("store AddSource: %v", err)
				}
			} else {
				wantFamily(t, err, tc.want)
				if after := e.counts(); after != before {
					t.Fatalf("rejected AddSource wrote state: before %v after %v", before, after)
				}
			}
		})
	}
}

func TestAddSourceAndListSources(t *testing.T) {
	e := newTestEnv(t)
	// Insert out of order: the listing must still be deterministic.
	e.mustAddSource("zeta", "personal")
	first := e.mustAddSource("alpha", "personal")
	e.mustAddSource("os-src", "opensource")

	if first.AuthState != "unknown" || first.Coverage != domain.CoverageUnknown ||
		first.Cursor != "" || first.LastAttemptAt != nil || first.LastSuccessAt != nil {
		t.Fatalf("unexpected source defaults: %+v", first)
	}

	got, err := e.s.ListSources(e.ctx(), e.binding)
	if err != nil {
		t.Fatalf("ListSources: %v", err)
	}
	var ids []string
	for _, src := range got {
		ids = append(ids, src.ID)
	}
	if strings.Join(ids, ",") != "alpha,os-src,zeta" {
		t.Fatalf("listed ids = %v, want deterministic order alpha,os-src,zeta", ids)
	}
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	got, err = e.s.ListSources(e.ctx(), onlyOS)
	if err != nil || len(got) != 1 || got[0].ID != "os-src" {
		t.Fatalf("scoped ListSources = %+v (err %v), want only os-src", got, err)
	}
}

func TestAddSourceDuplicateIdenticalVsConflict(t *testing.T) {
	e := newTestEnv(t)
	first := e.mustAddSource("gh", "personal")
	before := e.counts()

	again, err := e.s.AddSource(e.ctx(), e.sourceCmd("gh", "personal"), e.now.Add(time.Hour))
	if err != nil {
		t.Fatalf("identical re-add: %v", err)
	}
	if again.ID != first.ID || again.CreatedAt != first.CreatedAt || again.UpdatedAt != first.UpdatedAt {
		t.Fatalf("identical re-add returned a different row:\n%+v\n%+v", first, again)
	}
	if after := e.counts(); after != before {
		t.Fatalf("identical re-add wrote state: before %v after %v", before, after)
	}

	changed := e.sourceCmd("gh", "personal")
	changed.Name = "renamed"
	_, err = e.s.AddSource(e.ctx(), changed, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("conflicting re-add wrote state: before %v after %v", before, after)
	}
}

func TestApplySourcesCreatesUpdatesAndNoops(t *testing.T) {
	e := newTestEnv(t)
	first := e.sourceCmd("github", "personal")
	first.Name = "GitHub notifications"
	first.Connector = domain.SourceConnectorHostMCP
	first.Provider = "github"
	first.Cadence = "daily"
	second := e.sourceCmd("mail", "personal")
	cmds := []app.SourceCmd{first, second}
	out, err := e.s.ApplySources(e.ctx(), cmds, e.now)
	if err != nil {
		t.Fatalf("ApplySources create: %v", err)
	}
	if len(out) != 2 || out[0].ID != "github" || out[1].ID != "mail" {
		t.Fatalf("unexpected apply output: %+v", out)
	}
	before := e.counts()
	// Same configuration is a no-op.
	if _, err := e.s.ApplySources(e.ctx(), cmds, e.now.Add(time.Minute)); err != nil {
		t.Fatalf("ApplySources no-op: %v", err)
	}
	after := e.counts()
	if after[6] != before[6] || after[4] != before[4] {
		t.Fatalf("no-op wrote rows: before=%v after=%v", before, after)
	}
	// A changed configuration updates only the configured fields and keeps
	// coverage/cursor untouched.
	if _, err := e.s.db.ExecContext(e.ctx(),
		`UPDATE sources SET coverage_state = 'unverified', cursor = 'cur-1' WHERE id = 'github'`); err != nil {
		t.Fatalf("seed coverage: %v", err)
	}
	first.Name = "GitHub triage"
	first.Cadence = "hourly"
	if _, err := e.s.ApplySources(e.ctx(), []app.SourceCmd{first}, e.now.Add(time.Hour)); err != nil {
		t.Fatalf("ApplySources update: %v", err)
	}
	var name, cadence, coverage, cursor string
	if err := e.s.db.QueryRowContext(e.ctx(),
		`SELECT name, cadence, coverage_state, cursor FROM sources WHERE id = 'github'`).
		Scan(&name, &cadence, &coverage, &cursor); err != nil {
		t.Fatalf("read updated source: %v", err)
	}
	if name != "GitHub triage" || cadence != "hourly" || coverage != "unverified" || cursor != "cur-1" {
		t.Fatalf("unexpected updated source: name=%q cadence=%q coverage=%q cursor=%q", name, cadence, coverage, cursor)
	}
}

func TestApplySourcesRejectsDuplicateAndForeignID(t *testing.T) {
	e := newTestEnv(t)
	cmd := e.sourceCmd("github", "personal")
	if _, err := e.s.ApplySources(e.ctx(), []app.SourceCmd{cmd, cmd}, e.now); domain.FamilyOf(err) != domain.InvalidInput {
		t.Fatalf("duplicate id: got %v", err)
	}
	if _, err := e.s.AddSource(e.ctx(), e.sourceCmd("mail", "opensource"), e.now); err != nil {
		t.Fatalf("seed foreign source: %v", err)
	}
	foreign := e.sourceCmd("mail", "personal")
	foreign.Provider = "changed"
	if _, err := e.s.ApplySources(e.ctx(), []app.SourceCmd{foreign}, e.now); domain.FamilyOf(err) != domain.Conflict {
		t.Fatalf("foreign id: got %v", err)
	}
	tooMany := make([]app.SourceCmd, domain.MaxSourceConfigItems+1)
	for i := range tooMany {
		tooMany[i] = e.sourceCmd("s"+strconv.Itoa(i), "personal")
	}
	if _, err := e.s.ApplySources(e.ctx(), tooMany, e.now); domain.FamilyOf(err) != domain.InvalidInput {
		t.Fatalf("oversized config: got %v", err)
	}
}

func TestSourceScopeIsolation(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("personal-src", "personal")
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}

	if got, err := e.s.ListSources(e.ctx(), onlyOS); err != nil || len(got) != 0 {
		t.Fatalf("cross-scope ListSources leaked %d rows (err %v)", len(got), err)
	}
	cmd := e.sourceCmd("sneaky", "personal")
	cmd.Binding = onlyOS
	if _, err := e.s.AddSource(e.ctx(), cmd, e.now); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("cross-scope AddSource: got %v, want scope_denied", err)
	}

	review := app.SourceReviewCmd{
		Binding: onlyOS, SourceID: "personal-src", BatchID: "b", Key: "k",
		ResultKind: "reported", Items: []domain.SourceItem{{OriginalText: "leak"}},
	}
	if _, _, err := e.s.RecordSourceReview(e.ctx(), review, e.now); !domain.Of(err, domain.ScopeDenied) {
		t.Fatalf("cross-scope RecordSourceReview: got %v, want scope_denied", err)
	}
	review.Binding = e.binding
	review.SourceID = "missing-src"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), review, e.now); !domain.Of(err, domain.NotFound) {
		t.Fatalf("missing source review: got %v, want not_found", err)
	}
	if n := e.count(`SELECT count(*) FROM source_reviews`); n != 0 {
		t.Fatalf("rejected reviews wrote %d rows", n)
	}
}

func reportedBatch(key, batch string, items ...domain.SourceItem) app.SourceReviewCmd {
	return app.SourceReviewCmd{
		BatchID: batch, Key: key, ResultKind: "reported",
		Retrieval: domain.SourceRetrieval{
			Window: "2026-11-18", Cursor: "cur-1", RequestedLimit: 50,
			ProviderReturnedLimit: len(items), CompleteWindow: true,
		},
		Items: items,
	}
}

func TestRecordSourceReviewCreatesCaptures(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	occurred := e.now.Add(-time.Hour)
	cmd := reportedBatch("rev-1", "batch-1",
		domain.SourceItem{ExternalID: "issue-1", ExternalRevision: "r1", OriginalText: "fix the bug",
			SourceURI: "https://example.test/1", OccurredAt: &occurred, ProviderMetadataSummary: "issue"},
		domain.SourceItem{OriginalText: "manual note"},
	)
	cmd.Binding = e.binding
	cmd.SourceID = "gh"

	review, captures, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now)
	if err != nil {
		t.Fatalf("RecordSourceReview: %v", err)
	}
	if review.ID == "" || review.SourceID != "gh" || review.BatchID != "batch-1" ||
		review.ResultKind != "reported" || review.Coverage != domain.CoverageUnverified ||
		!review.CreatedAt.Equal(e.now) {
		t.Fatalf("unexpected review: %+v", review)
	}
	if len(review.CaptureIDs) != 2 || len(captures) != 2 {
		t.Fatalf("review captures = %d/%d, want 2/2", len(review.CaptureIDs), len(captures))
	}
	mustJSONEqual(t, cmd.Retrieval, review.Retrieval, "retrieval")
	first := captures[0]
	if first.SourceID != "gh" || first.ExternalID == nil || *first.ExternalID != "issue-1" ||
		first.ExternalRevision == nil || *first.ExternalRevision != "r1" ||
		first.OriginalText != "fix the bug" || first.ContentHash != sha256hex("fix the bug") ||
		first.SourceURI == nil || *first.SourceURI != "https://example.test/1" ||
		first.OccurredAt == nil || !first.OccurredAt.Equal(occurred) ||
		first.State != domain.Pending || first.Revision != 1 {
		t.Fatalf("unexpected external capture: %+v", first)
	}
	if second := captures[1]; second.ExternalID != nil || second.OriginalText != "manual note" {
		t.Fatalf("unexpected plain capture: %+v", second)
	}
	if n := e.count(`SELECT count(*) FROM captures`); n != 2 {
		t.Fatalf("captures = %d, want 2", n)
	}
	if n := e.count(`SELECT count(*) FROM source_reviews`); n != 1 {
		t.Fatalf("source_reviews = %d, want 1", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'source_review'`); n != 1 {
		t.Fatalf("source review history = %d, want 1", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'capture'`); n != 2 {
		t.Fatalf("capture history = %d, want 2", n)
	}
	coverage, cursor, attempt, success := e.sourceRow("gh")
	if coverage != "unverified" || cursor != "" || attempt != fmtTime(e.now) || success != "<nil>" {
		t.Fatalf("source after batch: coverage %q cursor %q attempt %q success %q",
			coverage, cursor, attempt, success)
	}
}

func TestRecordSourceReviewIdempotency(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-1", "batch-1", domain.SourceItem{OriginalText: "first report"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"

	review, captures, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now)
	if err != nil {
		t.Fatalf("first RecordSourceReview: %v", err)
	}
	before := e.counts()

	// Same key and payload replays the stored result without any write.
	replay, replayCaps, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now.Add(time.Hour))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	mustJSONEqual(t, review, replay, "replayed review")
	mustJSONEqual(t, captures, replayCaps, "replayed captures")
	if after := e.counts(); after != before {
		t.Fatalf("replay wrote state: before %v after %v", before, after)
	}

	// Same key, different payload is an idempotency conflict.
	changed := reportedBatch("rev-1", "batch-1", domain.SourceItem{OriginalText: "second report"})
	changed.Binding = e.binding
	changed.SourceID = "gh"
	_, _, err = e.s.RecordSourceReview(e.ctx(), changed, e.now)
	wantFamily(t, err, domain.IdempotencyConflict)

	// A fresh key that reuses the batch id hits the batch guard and rolls
	// back completely: no review, no captures, no idempotency record.
	reused := reportedBatch("rev-2", "batch-1", domain.SourceItem{OriginalText: "first report"})
	reused.Binding = e.binding
	reused.SourceID = "gh"
	_, _, err = e.s.RecordSourceReview(e.ctx(), reused, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("conflicting batch wrote state: before %v after %v", before, after)
	}

	// An invalid item leaves nothing behind either.
	invalid := reportedBatch("rev-3", "batch-3", domain.SourceItem{OriginalText: "   "})
	invalid.Binding = e.binding
	invalid.SourceID = "gh"
	_, _, err = e.s.RecordSourceReview(e.ctx(), invalid, e.now)
	wantFamily(t, err, domain.InvalidInput)
	if after := e.counts(); after != before {
		t.Fatalf("rejected batch wrote state: before %v after %v", before, after)
	}
}

func TestRecordSourceReviewExternalIdentity(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	item := domain.SourceItem{ExternalID: "i1", ExternalRevision: "r1", OriginalText: "same item"}

	first := func(key, batch string, items ...domain.SourceItem) (domain.SourceReview, []domain.Capture) {
		t.Helper()
		cmd := reportedBatch(key, batch, items...)
		cmd.Binding = e.binding
		cmd.SourceID = "gh"
		review, caps, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now)
		if err != nil {
			t.Fatalf("RecordSourceReview(%s): %v", key, err)
		}
		return review, caps
	}

	_, caps := first("k1", "b1", item)
	if len(caps) != 1 {
		t.Fatalf("first batch created %d captures, want 1", len(caps))
	}

	// The identical external triple is skipped: no second capture.
	review2, caps2 := first("k2", "b2", item)
	if len(caps2) != 0 || len(review2.CaptureIDs) != 0 {
		t.Fatalf("duplicate triple created %d captures (ids %v), want none", len(caps2), review2.CaptureIDs)
	}
	if n := e.count(`SELECT count(*) FROM captures`); n != 1 {
		t.Fatalf("captures after duplicate triple = %d, want 1", n)
	}

	// A changed external revision is a new capture.
	revised := item
	revised.ExternalRevision, revised.OriginalText = "r2", "revised item"
	_, caps3 := first("k3", "b3", revised)
	if len(caps3) != 1 {
		t.Fatalf("revised batch created %d captures, want 1", len(caps3))
	}
	if n := e.count(`SELECT count(*) FROM captures`); n != 2 {
		t.Fatalf("captures after revision = %d, want 2", n)
	}
}

func TestRecordSourceReviewCoverageAndCursor(t *testing.T) {
	cases := []struct {
		name         string
		items        []domain.SourceItem
		retrieval    domain.SourceRetrieval
		wantCoverage domain.CoverageState
		wantSuccess  bool
	}{
		{
			name:  "failures mark partial",
			items: []domain.SourceItem{{OriginalText: "one"}},
			retrieval: domain.SourceRetrieval{Failures: []string{"provider timeout"},
				CompleteWindow: true},
			wantCoverage: domain.CoveragePartial, wantSuccess: false,
		},
		{
			name:         "truncated marks partial",
			items:        []domain.SourceItem{{OriginalText: "one"}},
			retrieval:    domain.SourceRetrieval{Truncated: true, CompleteWindow: true},
			wantCoverage: domain.CoveragePartial, wantSuccess: false,
		},
		{
			name:         "failures and truncation mark partial",
			items:        []domain.SourceItem{{OriginalText: "one"}},
			retrieval:    domain.SourceRetrieval{Failures: []string{"boom"}, Truncated: true},
			wantCoverage: domain.CoveragePartial, wantSuccess: false,
		},
		{
			name:         "empty batch with failures marks failed",
			items:        nil,
			retrieval:    domain.SourceRetrieval{Failures: []string{"auth expired"}},
			wantCoverage: domain.CoverageFailed, wantSuccess: false,
		},
		{
			name:         "clean reported batch stays unverified",
			items:        []domain.SourceItem{{OriginalText: "one"}},
			retrieval:    domain.SourceRetrieval{CompleteWindow: true},
			wantCoverage: domain.CoverageUnverified, wantSuccess: false,
		},
		{
			name:         "empty clean batch stays unverified",
			items:        nil,
			retrieval:    domain.SourceRetrieval{CompleteWindow: true},
			wantCoverage: domain.CoverageUnverified, wantSuccess: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := newTestEnv(t)
			e.mustAddSource("gh", "personal")
			// A pre-existing cursor proves a reported batch never advances it.
			e.mustExec(`UPDATE sources SET cursor = 'seed-cursor' WHERE id = 'gh'`)

			cmd := reportedBatch("k1", "b1", tc.items...)
			cmd.Binding = e.binding
			cmd.SourceID = "gh"
			cmd.Retrieval = tc.retrieval
			review, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now)
			if err != nil {
				t.Fatalf("RecordSourceReview: %v", err)
			}
			if review.Coverage != tc.wantCoverage {
				t.Fatalf("coverage = %q, want %q", review.Coverage, tc.wantCoverage)
			}
			coverage, cursor, attempt, success := e.sourceRow("gh")
			if coverage != string(tc.wantCoverage) {
				t.Fatalf("source coverage = %q, want %q", coverage, tc.wantCoverage)
			}
			if cursor != "seed-cursor" {
				t.Fatalf("cursor = %q, reported batches must not advance it", cursor)
			}
			if attempt != fmtTime(e.now) {
				t.Fatalf("last_attempt_at = %q, want %q", attempt, fmtTime(e.now))
			}
			if tc.wantSuccess && success != fmtTime(e.now) {
				t.Fatalf("last_success_at = %q, want %q", success, fmtTime(e.now))
			}
			if !tc.wantSuccess && success != "<nil>" {
				t.Fatalf("last_success_at = %q, want NULL after failures", success)
			}
		})
	}
}

// TestRecordSourceReviewObservedRejectedInService pins the trust boundary:
// only the service rejects observed coverage, with the adapter message, and
// the store keeps the observed path (including cursor advance) for a future
// trusted host adapter.
func TestRecordSourceReviewObservedRejectedInService(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	svc := app.New(e.s)

	cmd := reportedBatch("rev-1", "batch-1", domain.SourceItem{OriginalText: "seen"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	cmd.ResultKind = "observed"
	cmd.Retrieval.Cursor = "cur-advanced"

	_, _, err := svc.RecordSourceReview(e.ctx(), cmd)
	wantFamily(t, err, domain.InvalidInput)
	if !strings.Contains(err.Error(), "trusted host adapter") {
		t.Fatalf("observed rejection message = %q, want the trusted host adapter explanation", err)
	}
	if n := e.count(`SELECT count(*) FROM source_reviews`); n != 0 {
		t.Fatalf("service wrote %d reviews for observed coverage", n)
	}

	review, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now)
	if err != nil {
		t.Fatalf("store observed batch: %v", err)
	}
	if review.ResultKind != "observed" {
		t.Fatalf("stored result kind = %q, want observed", review.ResultKind)
	}
	if review.Coverage != domain.CoverageComplete {
		t.Fatalf("coverage = %q, want complete for a complete observed batch", review.Coverage)
	}
	coverage, cursor, _, success := e.sourceRow("gh")
	if coverage != string(domain.CoverageComplete) {
		t.Fatalf("source coverage = %q, want complete", coverage)
	}
	if cursor != "cur-advanced" {
		t.Fatalf("cursor = %q, a complete observed batch must advance it", cursor)
	}
	if success == "<nil>" {
		t.Fatal("last_success_at is NULL after a clean observed batch")
	}
}

func TestRecordSourceReviewRejectsOversizedInput(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	svc := app.New(e.s)

	big := reportedBatch("k-big", "b-big",
		domain.SourceItem{OriginalText: strings.Repeat("x", domain.MaxSourceItemBytes+1)})
	big.Binding, big.SourceID = e.binding, "gh"
	if _, _, err := svc.RecordSourceReview(e.ctx(), big); err == nil {
		t.Fatal("service accepted an item above the 64 KiB bound")
	}
	if _, _, err := e.s.RecordSourceReview(e.ctx(), big, e.now); err == nil {
		t.Fatal("store accepted an item above the 64 KiB bound")
	}

	many := make([]domain.SourceItem, domain.MaxSourceBatchItems+1)
	for i := range many {
		many[i] = domain.SourceItem{OriginalText: "item"}
	}
	over := reportedBatch("k-many", "b-many", many...)
	over.Binding, over.SourceID = e.binding, "gh"
	if _, _, err := svc.RecordSourceReview(e.ctx(), over); err == nil {
		t.Fatal("service accepted a batch above the 500 item bound")
	}
	if _, _, err := e.s.RecordSourceReview(e.ctx(), over, e.now); err == nil {
		t.Fatal("store accepted a batch above the 500 item bound")
	}

	if n := e.count(`SELECT count(*) FROM source_reviews`); n != 0 {
		t.Fatalf("oversized input wrote %d reviews", n)
	}
}

func TestExportRestoreIncludesSourcesAndReviews(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-1", "batch-1",
		domain.SourceItem{ExternalID: "i1", ExternalRevision: "r1", OriginalText: "ported"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("RecordSourceReview: %v", err)
	}

	export := filepath.Join(t.TempDir(), "export.json")
	if err := e.s.Export(e.ctx(), export); err != nil {
		t.Fatalf("Export: %v", err)
	}
	raw, err := os.ReadFile(export)
	if err != nil {
		t.Fatal(err)
	}
	var doc exportDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("decode export: %v", err)
	}
	if len(doc.Tables["sources"]) != 1 || len(doc.Tables["source_reviews"]) != 1 {
		t.Fatalf("export tables: sources %d source_reviews %d, want 1 and 1",
			len(doc.Tables["sources"]), len(doc.Tables["source_reviews"]))
	}

	dst := openTestStore(t, filepath.Join(t.TempDir(), "dst.db"))
	report, err := dst.Restore(e.ctx(), export)
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if report.Tables["sources"] != 1 || report.Tables["source_reviews"] != 1 {
		t.Fatalf("restore report = %+v, want sources and source_reviews at 1", report.Tables)
	}
	want, err := e.s.ListSources(e.ctx(), e.binding)
	if err != nil || len(want) != 1 {
		t.Fatalf("original ListSources = %+v (err %v)", want, err)
	}
	got, err := dst.ListSources(e.ctx(), e.binding)
	if err != nil || len(got) != 1 {
		t.Fatalf("restored ListSources = %+v (err %v)", got, err)
	}
	mustJSONEqual(t, want[0], got[0], "restored source")
	if n := countRows(t, dst, "source_reviews"); n != 1 {
		t.Fatalf("restored source_reviews = %d, want 1", n)
	}
	if n := countRows(t, dst, "captures"); n != 1 {
		t.Fatalf("restored captures = %d, want 1", n)
	}
	if rep, err := dst.Check(e.ctx(), &e.binding); err != nil || !rep.OK {
		t.Fatalf("check on restored store: %+v (err %v)", rep.Errors, err)
	}
}

func TestCheckCatchesDanglingSourceReference(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-1", "batch-1",
		domain.SourceItem{ExternalID: "i1", ExternalRevision: "r1", OriginalText: "linked"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("RecordSourceReview: %v", err)
	}

	rep, err := e.s.Check(e.ctx(), &e.binding)
	if err != nil || !rep.OK {
		t.Fatalf("healthy store reported errors: %+v (err %v)", rep.Errors, err)
	}

	// captures.source_id has no foreign key: an external capture can point at
	// a source that does not exist, and Check must flag exactly that.
	e.mustExec(`UPDATE captures SET source_id = 'ghost' WHERE external_id IS NOT NULL`)
	rep, err = e.s.Check(e.ctx(), &e.binding)
	if err != nil {
		t.Fatalf("Check after breakage: %v", err)
	}
	if rep.OK {
		t.Fatal("dangling source reference reported OK")
	}
	if joined := strings.Join(rep.Errors, "\n"); !strings.Contains(joined, "references a missing source") {
		t.Fatalf("check errors missing the dangling source report:\n%s", joined)
	}
}

func TestPrepareSurfacesSourceCoverage(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-1", "batch-1",
		domain.SourceItem{OriginalText: "reported item"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("RecordSourceReview: %v", err)
	}

	brief, err := e.s.Prepare(e.ctx(), e.binding, "2026-11-19")
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	if len(brief.Sources) != 1 || brief.Sources[0].ID != "gh" ||
		brief.Sources[0].Coverage != domain.CoverageUnverified {
		t.Fatalf("prepare sources = %+v, want gh unverified", brief.Sources)
	}
}

func TestDeleteSourceRemovesUnreferencedSource(t *testing.T) {
	e := newTestEnv(t)
	svc := app.New(e.s)
	src := e.mustAddSource("gh", "personal")
	e.mustAddSource("mail", "personal")

	got, err := svc.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"})
	if err != nil {
		t.Fatalf("DeleteSource: %v", err)
	}
	if got.ID != src.ID || got.Scope != "personal" || got.Name != src.Name {
		t.Fatalf("deleted source = %+v, want the registered row %+v", got, src)
	}
	if n := e.count(`SELECT count(*) FROM sources WHERE id = 'gh'`); n != 0 {
		t.Fatalf("source row survived delete: %d", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'source' AND entity_id = 'gh' AND event = 'deleted'`); n != 1 {
		t.Fatalf("deleted history events = %d, want 1 (created history must stay)", n)
	}
	if n := e.count(`SELECT count(*) FROM history_events WHERE entity_type = 'source' AND entity_id = 'gh' AND event = 'created'`); n != 1 {
		t.Fatalf("created history events = %d, want 1 kept", n)
	}
	listed, err := e.s.ListSources(e.ctx(), e.binding)
	if err != nil || len(listed) != 1 || listed[0].ID != "mail" {
		t.Fatalf("after delete ListSources = %+v (err %v), want only mail", listed, err)
	}
}

func TestDeleteSourceRefusesReferencedSource(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-1", "batch-1", domain.SourceItem{OriginalText: "a report"})
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("seed review: %v", err)
	}
	before := e.counts()

	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"}, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("refused delete wrote state: before %v after %v", before, after)
	}
	if n := e.count(`SELECT count(*) FROM sources WHERE id = 'gh'`); n != 1 {
		t.Fatalf("referenced source was removed")
	}
}

func TestDeleteSourceRefusesCapturesFromSource(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	if _, err := e.s.db.ExecContext(e.ctx(),
		`INSERT INTO captures (id, scope_id, source_id, original_text, content_hash, captured_at,
		   processing_state, revision)
		 VALUES ('C-x', 'personal', 'gh', 'plain', 'h', ?, 'pending', 1)`, fmtTime(e.now)); err != nil {
		t.Fatalf("seed capture: %v", err)
	}
	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"}, e.now)
	wantFamily(t, err, domain.Conflict)
}

func TestDeleteSourceScopeAndNotFound(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("personal-src", "personal")
	onlyOS := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"opensource"}}
	before := e.counts()

	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: onlyOS, ID: "personal-src"}, e.now)
	wantFamily(t, err, domain.ScopeDenied)
	_, err = e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "missing"}, e.now)
	wantFamily(t, err, domain.NotFound)
	_, err = e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "Bad Id"}, e.now)
	wantFamily(t, err, domain.InvalidInput)
	if after := e.counts(); after != before {
		t.Fatalf("rejected deletes wrote state: before %v after %v", before, after)
	}
}

func TestDeleteSourceIdempotentReplay(t *testing.T) {
	e := newTestEnv(t)
	first := e.mustAddSource("gh", "personal")
	cmd := app.SourceDeleteCmd{Binding: e.binding, ID: "gh", Key: "del-1"}
	if _, err := e.s.DeleteSource(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	before := e.counts()

	// The same key replays the stored source without writing, even though the
	// row is gone now.
	replay, err := e.s.DeleteSource(e.ctx(), cmd, e.now.Add(time.Hour))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if replay.ID != first.ID || replay.Name != first.Name {
		t.Fatalf("replay = %+v, want stored source %+v", replay, first)
	}
	if after := e.counts(); after != before {
		t.Fatalf("replay wrote state: before %v after %v", before, after)
	}

	// The same key for another id is an idempotency conflict.
	e.mustAddSource("mail", "personal")
	other := app.SourceDeleteCmd{Binding: e.binding, ID: "mail", Key: "del-1"}
	_, err = e.s.DeleteSource(e.ctx(), other, e.now)
	wantFamily(t, err, domain.IdempotencyConflict)
}

// TestCaptureExplicitSourceMustBeRegisteredInPrimaryScope pins the source
// reference of a capture: an explicit id must be registered in the primary
// scope of the binding, and a refused capture writes nothing. An empty id keeps
// the implicit manual entry point, which needs no registered row.
func TestCaptureExplicitSourceMustBeRegisteredInPrimaryScope(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "opensource")
	before := e.counts()

	// The primary scope of e.binding is personal; gh lives in opensource.
	_, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: "c-1", Text: "x", SourceID: "gh"}, e.now)
	wantFamily(t, err, domain.ScopeDenied)
	_, err = e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: "c-2", Text: "x", SourceID: "missing"}, e.now)
	wantFamily(t, err, domain.NotFound)
	if after := e.counts(); after != before {
		t.Fatalf("refused capture wrote state: before %v after %v", before, after)
	}

	e.mustAddSource("notes", "personal")
	c, err := e.s.Capture(e.ctx(), app.CaptureCmd{Binding: e.binding, Key: "c-3", Text: "x", SourceID: "notes"}, e.now)
	if err != nil || c.SourceID != "notes" || c.Scope != "personal" {
		t.Fatalf("registered explicit source: capture %+v, err %v", c, err)
	}
	implicit := e.capture("implicit", "c-4")
	if implicit.SourceID != domain.ImplicitSourceID {
		t.Fatalf("implicit capture source = %q, want %s", implicit.SourceID, domain.ImplicitSourceID)
	}
}

// TestImplicitProvenanceDoesNotBlockRegisteredSourceDelete pins the namespace
// split: implicit captures and imported legacy rows carry an upper-case
// provenance that no source can register, so a source named "manual" or
// "legacy" deletes freely.
func TestImplicitProvenanceDoesNotBlockRegisteredSourceDelete(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("manual", "personal")
	e.mustAddSource("legacy", "personal")
	e.capture("implicit", "c-1")
	e.mustExec(`INSERT INTO captures (id, scope_id, source_id, original_text, content_hash, captured_at,
	     processing_state, revision)
	   VALUES ('C-imported', 'personal', ?, 'plain', 'h', ?, 'pending', 1)`, domain.LegacySourceID, fmtTime(e.now))
	for _, id := range []string{"manual", "legacy"} {
		if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: id}, e.now); err != nil {
			t.Fatalf("delete %s with only internal provenance rows: %v", id, err)
		}
	}
}

// TestPreSplitManualRowsKeepRegisteredManualSourceReferenced pins the
// conservative rule for historical rows: a capture written before the split
// with source_id "manual" cannot be told apart from a capture of a registered
// source "manual", so deleting that source stays refused and nothing is rewritten.
func TestPreSplitManualRowsKeepRegisteredManualSourceReferenced(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("manual", "personal")
	e.mustExec(`INSERT INTO captures (id, scope_id, source_id, original_text, content_hash, captured_at,
	     processing_state, revision)
	   VALUES ('C-old', 'personal', 'manual', 'plain', 'h', ?, 'pending', 1)`, fmtTime(e.now))
	before := e.counts()
	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "manual"}, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("refused delete wrote state: before %v after %v", before, after)
	}
}

// TestDeletedSourceIDCannotBeReused pins the no-reuse rule: after a delete the
// id keeps its deleted history, so add and apply both refuse it with conflict
// and write nothing.
func TestDeletedSourceIDCannotBeReused(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"}, e.now); err != nil {
		t.Fatalf("delete: %v", err)
	}
	before := e.counts()

	_, err := e.s.AddSource(e.ctx(), e.sourceCmd("gh", "personal"), e.now)
	wantFamily(t, err, domain.Conflict)
	_, err = e.s.ApplySources(e.ctx(), []app.SourceCmd{e.sourceCmd("fresh", "personal"), e.sourceCmd("gh", "personal")}, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("reused id wrote state: before %v after %v", before, after)
	}
	if n := e.count(`SELECT count(*) FROM sources WHERE id IN ('gh', 'fresh')`); n != 0 {
		t.Fatalf("sources after refused reuse = %d, want 0", n)
	}
}

// TestDeleteSourceRefusesReviewWithoutCaptures pins the source_reviews guard on
// its own: an empty reported batch leaves no captures, yet the source is still
// referenced and cannot be deleted.
func TestDeleteSourceRefusesReviewWithoutCaptures(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	cmd := reportedBatch("rev-empty", "batch-empty")
	cmd.Binding = e.binding
	cmd.SourceID = "gh"
	if _, _, err := e.s.RecordSourceReview(e.ctx(), cmd, e.now); err != nil {
		t.Fatalf("seed empty review: %v", err)
	}
	if n := e.count(`SELECT count(*) FROM captures`); n != 0 {
		t.Fatalf("empty review created %d captures, want 0", n)
	}
	before := e.counts()

	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"}, e.now)
	wantFamily(t, err, domain.Conflict)
	if after := e.counts(); after != before {
		t.Fatalf("refused delete wrote state: before %v after %v", before, after)
	}
	if n := e.count(`SELECT count(*) FROM sources WHERE id = 'gh'`); n != 1 {
		t.Fatalf("referenced source was removed")
	}
}

// TestDeleteSourceCountsOnlySameScopeCaptures pins the capture half of the
// reference guard: only captures in the source's own scope block deletion.
func TestDeleteSourceCountsOnlySameScopeCaptures(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	e.mustExec(`INSERT INTO captures (id, scope_id, source_id, original_text, content_hash, captured_at,
	     processing_state, revision)
	   VALUES ('C-foreign', 'opensource', 'gh', 'plain', 'h', ?, 'pending', 1)`, fmtTime(e.now))
	if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh"}, e.now); err != nil {
		t.Fatalf("foreign-scope capture blocked delete: %v", err)
	}

	e.mustAddSource("mail", "personal")
	e.mustExec(`INSERT INTO captures (id, scope_id, source_id, original_text, content_hash, captured_at,
	     processing_state, revision)
	   VALUES ('C-local', 'personal', 'mail', 'plain', 'h', ?, 'pending', 1)`, fmtTime(e.now))
	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "mail"}, e.now)
	wantFamily(t, err, domain.Conflict)
}

// TestDeleteSourceIdempotencyIsNamespacedByBinding pins the namespace: the same
// binding replays even with its scopes reordered, while another binding that
// reuses the key neither replays the stored result nor collides with it.
func TestDeleteSourceIdempotencyIsNamespacedByBinding(t *testing.T) {
	e := newTestEnv(t)
	e.mustAddSource("gh", "personal")
	e.mustAddSource("mail", "personal")
	if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: e.binding, ID: "gh", Key: "del-1"}, e.now); err != nil {
		t.Fatalf("first delete: %v", err)
	}

	reordered := e.binding
	reordered.Scopes = []domain.ScopeID{"opensource", "personal"}
	if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: reordered, ID: "gh", Key: "del-1"}, e.now); err != nil {
		t.Fatalf("same binding with reordered scopes did not replay: %v", err)
	}

	narrow := domain.ScopeBinding{Profile: "personal", Actor: "tester", Scopes: []domain.ScopeID{"personal"}}
	_, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: narrow, ID: "gh", Key: "del-1"}, e.now)
	wantFamily(t, err, domain.NotFound) // not a replay of the other binding's result
	if _, err := e.s.DeleteSource(e.ctx(), app.SourceDeleteCmd{Binding: narrow, ID: "mail", Key: "del-1"}, e.now); err != nil {
		t.Fatalf("other binding collided with the stored key: %v", err)
	}
	if n := e.count(`SELECT count(*) FROM sources`); n != 0 {
		t.Fatalf("sources after deletes = %d, want 0", n)
	}
}
