package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const sourceColumns = `id, name, scope_id, kind, connector, provider, connection_ref,
	non_secret_query, cadence, auth_state, coverage_state, cursor,
	last_attempt_at, last_success_at, created_at, updated_at`

func scanSource(sc scanner) (domain.Source, error) {
	var (
		src                         domain.Source
		scope, kind, conn, coverage string
		lastAttempt, lastSuccess    sql.NullString
		created, updated            string
	)
	if err := sc.Scan(&src.ID, &src.Name, &scope, &kind, &conn, &src.Provider,
		&src.ConnectionRef, &src.NonSecretQuery, &src.Cadence, &src.AuthState,
		&coverage, &src.Cursor, &lastAttempt, &lastSuccess, &created, &updated); err != nil {
		return domain.Source{}, err
	}
	src.Scope = domain.ScopeID(scope)
	src.Kind = domain.SourceKind(kind)
	src.Connector = domain.SourceConnector(conn)
	src.Coverage = domain.CoverageState(coverage)
	var err error
	if src.LastAttemptAt, err = nullTime("sources.last_attempt_at", lastAttempt); err != nil {
		return domain.Source{}, err
	}
	if src.LastSuccessAt, err = nullTime("sources.last_success_at", lastSuccess); err != nil {
		return domain.Source{}, err
	}
	if src.CreatedAt, err = parseTime("sources.created_at", created); err != nil {
		return domain.Source{}, err
	}
	if src.UpdatedAt, err = parseTime("sources.updated_at", updated); err != nil {
		return domain.Source{}, err
	}
	return src, nil
}

// validateSourceCmd mirrors app.validateSourceCmd so direct Repo callers get
// identical precondition checks.
func validateSourceCmd(cmd app.SourceCmd) error {
	if !domain.ValidSourceID(cmd.ID) {
		return domain.Invalid("source id must match [a-z][a-z0-9_-]{1,63}")
	}
	if strings.TrimSpace(cmd.Name) == "" {
		return domain.Invalid("source name is required")
	}
	switch cmd.Kind {
	case domain.SourceKindCapture, domain.SourceKindCalendar:
	default:
		return domain.Invalid("unknown source kind %q", cmd.Kind)
	}
	switch cmd.Connector {
	case domain.SourceConnectorManual, domain.SourceConnectorDirectory, domain.SourceConnectorHostMCP:
	default:
		return domain.Invalid("unknown source connector %q", cmd.Connector)
	}
	if cmd.Scope == "" {
		return domain.Invalid("source scope is required")
	}
	if !cmd.Binding.Allows(cmd.Scope) {
		return domain.NewError(domain.ScopeDenied, "scope %s is outside the active scopes", cmd.Scope)
	}
	return nil
}

// validateSourceReviewCmd mirrors app.validateSourceReviewCmd. The store
// additionally accepts observed, which only a trusted host adapter may record
// through the service.
func validateSourceReviewCmd(cmd app.SourceReviewCmd) error {
	if !domain.ValidSourceID(cmd.SourceID) {
		return domain.Invalid("source id must match [a-z][a-z0-9_-]{1,63}")
	}
	if strings.TrimSpace(cmd.BatchID) == "" {
		return domain.Invalid("batch id is required")
	}
	if err := requireKey(cmd.Key); err != nil {
		return err
	}
	switch cmd.ResultKind {
	case "observed", "reported":
	default:
		return domain.Invalid("unknown result kind %q", cmd.ResultKind)
	}
	if len(cmd.Items) > domain.MaxSourceBatchItems {
		return domain.Invalid("source batch exceeds %d items", domain.MaxSourceBatchItems)
	}
	for i, item := range cmd.Items {
		if err := item.Validate(); err != nil {
			return domain.Invalid("source item %d: %v", i, err)
		}
	}
	return nil
}

// loadSourceScope fetches a source restricted to the binding scopes.
func loadSourceScope(ctx context.Context, q queryer, b domain.ScopeBinding, id string) (domain.Source, error) {
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.Source{}, err
	}
	args = append([]any{id}, args...)
	row := q.QueryRowContext(ctx,
		"SELECT "+sourceColumns+" FROM sources WHERE id = ? AND scope_id IN ("+clause+")", args...)
	src, err := scanSource(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Source{}, rowAccessError(ctx, q, "sources", "source", id)
	}
	if err != nil {
		return domain.Source{}, err
	}
	return src, nil
}

func sameSourceConfig(src domain.Source, cmd app.SourceCmd) bool {
	return src.Name == cmd.Name && src.Scope == cmd.Scope && src.Kind == cmd.Kind &&
		src.Connector == cmd.Connector && src.Provider == cmd.Provider &&
		src.ConnectionRef == cmd.ConnectionRef && src.NonSecretQuery == cmd.NonSecretQuery &&
		src.Cadence == cmd.Cadence
}

// AddSource registers one source under a bound scope.
//
// Pre: binding validates; id matches [a-z][a-z0-9_-]{1,63}; name, kind,
// connector and scope are set; the scope is in the binding and exists.
// Post: one transaction inserts the source and its history. Re-adding the
// same id with an identical configuration returns the existing row without
// writing; a different configuration is conflict. Nothing is written on
// failure.
func (s *Store) AddSource(ctx context.Context, cmd app.SourceCmd, now time.Time) (domain.Source, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Source{}, err
	}
	if err := validateSourceCmd(cmd); err != nil {
		return domain.Source{}, err
	}
	var out domain.Source
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		var one int
		err := tx.QueryRowContext(ctx, "SELECT 1 FROM scopes WHERE id = ?", string(cmd.Scope)).Scan(&one)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			return domain.Invalid("unknown scope reference %s", cmd.Scope)
		case err != nil:
			return err
		}
		existing, err := scanSource(tx.QueryRowContext(ctx,
			"SELECT "+sourceColumns+" FROM sources WHERE id = ?", cmd.ID))
		switch {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return err
		default:
			if sameSourceConfig(existing, cmd) {
				out = existing
				return nil
			}
			return domain.NewError(domain.Conflict,
				"source id %s is already registered; choose another id", cmd.ID)
		}
		out = domain.Source{
			ID: cmd.ID, Name: cmd.Name, Scope: cmd.Scope, Kind: cmd.Kind,
			Connector: cmd.Connector, Provider: cmd.Provider,
			ConnectionRef: cmd.ConnectionRef, NonSecretQuery: cmd.NonSecretQuery,
			Cadence: cmd.Cadence, AuthState: "unknown", Coverage: domain.CoverageUnknown,
			CreatedAt: now, UpdatedAt: now,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sources (id, name, scope_id, kind, connector, provider, connection_ref,
			   non_secret_query, cadence, auth_state, coverage_state, cursor,
			   last_attempt_at, last_success_at, created_at, updated_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'unknown', 'unknown', '', NULL, NULL, ?, ?)`,
			out.ID, out.Name, string(out.Scope), string(out.Kind), string(out.Connector),
			out.Provider, out.ConnectionRef, out.NonSecretQuery, out.Cadence,
			fmtTime(now), fmtTime(now)); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "source", out.ID, "created", string(out.Scope), "", 1, out, now); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return domain.Source{}, err
	}
	return out, nil
}

// ApplySources synchronizes a user-defined source configuration in one
// transaction.
//
// Pre: every command validates, ids are unique, and every scope is in the
// binding and exists. A source id already owned by another scope is conflict.
// Post: missing sources are inserted; existing sources with the same scope
// have only their configuration updated and keep coverage, cursor and auth
// state; identical entries are untouched. Any failure rolls back the batch.
func (s *Store) ApplySources(ctx context.Context, cmds []app.SourceCmd, now time.Time) ([]domain.Source, error) {
	now = now.UTC().Truncate(time.Second)
	if len(cmds) == 0 {
		return nil, domain.Invalid("source configuration is empty")
	}
	if len(cmds) > domain.MaxSourceConfigItems {
		return nil, domain.Invalid("source configuration exceeds %d entries", domain.MaxSourceConfigItems)
	}
	seen := make(map[string]bool, len(cmds))
	for _, cmd := range cmds {
		if err := cmd.Binding.Validate(); err != nil {
			return nil, err
		}
		if err := validateSourceCmd(cmd); err != nil {
			return nil, err
		}
		if seen[cmd.ID] {
			return nil, domain.Invalid("duplicate source id %s", cmd.ID)
		}
		seen[cmd.ID] = true
	}
	var out []domain.Source
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		out = make([]domain.Source, 0, len(cmds))
		for _, cmd := range cmds {
			var one int
			err := tx.QueryRowContext(ctx, "SELECT 1 FROM scopes WHERE id = ?", string(cmd.Scope)).Scan(&one)
			switch {
			case errors.Is(err, sql.ErrNoRows):
				return domain.Invalid("unknown scope reference %s", cmd.Scope)
			case err != nil:
				return err
			}
			existing, err := scanSource(tx.QueryRowContext(ctx,
				"SELECT "+sourceColumns+" FROM sources WHERE id = ?", cmd.ID))
			switch {
			case errors.Is(err, sql.ErrNoRows):
				src := domain.Source{
					ID: cmd.ID, Name: cmd.Name, Scope: cmd.Scope, Kind: cmd.Kind,
					Connector: cmd.Connector, Provider: cmd.Provider,
					ConnectionRef: cmd.ConnectionRef, NonSecretQuery: cmd.NonSecretQuery,
					Cadence: cmd.Cadence, AuthState: "unknown", Coverage: domain.CoverageUnknown,
					CreatedAt: now, UpdatedAt: now,
				}
				if _, err := tx.ExecContext(ctx,
					`INSERT INTO sources (id, name, scope_id, kind, connector, provider, connection_ref,
					   non_secret_query, cadence, auth_state, coverage_state, cursor,
					   last_attempt_at, last_success_at, created_at, updated_at)
					 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'unknown', 'unknown', '', NULL, NULL, ?, ?)`,
					src.ID, src.Name, string(src.Scope), string(src.Kind), string(src.Connector),
					src.Provider, src.ConnectionRef, src.NonSecretQuery, src.Cadence,
					fmtTime(now), fmtTime(now)); err != nil {
					return err
				}
				if err := insertHistory(ctx, tx, "source", src.ID, "created", string(src.Scope), "", 1, src, now); err != nil {
					return err
				}
				out = append(out, src)
			case err != nil:
				return err
			default:
				if existing.Scope != cmd.Scope {
					return domain.NewError(domain.Conflict,
						"source id %s is already registered; choose another id", cmd.ID)
				}
				if sameSourceConfig(existing, cmd) {
					out = append(out, existing)
					continue
				}
				if _, err := tx.ExecContext(ctx,
					`UPDATE sources SET name = ?, kind = ?, connector = ?, provider = ?,
					   connection_ref = ?, non_secret_query = ?, cadence = ?, updated_at = ?
					 WHERE id = ?`,
					cmd.Name, string(cmd.Kind), string(cmd.Connector), cmd.Provider,
					cmd.ConnectionRef, cmd.NonSecretQuery, cmd.Cadence, fmtTime(now), cmd.ID); err != nil {
					return err
				}
				existing.Name = cmd.Name
				existing.Kind = cmd.Kind
				existing.Connector = cmd.Connector
				existing.Provider = cmd.Provider
				existing.ConnectionRef = cmd.ConnectionRef
				existing.NonSecretQuery = cmd.NonSecretQuery
				existing.Cadence = cmd.Cadence
				existing.UpdatedAt = now
				if err := insertHistory(ctx, tx, "source", existing.ID, "updated", string(existing.Scope), "", 1, existing, now); err != nil {
					return err
				}
				out = append(out, existing)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// ListSources returns the sources of the binding scopes ordered by id, so the
// listing is deterministic across calls.
func (s *Store) ListSources(ctx context.Context, b domain.ScopeBinding) ([]domain.Source, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT "+sourceColumns+" FROM sources WHERE scope_id IN ("+clause+") ORDER BY id ASC", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Source
	for rows.Next() {
		src, err := scanSource(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, src)
	}
	return out, rows.Err()
}

// sourceReviewResult is the idempotent result of RecordSourceReview.
type sourceReviewResult struct {
	Review   domain.SourceReview `json:"review"`
	Captures []domain.Capture    `json:"captures"`
}

// sourceReviewCoverage derives the recorded coverage. Only an observed,
// complete, untruncated, failure-free batch is complete. Observed batches
// with gaps are partial, a batch with no items and failures failed, and any
// reported batch stays unverified or partial because only a trusted adapter
// can confirm what the provider returned.
func sourceReviewCoverage(cmd app.SourceReviewCmd) domain.CoverageState {
	switch {
	case len(cmd.Items) == 0 && len(cmd.Retrieval.Failures) > 0:
		return domain.CoverageFailed
	case cmd.ResultKind == "observed":
		if cmd.Retrieval.CompleteWindow && !cmd.Retrieval.Truncated && len(cmd.Retrieval.Failures) == 0 {
			return domain.CoverageComplete
		}
		return domain.CoveragePartial
	case len(cmd.Retrieval.Failures) > 0 || cmd.Retrieval.Truncated:
		return domain.CoveragePartial
	default:
		return domain.CoverageUnverified
	}
}

// uniqueReviewError translates the two source_reviews uniqueness guards into
// conflict errors with the offending identity.
func uniqueReviewError(err error, review domain.SourceReview) error {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "source_reviews.batch_id"):
		return domain.NewError(domain.Conflict,
			"batch %s was already recorded for source %s", review.BatchID, review.SourceID)
	case strings.Contains(msg, "source_reviews.idempotency_key"):
		return domain.NewError(domain.Conflict,
			"idempotency key was already recorded for source %s", review.SourceID)
	}
	return err
}

// RecordSourceReview stores one retrieval batch reported for a source.
//
// Pre: binding validates; source id, batch id and key are set; result kind is
// reported or observed; every item carries non-empty text and an external id
// with its revision or neither. The batch is bounded by len(cmd.Items), a
// finite validated count.
// Post: one transaction inserts the source review, one pending Capture per
// new item (an identical external triple is skipped, a new external revision
// is a new capture), the source coverage/attempt update, history for the
// review and every new capture, and the idempotency record. An identical
// retry replays the stored review and captures; the same key with a different
// payload is idempotency_conflict; any error rolls back every write. The
// cursor advances only for a complete, untruncated, failure-free observed
// batch, so a reported batch never moves it.
func (s *Store) RecordSourceReview(ctx context.Context, cmd app.SourceReviewCmd, now time.Time) (domain.SourceReview, []domain.Capture, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.SourceReview{}, nil, err
	}
	if err := validateSourceReviewCmd(cmd); err != nil {
		return domain.SourceReview{}, nil, err
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.SourceReview{}, nil, err
	}
	var res sourceReviewResult
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "source_review", cmd.Key, hash, &res)
		if err != nil || done {
			return err
		}
		src, err := loadSourceScope(ctx, tx, cmd.Binding, cmd.SourceID)
		if err != nil {
			return err
		}
		coverage := sourceReviewCoverage(cmd)
		cursor := src.Cursor
		if cmd.ResultKind == "observed" && cmd.Retrieval.CompleteWindow &&
			!cmd.Retrieval.Truncated && len(cmd.Retrieval.Failures) == 0 {
			cursor = cmd.Retrieval.Cursor
		}
		lastSuccess := src.LastSuccessAt
		if cmd.ResultKind == "observed" && len(cmd.Retrieval.Failures) == 0 {
			lastSuccess = &now
		}
		retrievalJSON, err := json.Marshal(cmd.Retrieval)
		if err != nil {
			return domain.Invalid("retrieval is not serializable: %v", err)
		}
		date := idDate(now)
		seq, err := nextDailySeq(ctx, tx, "source_reviews", "SR-"+date+"-")
		if err != nil {
			return err
		}
		review := domain.SourceReview{
			ID:         fmt.Sprintf("SR-%s-%03d", date, seq),
			SourceID:   src.ID,
			BatchID:    cmd.BatchID,
			ResultKind: cmd.ResultKind,
			Coverage:   coverage,
			Retrieval:  cmd.Retrieval,
			CreatedAt:  now,
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO source_reviews (id, source_id, batch_id, idempotency_key, request_hash,
			   result_kind, coverage_state, retrieval_json, created_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			review.ID, review.SourceID, review.BatchID, cmd.Key, hash,
			review.ResultKind, string(review.Coverage), string(retrievalJSON), fmtTime(now)); err != nil {
			return uniqueReviewError(err, review)
		}
		captures := make([]domain.Capture, 0, len(cmd.Items))
		for _, item := range cmd.Items {
			if item.ExternalID != "" {
				var existing string
				err := tx.QueryRowContext(ctx,
					`SELECT id FROM captures WHERE scope_id = ? AND source_id = ? AND external_id = ? AND external_revision = ?`,
					string(src.Scope), src.ID, item.ExternalID, item.ExternalRevision).Scan(&existing)
				switch {
				case err == nil:
					continue // identical external triple: same capture, skip
				case !errors.Is(err, sql.ErrNoRows):
					return err
				}
			}
			seq, err := nextDailySeq(ctx, tx, "captures", "C-"+date+"-")
			if err != nil {
				return err
			}
			var extID, extRev, uri *string
			if item.ExternalID != "" {
				eid, erev := item.ExternalID, item.ExternalRevision
				extID, extRev = &eid, &erev
			}
			if item.SourceURI != "" {
				u := item.SourceURI
				uri = &u
			}
			cap := domain.Capture{
				ID:               domain.CaptureID(fmt.Sprintf("C-%s-%03d", date, seq)),
				Scope:            src.Scope,
				SourceID:         src.ID,
				ExternalID:       extID,
				ExternalRevision: extRev,
				OriginalText:     item.OriginalText,
				ContentHash:      sha256hex(item.OriginalText),
				SourceURI:        uri,
				OccurredAt:       item.OccurredAt,
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
				argID(cap.SourceURI), argTime(cap.OccurredAt), fmtTime(cap.CapturedAt)); err != nil {
				return err
			}
			if err := insertHistory(ctx, tx, "capture", string(cap.ID), "captured",
				string(cap.Scope), "", 1, cap, now); err != nil {
				return err
			}
			captures = append(captures, cap)
			review.CaptureIDs = append(review.CaptureIDs, cap.ID)
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE sources SET coverage_state = ?, last_attempt_at = ?, last_success_at = ?,
			   cursor = ?, updated_at = ? WHERE id = ?`,
			string(coverage), fmtTime(now), argTime(lastSuccess), cursor, fmtTime(now), src.ID); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "source_review", review.ID, "recorded",
			string(src.Scope), "", 1, review, now); err != nil {
			return err
		}
		res = sourceReviewResult{Review: review, Captures: captures}
		return writeIdem(ctx, tx, "source_review", cmd.Key, hash, res, now)
	})
	if err != nil {
		return domain.SourceReview{}, nil, err
	}
	return res.Review, res.Captures, nil
}
