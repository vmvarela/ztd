package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"ztd/internal/app"
	"ztd/internal/domain"
)

const goalColumns = `id, profile_id, kind, start_on, end_on, statement, status`

func scanGoal(sc scanner) (domain.Goal, error) {
	var (
		g       domain.Goal
		endOn   sql.NullString
		profile string
	)
	if err := sc.Scan(&g.ID, &profile, &g.Kind, &g.StartOn, &endOn, &g.Statement, &g.Status); err != nil {
		return domain.Goal{}, err
	}
	g.Profile = domain.ProfileID(profile)
	if endOn.Valid {
		g.EndOn = endOn.String
	}
	return g, nil
}

func activeGoal(ctx context.Context, q queryer, profile domain.ProfileID) (*domain.Goal, error) {
	row := q.QueryRowContext(ctx,
		"SELECT "+goalColumns+" FROM goals WHERE profile_id = ? AND kind = 'primary' AND status = 'active'",
		string(profile))
	g, err := scanGoal(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &g, nil
}

// SetGoal records one Goal. A Profile may have at most one active primary
// Goal; the partial unique index enforces it and this check returns a clear
// conflict instead of a raw constraint error.
func (s *Store) SetGoal(ctx context.Context, cmd app.GoalCmd, now time.Time) (domain.Goal, error) {
	now = now.UTC().Truncate(time.Second)
	if err := cmd.Binding.Validate(); err != nil {
		return domain.Goal{}, err
	}
	hash, err := hashPayload(cmd)
	if err != nil {
		return domain.Goal{}, err
	}
	var out domain.Goal
	err = s.withTx(ctx, func(tx *sql.Tx) error {
		done, err := lookupIdem(ctx, tx, "goal", cmd.Key, hash, &out)
		if err != nil || done {
			return err
		}
		scopes, err := profileScopes(ctx, tx, cmd.Binding.Profile)
		if err != nil {
			return err
		}
		if len(scopes) == 0 {
			return domain.NewError(domain.NotFound, "profile %s does not exist", cmd.Binding.Profile)
		}
		if cmd.Kind == "primary" {
			existing, err := activeGoal(ctx, tx, cmd.Binding.Profile)
			if err != nil {
				return err
			}
			if existing != nil {
				return domain.NewError(domain.Conflict,
					"profile %s already has active primary goal %s", cmd.Binding.Profile, existing.ID)
			}
		}
		date := idDate(now)
		seq, err := nextDailySeq(ctx, tx, "goals", "G-"+date+"-")
		if err != nil {
			return err
		}
		out = domain.Goal{
			ID:        fmt.Sprintf("G-%s-%03d", date, seq),
			Profile:   cmd.Binding.Profile,
			Kind:      cmd.Kind,
			StartOn:   cmd.StartOn,
			EndOn:     cmd.EndOn,
			Statement: cmd.Statement,
			Status:    "active",
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO goals (id, profile_id, kind, start_on, end_on, statement, status, created_at, updated_at)
			 VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
			out.ID, string(out.Profile), out.Kind, out.StartOn, nullIfEmpty(out.EndOn), out.Statement,
			fmtTime(now), fmtTime(now)); err != nil {
			return err
		}
		if err := insertHistory(ctx, tx, "goal", out.ID, "created", "", string(out.Profile), 1, out, now); err != nil {
			return err
		}
		return writeIdem(ctx, tx, "goal", cmd.Key, hash, out, now)
	})
	return out, err
}

// ActiveGoal returns the Profile's active primary Goal, or nil.
func (s *Store) ActiveGoal(ctx context.Context, b domain.ScopeBinding) (*domain.Goal, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	return activeGoal(ctx, s.db, b.Profile)
}
