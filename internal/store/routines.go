package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"ztd/internal/domain"
)

var weekdays = map[string]time.Weekday{
	"sun": time.Sunday, "mon": time.Monday, "tue": time.Tuesday,
	"wed": time.Wednesday, "thu": time.Thursday, "fri": time.Friday,
	"sat": time.Saturday,
}

func scanRoutine(sc scanner) (domain.Routine, error) {
	var (
		r      domain.Routine
		last   sql.NullString
		active int
	)
	if err := sc.Scan(&r.ID, &r.Scope, &r.Kind, &r.Cadence, &last, &active, &r.Revision); err != nil {
		return domain.Routine{}, err
	}
	r.Active = active == 1
	var err error
	if r.LastCompletedAt, err = nullTime("routines.last_completed_at", last); err != nil {
		return domain.Routine{}, err
	}
	return r, nil
}

// routineDue computes the next occurrence after last and compares it with the
// requested local date. The weekly scan is bounded to seven days.
func routineDue(cadence string, last *time.Time, date time.Time) (bool, error) {
	cadence = strings.TrimSpace(cadence)
	if cadence == "daily" {
		if last == nil {
			return true, nil
		}
		return date.After(*last), nil
	}
	if !strings.HasPrefix(cadence, "weekly:") {
		return false, domain.Invalid("unknown routine cadence %q", cadence)
	}
	day, ok := weekdays[strings.TrimPrefix(cadence, "weekly:")]
	if !ok {
		return false, domain.Invalid("unknown routine weekday in %q", cadence)
	}
	if last == nil {
		return true, nil
	}
	next := last.AddDate(0, 0, 1)
	for i := 0; i < 7; i++ {
		if next.Weekday() == day {
			return !date.Before(next), nil
		}
		next = next.AddDate(0, 0, 1)
	}
	return false, domain.NewError(domain.IOError, "could not resolve weekly cadence %q", cadence)
}

// DueRoutines lists active routines in the binding scopes due on the local date.
func (s *Store) DueRoutines(ctx context.Context, b domain.ScopeBinding, date string) ([]domain.Routine, error) {
	if err := b.Validate(); err != nil {
		return nil, err
	}
	day, err := time.Parse("2006-01-02", date)
	if err != nil {
		return nil, domain.Invalid("date must be YYYY-MM-DD")
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT id, scope_id, kind, cadence, last_completed_at, active, revision FROM routines WHERE scope_id IN ("+clause+") AND active = 1 ORDER BY id", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Routine
	for rows.Next() {
		r, err := scanRoutine(rows)
		if err != nil {
			return nil, err
		}
		due, err := routineDue(r.Cadence, r.LastCompletedAt, day)
		if err != nil {
			return nil, err
		}
		if due {
			out = append(out, r)
		}
	}
	return out, rows.Err()
}

// CompleteRoutine records one run on the local date.
func (s *Store) CompleteRoutine(ctx context.Context, b domain.ScopeBinding, id domain.RoutineID, date string) (domain.Routine, error) {
	if err := b.Validate(); err != nil {
		return domain.Routine{}, err
	}
	day, err := time.Parse("2006-01-02", date)
	if err != nil {
		return domain.Routine{}, domain.Invalid("date must be YYYY-MM-DD")
	}
	clause, args, err := scopeClause(b)
	if err != nil {
		return domain.Routine{}, err
	}
	args = append([]any{string(id)}, args...)
	row := s.db.QueryRowContext(ctx,
		"SELECT id, scope_id, kind, cadence, last_completed_at, active, revision FROM routines WHERE id = ? AND scope_id IN ("+clause+")", args...)
	r, err := scanRoutine(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Routine{}, rowAccessError(ctx, s.db, "routines", "routine", string(id))
	}
	if err != nil {
		return domain.Routine{}, err
	}
	if !r.Active {
		return domain.Routine{}, domain.NewError(domain.InvalidTransition, "routine %s is inactive", id)
	}
	if _, err := s.db.ExecContext(ctx,
		"UPDATE routines SET last_completed_at = ?, revision = ? WHERE id = ?",
		fmtTime(day), int64(r.Revision+1), string(id)); err != nil {
		return domain.Routine{}, busyOrRaw(err)
	}
	r.LastCompletedAt = &day
	r.Revision++
	return r, nil
}
