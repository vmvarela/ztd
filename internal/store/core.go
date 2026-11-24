package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const captureColumns = `id, scope_id, source_id, external_id, external_revision,
	original_text, content_hash, source_uri, occurred_at, captured_at,
	processing_state, processing_outcome, review_after, revision, outcome_json`

const workItemColumns = `id, scope_id, area_id, project_id, context_id, title,
	origin_capture_id, lifecycle, waiting_on, due_at, closure_kind, closed_at,
	resolution, revision, created_at, updated_at, custom_fields`

// lifecycleOrder sorts next, waiting, someday, then archived; callers append
// their tie-breakers.
const lifecycleOrder = `ORDER BY CASE lifecycle
	WHEN 'next' THEN 0 WHEN 'waiting' THEN 1 WHEN 'someday' THEN 2 ELSE 3 END, `

func nullStr(ns sql.NullString) *string {
	if !ns.Valid {
		return nil
	}
	v := ns.String
	return &v
}

func ptrID[T ~string](ns sql.NullString) *T {
	if !ns.Valid {
		return nil
	}
	v := T(ns.String)
	return &v
}

func argID[T ~string](v *T) any {
	if v == nil {
		return nil
	}
	return string(*v)
}

func scanCapture(sc scanner) (domain.Capture, error) {
	var (
		cap                                          domain.Capture
		extID, extRev, uri, occ, outcome, reviewVals sql.NullString
		captured, state                              string
		details                                      sql.NullString
	)
	if err := sc.Scan(&cap.ID, &cap.Scope, &cap.SourceID, &extID, &extRev,
		&cap.OriginalText, &cap.ContentHash, &uri, &occ, &captured, &state,
		&outcome, &reviewVals, &cap.Revision, &details); err != nil {
		return domain.Capture{}, err
	}
	cap.ExternalID = nullStr(extID)
	cap.ExternalRevision = nullStr(extRev)
	cap.SourceURI = nullStr(uri)
	cap.State = domain.ProcessingState(state)
	var err error
	if cap.CapturedAt, err = parseTime("captures.captured_at", captured); err != nil {
		return domain.Capture{}, err
	}
	if cap.OccurredAt, err = nullTime("captures.occurred_at", occ); err != nil {
		return domain.Capture{}, err
	}
	if cap.ReviewAfter, err = nullTime("captures.review_after", reviewVals); err != nil {
		return domain.Capture{}, err
	}
	// The column stores the outcome kind; the human-entered details live in the
	// process history event and the idempotent result payload.
	if outcome.Valid {
		o := domain.Outcome{Kind: domain.OutcomeKind(outcome.String)}
		if o.Kind == domain.OutcomeDefer {
			o.ReviewAfter = cap.ReviewAfter
		}
		cap.Outcome = &o
	}
	if details.Valid && details.String != "null" {
		if err := json.Unmarshal([]byte(details.String), &cap.Outcome); err != nil {
			return domain.Capture{}, err
		}
	}
	return cap, nil
}

func scanWorkItem(sc scanner) (domain.WorkItem, error) {
	var (
		w                                            domain.WorkItem
		area, proj, ctxID, origin                    sql.NullString
		waiting, due, closure, closed, resolutionVal sql.NullString
		created, updated, fields                     string
	)
	if err := sc.Scan(&w.ID, &w.Scope, &area, &proj, &ctxID, &w.Title, &origin,
		&w.Lifecycle, &waiting, &due, &closure, &closed, &resolutionVal,
		&w.Revision, &created, &updated, &fields); err != nil {
		return domain.WorkItem{}, err
	}
	w.AreaID = ptrID[domain.AreaID](area)
	w.ProjectID = ptrID[domain.ProjectID](proj)
	w.ContextID = ptrID[domain.ContextID](ctxID)
	w.OriginCaptureID = ptrID[domain.CaptureID](origin)
	w.WaitingOn = waiting.String
	w.ClosureKind = domain.ClosureKind(closure.String)
	w.Resolution = resolutionVal.String
	if fields != "" && fields != "{}" {
		if err := json.Unmarshal([]byte(fields), &w.CustomFields); err != nil {
			return domain.WorkItem{}, domain.Invalid("work item %s has invalid custom_fields: %v", w.ID, err)
		}
	}
	var err error
	if w.DueAt, err = nullTime("work_items.due_at", due); err != nil {
		return domain.WorkItem{}, err
	}
	if w.ClosedAt, err = nullTime("work_items.closed_at", closed); err != nil {
		return domain.WorkItem{}, err
	}
	if w.CreatedAt, err = parseTime("work_items.created_at", created); err != nil {
		return domain.WorkItem{}, err
	}
	if w.UpdatedAt, err = parseTime("work_items.updated_at", updated); err != nil {
		return domain.WorkItem{}, err
	}
	return w, nil
}

func collectWorkItems(rows *sql.Rows) ([]domain.WorkItem, error) {
	defer rows.Close()
	var out []domain.WorkItem
	for rows.Next() {
		w, err := scanWorkItem(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// insertHistory appends one append-only event for an entity created or changed
// in the current transaction.
func insertHistory(ctx context.Context, q queryer, entity, id, event, scopeID, profileID string,
	rev domain.Revision, payload any, now time.Time,
) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return domain.Invalid("history payload for %s %s is not serializable: %v", entity, id, err)
	}
	var scopeArg, profileArg any
	if scopeID != "" {
		scopeArg = scopeID
	}
	if profileID != "" {
		profileArg = profileID
	}
	_, err = q.ExecContext(ctx,
		`INSERT INTO history_events (entity_type, entity_id, scope_id, profile_id, event, revision, payload_json, created_at)
		     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		entity, id, scopeArg, profileArg, event, int64(rev), string(b), fmtTime(now))
	return err
}

// validateProcessOutcome mirrors app.validateOutcome so direct Repo callers
// get identical precondition checks.
func validateProcessOutcome(o domain.Outcome) error {
	switch o.Kind {
	case domain.OutcomeWorkItems:
		if len(o.Titles) == 0 {
			return domain.Invalid("work_items outcome requires at least one title")
		}
		for _, title := range o.Titles {
			if strings.TrimSpace(title) == "" {
				return domain.Invalid("work item titles cannot be blank")
			}
		}
	case domain.OutcomeReference:
	case domain.OutcomeImmediate:
		if strings.TrimSpace(o.ResultEvidence) == "" {
			return domain.Invalid("immediate outcome requires result evidence")
		}
	case domain.OutcomeDiscard:
		if strings.TrimSpace(o.Reason) == "" {
			return domain.Invalid("discard outcome requires a reason")
		}
	case domain.OutcomeDefer:
		if o.ReviewAfter == nil {
			return domain.Invalid("defer outcome requires review_after")
		}
	default:
		return domain.Invalid("unknown outcome kind %q", o.Kind)
	}
	return nil
}

// loadCaptureScope fetches a capture restricted to the binding scopes.
func loadCaptureScope(ctx context.Context, q queryer, b domain.ScopeBinding, id string) (domain.Capture, error) {
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.Capture{}, err
	}
	args = append([]any{id}, args...)
	row := q.QueryRowContext(ctx,
		"SELECT "+captureColumns+" FROM captures WHERE id = ? AND scope_id IN ("+clause+")", args...)
	cap, err := scanCapture(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Capture{}, rowAccessError(ctx, q, "captures", "capture", id)
	}
	if err != nil {
		return domain.Capture{}, err
	}
	return cap, nil
}

// captureHashVersion tags capture request hashes. Versions before the split
// hashed an omitted source as "manual", so an explicit registered "manual"
// hashed exactly like an implicit capture; the tag keeps the two apart.
const captureHashVersion = 2

// captureRequest is the versioned payload hashed for a capture request.
type captureRequest struct {
	Version int
	Cmd     app.CaptureCmd
}

// lookupCaptureIdem is lookupIdem for captures. A stored record also replays
// when it was written under the pre-split hash (legacyHash) and its stored
// source is one that build could have stored for this request: an omitted
// source was stored as "manual", and as domain.ImplicitSourceID by the build
// that split it. An explicit "manual" never replays such an implicit record.
// Pre-split rows cannot tell an omitted source from an explicit "manual", so an
// omitted retry may replay an explicit one; that is the inherited ambiguity.
func lookupCaptureIdem(ctx context.Context, q queryer, cmd app.CaptureCmd, hash, legacyHash string, out *domain.Capture) (bool, error) {
	var storedHash, result string
	err := q.QueryRowContext(ctx,
		"SELECT request_hash, result_json FROM idempotency_records WHERE command = 'capture' AND idempotency_key = ?",
		cmd.Key).Scan(&storedHash, &result)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, err
	}
	var stored domain.Capture
	if err := json.Unmarshal([]byte(result), &stored); err != nil {
		return false, domain.NewError(domain.IOError, "stored result for idempotency key %q is unreadable: %v", cmd.Key, err)
	}
	legacy := storedHash == legacyHash && legacySourceMatches(cmd.SourceID, stored.SourceID)
	if storedHash != hash && !legacy {
		return false, domain.NewError(domain.IdempotencyConflict,
			"idempotency key %q was already used with a different payload", cmd.Key)
	}
	*out = stored
	return true, nil
}

// legacySourceMatches reports whether a pre-split record stored under the
// legacy hash may replay for a request with the given source id.
func legacySourceMatches(requested, stored string) bool {
	if requested == "" {
		return stored == "manual" || stored == domain.ImplicitSourceID
	}
	return stored == requested
}

// Capture stores one immutable inbox entry.
//
// Pre: binding validates with at least one scope; key is set; text is nonblank
// valid UTF-8 within 64 KiB; external id and revision are both set or both empty.
// Post: one transaction writes one pending Capture with a content hash, its
// history and the idempotency record. An identical retry replays the result; a
// different payload conflicts; a duplicate external identity conflicts. Nothing
// is written on failure.
func (s *Store) Capture(ctx context.Context, cmd app.CaptureCmd, now time.Time) (domain.Capture, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Capture{}, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.Capture{}, err
	}
	if strings.TrimSpace(cmd.Text) == "" {
		return domain.Capture{}, domain.Invalid("capture text is required")
	}
	if !utf8.ValidString(cmd.Text) {
		return domain.Capture{}, domain.Invalid("capture text must be valid UTF-8")
	}
	if len(cmd.Text) > 64*1024 {
		return domain.Capture{}, domain.Invalid("capture text exceeds 64 KiB")
	}
	if (cmd.ExternalID == nil) != (cmd.ExternalRev == nil) {
		return domain.Capture{}, domain.Invalid("external id and external revision must be provided together")
	}
	if cmd.ExternalID != nil && *cmd.ExternalID == "" {
		return domain.Capture{}, domain.Invalid("external id cannot be empty")
	}
	if cmd.ExternalRev != nil && *cmd.ExternalRev == "" {
		return domain.Capture{}, domain.Invalid("external revision cannot be empty")
	}
	source := cmd.SourceID
	if source == "" {
		source = domain.ImplicitSourceID
	}
	hash, err := hashPayload(captureRequest{Version: captureHashVersion, Cmd: cmd})
	if err != nil {
		return domain.Capture{}, err
	}
	legacyCmd := cmd
	if legacyCmd.SourceID == "" {
		legacyCmd.SourceID = "manual"
	}
	legacyHash, err := hashPayload(legacyCmd)
	if err != nil {
		return domain.Capture{}, err
	}
	// The capture belongs to the binding's primary scope; the remaining scopes
	// stay visible to the same session.
	scope := cmd.Binding.Scopes[0]
	var cap domain.Capture
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupCaptureIdem(ctx, tx, cmd, hash, legacyHash, &cap)
		if err != nil || done {
			return err
		}
		// An implicit source (empty SourceID) stays the unregistered manual
		// entry point; an explicit one must be registered in the primary scope.
		if cmd.SourceID != "" {
			if err := checkSourceRef(ctx, tx, source, scope); err != nil {
				return err
			}
		}
		if cmd.ExternalID != nil {
			var one int
			err := tx.QueryRowContext(ctx,
				`SELECT 1 FROM captures WHERE scope_id = ? AND source_id = ? AND external_id = ? AND external_revision = ?`,
				string(scope), source, *cmd.ExternalID, *cmd.ExternalRev).Scan(&one)
			switch {
			case err == nil:
				return domain.NewError(domain.Conflict,
					"capture with external identity %s/%s/%s already exists in scope %s",
					source, *cmd.ExternalID, *cmd.ExternalRev, scope)
			case !errors.Is(err, sql.ErrNoRows):
				return err
			}
		}
		date := idDate(now)
		seq, err := nextDailySeq(ctx, tx, "captures", "C-"+date+"-")
		if err != nil {
			return err
		}
		cap = domain.Capture{
			ID:               domain.CaptureID(fmt.Sprintf("C-%s-%03d", date, seq)),
			Scope:            scope,
			SourceID:         source,
			ExternalID:       cmd.ExternalID,
			ExternalRevision: cmd.ExternalRev,
			OriginalText:     cmd.Text,
			ContentHash:      sha256hex(cmd.Text),
			SourceURI:        cmd.SourceURI,
			OccurredAt:       cmd.OccurredAt,
			CapturedAt:       now,
			State:            domain.Pending,
			Revision:         1,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO captures (id, scope_id, source_id, external_id, external_revision,
				original_text, content_hash, source_uri, occurred_at, captured_at,
				processing_state, processing_outcome, review_after, revision)
			     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, 1)`,
			string(cap.ID), string(cap.Scope), cap.SourceID, argID(cap.ExternalID),
			argID(cap.ExternalRevision), cap.OriginalText, cap.ContentHash,
			argID(cap.SourceURI), argTime(cap.OccurredAt), fmtTime(cap.CapturedAt),
		); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "capture", string(cap.ID), "captured",
			string(cap.Scope), "", 1, cap, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "capture", cmd.Key, hash, cap, now)
	})
	if err != nil {
		return domain.Capture{}, err
	}
	return cap, nil
}

// InboxNext returns the oldest capture awaiting processing in the binding
// scopes: pending, or deferred with review_after due at now. An empty inbox is
// not_found, never an empty success.
func (s *Store) InboxNext(ctx context.Context, b domain.ScopeBinding, now time.Time) (domain.Capture, error) {
	if err := b.Validate(); err != nil {
		return domain.Capture{}, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.Capture{}, err
	}
	args = append(args, fmtTime(now))
	row := s.db.QueryRowContext(ctx,
		`SELECT `+captureColumns+` FROM captures
		     WHERE scope_id IN (`+clause+`)
		       AND (processing_state = 'pending'
		            OR (processing_state = 'deferred' AND review_after <= ?))
		     ORDER BY captured_at ASC, id ASC LIMIT 1`, args...)
	cap, err := scanCapture(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Capture{}, domain.NewError(domain.NotFound, "no capture is awaiting processing in the active scopes")
	}
	if err != nil {
		return domain.Capture{}, err
	}
	return cap, nil
}

// inboxListCap bounds one listing call so a huge inbox stays readable.
const inboxListCap = 200

// ListInbox returns the captures awaiting processing in the binding scopes:
// pending, or deferred with review_after due at now, oldest first, capped at
// inboxListCap. An empty inbox is an empty result, not an error.
func (s *Store) ListInbox(ctx context.Context, b domain.ScopeBinding, now time.Time) ([]domain.Capture, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	args = append(args, fmtTime(now), inboxListCap)
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+captureColumns+` FROM captures
		     WHERE scope_id IN (`+clause+`)
		       AND (processing_state = 'pending'
		            OR (processing_state = 'deferred' AND review_after <= ?))
		     ORDER BY captured_at ASC, id ASC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Capture
	for rows.Next() {
		cap, err := scanCapture(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, cap)
	}
	return out, rows.Err()
}

func (s *Store) InboxStats(ctx context.Context, b domain.ScopeBinding, now time.Time) (app.InboxStats, error) {
	if err := b.Validate(); err != nil {
		return app.InboxStats{}, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return app.InboxStats{}, err
	}
	// The first placeholder is the deferred review cut-off in the SELECT list,
	// so the time argument must precede the scope arguments.
	args = append([]any{fmtTime(now)}, args...)
	row := s.db.QueryRowContext(ctx,
		`SELECT
		   COALESCE(SUM(CASE WHEN processing_state = 'pending' THEN 1 ELSE 0 END), 0),
		   COALESCE(SUM(CASE WHEN processing_state = 'deferred' AND review_after <= ? THEN 1 ELSE 0 END), 0)
		 FROM captures WHERE scope_id IN (`+clause+`)`, args...)
	var stats app.InboxStats
	if err := row.Scan(&stats.Pending, &stats.Due); err != nil {
		return app.InboxStats{}, err
	}
	stats.Remaining = stats.Pending + stats.Due
	return stats, nil
}

// GetCapture returns one capture in the binding scopes, or scope_denied /
// not_found without disclosing out-of-scope content.
func (s *Store) GetCapture(ctx context.Context, b domain.ScopeBinding, id domain.CaptureID) (domain.Capture, error) {
	if err := b.Validate(); err != nil {
		return domain.Capture{}, err
	}
	return loadCaptureScope(ctx, s.db, b, string(id))
}

// Process commits exactly one typed outcome for a capture.
//
// Pre: binding and key are valid; outcome carries the fields validateOutcome
// requires; the capture is in a bound scope, pending or deferred-and-due;
// Expected is 0 or equals the capture revision; references exist in scope.
// The work_items batch is bounded by len(Titles), a finite validated count.
// Post: one transaction inserts len(Titles) WorkItems and advances the capture
// to processed/discarded/deferred with revision+1, plus history and the
// idempotency record. Any error rolls back every write; an identical retry
// replays the stored result.
func (s *Store) Process(ctx context.Context, cmd app.ProcessCmd, now time.Time) (app.ProcessResult, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return app.ProcessResult{}, err
	}
	if err := requireKey(cmd.Key); err != nil {
		return app.ProcessResult{}, err
	}
	if cmd.ID == "" {
		return app.ProcessResult{}, domain.Invalid("capture id is required")
	}
	if err := validateProcessOutcome(cmd.Outcome); err != nil {
		return app.ProcessResult{}, err
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return app.ProcessResult{}, err
	}
	var result app.ProcessResult
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "process", cmd.Key, hash, &result)
		if err != nil || done {
			return err
		}
		cap, err := loadCaptureScope(ctx, tx, cmd.Binding, string(cmd.ID))
		if err != nil {
			return err
		}
		if cmd.Expected != 0 && cmd.Expected != cap.Revision {
			return domain.NewError(domain.StaleRevision,
				"capture %s is at revision %d, expected %d", cmd.ID, cap.Revision, cmd.Expected)
		}
		switch {
		case cap.State == domain.Pending:
		case cap.State == domain.Deferred && cap.Due(now):
		case cap.State == domain.Deferred:
			return domain.NewError(domain.InvalidTransition,
				"capture %s is deferred until %s", cmd.ID, fmtTime(*cap.ReviewAfter))
		default:
			return domain.NewError(domain.InvalidTransition,
				"capture %s is already %s", cmd.ID, cap.State)
		}
		if err := checkOutcomeRefs(ctx, tx, cap.Scope, cmd.Outcome); err != nil {
			return err
		}

		if cmd.Document != nil {
			if cmd.Outcome.Kind != domain.OutcomeReference {
				return domain.Invalid("document requires reference outcome")
			}
			docCmd := *cmd.Document
			docCmd.Binding = cmd.Binding
			if docCmd.Scope == "" {
				docCmd.Scope = cap.Scope
			}
			// Keep capture provenance in its boundary. Move/copy knowledge explicitly.
			if docCmd.Scope != cap.Scope {
				return domain.Invalid("reference document must use the capture scope")
			}
			doc, err := putDocumentTx(ctx, tx, docCmd, now)
			if err != nil {
				return err
			}
			cmd.Outcome.DocumentID = doc.ID
		}
		if cmd.Outcome.DocumentID != "" {
			if cmd.Outcome.Kind != domain.OutcomeReference {
				return domain.Invalid("document_id requires reference outcome")
			}
			if err := checkSameScope(ctx, tx, "documents", "document", cmd.Outcome.DocumentID, cap.Scope); err != nil {
				return err
			}
		}
		state := domain.Processed
		switch cmd.Outcome.Kind {
		case domain.OutcomeDiscard:
			state = domain.Discarded
		case domain.OutcomeDefer:
			state = domain.Deferred
		}
		var reviewAfter *time.Time
		if state == domain.Deferred {
			reviewAfter = cmd.Outcome.ReviewAfter
		}

		var items []domain.WorkItem
		if cmd.Outcome.Kind == domain.OutcomeWorkItems {
			prefix := "T-" + idDate(now) + "-"
			seq, err := nextDailySeq(ctx, tx, "work_items", prefix)
			if err != nil {
				return err
			}
			// Finite batch bound: exactly len(cmd.Outcome.Titles) inserts, each
			// title validated above; no other input reaches this loop.
			for i, title := range cmd.Outcome.Titles {
				item := domain.WorkItem{
					ID:              domain.WorkItemID(fmt.Sprintf("%s%03d", prefix, seq+i)),
					Scope:           cap.Scope,
					AreaID:          cmd.Outcome.AreaID,
					ProjectID:       cmd.Outcome.ProjectID,
					ContextID:       cmd.Outcome.ContextID,
					Title:           title,
					OriginCaptureID: &cap.ID,
					Lifecycle:       domain.Next,
					Revision:        1,
					CreatedAt:       now,
					UpdatedAt:       now,
				}
				if _, err := tx.ExecContext(ctx,
					`INSERT INTO work_items (id, scope_id, area_id, project_id, context_id, title,
						origin_capture_id, status, waiting_on, due_at, closed_at,
						resolution, revision, created_at, updated_at, custom_fields)
					     VALUES (?, ?, ?, ?, ?, ?, ?, 'next', NULL, NULL, NULL, NULL, 1, ?, ?, '{}')`,
					string(item.ID), string(item.Scope), argID(item.AreaID), argID(item.ProjectID),
					argID(item.ContextID), item.Title, string(*item.OriginCaptureID),
					fmtTime(item.CreatedAt), fmtTime(item.UpdatedAt),
				); err != nil {
					return err
				}
				if err := insertHistory(ctx, tx, "work_item", string(item.ID), "created",
					string(cap.Scope), "", 1, item, now); err != nil {
					return err
				}
				items = append(items, item)
			}
		}

		details, err := json.Marshal(cmd.Outcome)
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx,
			`UPDATE captures SET processing_state = ?, processing_outcome = ?, review_after = ?, revision = ?, outcome_json = ?, document_id = ?
			     WHERE id = ? AND scope_id = ? AND revision = ?`,
			string(state), string(cmd.Outcome.Kind), argTime(reviewAfter), cap.Revision+1, string(details), nullableString(cmd.Outcome.DocumentID),
			string(cap.ID), string(cap.Scope), cap.Revision)
		if err != nil {
			return err
		}
		if n, affErr := res.RowsAffected(); affErr == nil && n != 1 {
			return domain.NewError(domain.StaleRevision, "capture %s changed concurrently", cmd.ID)
		}
		cap.State = state
		cap.ReviewAfter = reviewAfter
		cap.Revision = cap.Revision.Next()
		outcome := cmd.Outcome
		cap.Outcome = &outcome
		if err := insertHistory(ctx, tx, "capture", string(cap.ID), "processed",
			string(cap.Scope), "", cap.Revision, cap, now); err != nil {
			return err
		}
		result = app.ProcessResult{Capture: cap, WorkItems: items}
		return writeIdem(ctx, tx, "process", cmd.Key, hash, result, now)
	})
	if err != nil {
		return app.ProcessResult{}, err
	}
	return result, nil
}

// checkOutcomeRefs rejects references that do not exist or belong to another
// scope than the capture.
func checkOutcomeRefs(ctx context.Context, q queryer, scope domain.ScopeID, o domain.Outcome) error {
	if o.ProjectID != nil {
		if err := checkSameScope(ctx, q, "projects", "project", string(*o.ProjectID), scope); err != nil {
			return err
		}
	}
	if o.AreaID != nil {
		if err := checkSameScope(ctx, q, "contexts", "area", string(*o.AreaID), scope); err != nil {
			return err
		}
	}
	if o.ContextID != nil {
		if err := checkSameScope(ctx, q, "contexts", "context", string(*o.ContextID), scope); err != nil {
			return err
		}
	}
	return nil
}

// GetWorkItem returns one work item in the binding scopes.
func (s *Store) GetWorkItem(ctx context.Context, b domain.ScopeBinding, id domain.WorkItemID) (domain.WorkItem, error) {
	if err := b.Validate(); err != nil {
		return domain.WorkItem{}, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.WorkItem{}, err
	}
	args = append([]any{string(id)}, args...)
	row := s.db.QueryRowContext(ctx,
		"SELECT "+workItemColumns+" FROM work_items WHERE id = ? AND scope_id IN ("+clause+")", args...)
	w, err := scanWorkItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.WorkItem{}, rowAccessError(ctx, s.db, "work_items", "work item", string(id))
	}
	if err != nil {
		return domain.WorkItem{}, err
	}
	return w, nil
}

// ListWorkItems returns scope-filtered work items ordered lifecycle then
// updated_at descending. An empty lifecycle lists every lifecycle.
func (s *Store) ListWorkItems(ctx context.Context, b domain.ScopeBinding, lifecycle domain.Lifecycle) ([]domain.WorkItem, error) {
	return s.ListWorkItemsFiltered(ctx, b, app.ListWorkItemsFilter{Lifecycle: lifecycle})
}

// ListWorkItemsFiltered returns the work items of the binding scopes that
// match the filter, ordered by lifecycle, then updated_at descending, then id.
// Lifecycle empty lists every lifecycle; Context matches contexts.name inside
// the binding scopes; Project matches project_id; Scope narrows to one scope
// the binding allows.
func (s *Store) ListWorkItemsFiltered(ctx context.Context, b domain.ScopeBinding, filter app.ListWorkItemsFilter) ([]domain.WorkItem, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	query := "SELECT " + workItemColumns + " FROM work_items WHERE scope_id IN (" + clause + ")"
	switch filter.Lifecycle {
	case "":
	case domain.Next, domain.Waiting, domain.Someday, domain.Archived:
		query += " AND lifecycle = ?"
		args = append(args, string(filter.Lifecycle))
	default:
		return nil, domain.Invalid("unknown lifecycle %q", filter.Lifecycle)
	}
	if filter.Context != "" {
		// The context must itself live in a bound scope, so a name that only
		// exists elsewhere cannot widen the listing.
		query += " AND context_id IN (SELECT id FROM contexts WHERE name = ? AND scope_id IN (" + clause + "))"
		args = append(args, filter.Context)
		args = append(args, scopeArgs(b)...)
	}
	if filter.Project != "" {
		query += " AND project_id = ?"
		args = append(args, string(filter.Project))
	}
	if filter.Scope != "" {
		if !b.Allows(filter.Scope) {
			return nil, domain.NewError(domain.ScopeDenied, "scope %s is outside the active scopes", filter.Scope)
		}
		query += " AND scope_id = ?"
		args = append(args, string(filter.Scope))
	}
	query += " " + lifecycleOrder + "updated_at DESC, id ASC"
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	return collectWorkItems(rows)
}

// Find runs a case-insensitive substring search over work item titles in the
// binding scopes, ordered lifecycle then updated_at descending. A limit of
// 0 selects the default of 10; any limit above 50 is capped at 50.
func (s *Store) Find(ctx context.Context, b domain.ScopeBinding, query string, limit int) ([]domain.WorkItem, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(query) == "" {
		return nil, domain.Invalid("search query is required")
	}
	switch {
	case limit <= 0:
		limit = 10
	case limit > 50:
		limit = 50
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	args = append(args, query, limit)
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+workItemColumns+" FROM work_items WHERE scope_id IN ("+clause+")"+
			" AND instr(lower(title), lower(?)) > 0 "+
			lifecycleOrder+"updated_at DESC, id ASC LIMIT ?", args...)
	if err != nil {
		return nil, err
	}
	return collectWorkItems(rows)
}
