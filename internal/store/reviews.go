package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"ztd/internal/app"
	"ztd/internal/domain"
)

// Reviews are documents. The old Review shape is only a compatibility response.
func (s *Store) RecordReview(ctx context.Context, cmd app.ReviewCmd, now time.Time) (domain.Review, error) {
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Review{}, err
	}
	if len(cmd.Binding.Scopes) != 1 {
		return domain.Review{}, domain.Invalid("select exactly one scope for a review")
	}
	if err := requireKey(cmd.Key); err != nil {
		return domain.Review{}, err
	}
	switch cmd.Kind {
	case "daily", "weekly", "monthly", "yearly":
	default:
		return domain.Review{}, domain.Invalid("unknown review kind")
	}
	if strings.TrimSpace(cmd.Period) == "" || strings.TrimSpace(cmd.Outcomes) == "" || strings.TrimSpace(cmd.Coverage) == "" {
		return domain.Review{}, domain.Invalid("period, outcomes and coverage are required")
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.Review{}, err
	}
	var out domain.Review
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "review", cmd.Key, hash, &out)
		if done || err != nil {
			return err
		}
		scope := cmd.Binding.Scopes[0]
		slug := "reviews/" + cmd.Kind + "/" + cmd.Period
		existing, err := scanDocument(tx.QueryRowContext(ctx, "SELECT "+documentColumns+" FROM documents WHERE scope_id = ? AND kind = 'review' AND slug = ?", scope, slug))
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		doc, err := putDocumentTx(ctx, tx, app.DocumentCmd{Binding: cmd.Binding, Kind: domain.DocumentReview, Slug: slug, Title: cmd.Kind + " review " + cmd.Period, Body: cmd.Outcomes + "\n\nCoverage: " + cmd.Coverage, Status: domain.DocumentVerified, Expected: existing.Revision}, now)
		if err != nil {
			return err
		}
		state := "partial"
		if cmd.Complete {
			state = "complete"
		}
		out = domain.Review{ID: domain.ReviewID(doc.ID), Profile: cmd.Binding.Profile, Kind: cmd.Kind, Period: cmd.Period, Outcomes: cmd.Outcomes, Coverage: cmd.Coverage, CompletionState: state, CreatedAt: doc.CreatedAt}
		raw, err := json.Marshal(map[string]any{"review": out})
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE documents SET metadata_json = ? WHERE id = ?", string(raw), doc.ID); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "review", cmd.Key, hash, out, now)
	})
	return out, err
}
func (s *Store) ReadReview(ctx context.Context, b domain.ScopeBinding, kind, period string) (domain.Document, error) {
	if len(b.Scopes) != 1 {
		return domain.Document{}, domain.Invalid("select exactly one scope for a review")
	}
	doc, err := s.GetDocument(ctx, b, domain.DocumentReview, "reviews/"+kind+"/"+period)
	if err == nil {
		return doc, nil
	}
	if err := b.Validate(); err != nil {
		return domain.Document{}, err
	}
	// Migrated reviews retain their original identity and content.
	legacy, legacyErr := scanDocument(s.db.QueryRowContext(ctx, "SELECT "+documentColumns+" FROM documents WHERE scope_id = ? AND kind = 'review' AND json_extract(metadata_json, '$.review.kind') = ? AND json_extract(metadata_json, '$.review.period') = ? ORDER BY updated_at DESC LIMIT 1", b.Scopes[0], kind, period))
	if legacyErr == nil {
		return legacy, nil
	}
	return domain.Document{}, err
}
