package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
	"ztd/internal/domain"
)

func (s *Store) Settings(ctx context.Context) (domain.Settings, error) {
	var out domain.Settings
	err := s.db.QueryRowContext(ctx, "SELECT owner_actor_id,timezone FROM settings WHERE id=1").Scan(&out.Owner, &out.Timezone)
	if errors.Is(err, sql.ErrNoRows) {
		return out, domain.NewError(domain.NotFound, "run ztd init first")
	}
	return out, err
}
func (s *Store) SetTimezone(ctx context.Context, zone string) (domain.Settings, error) {
	if _, err := time.LoadLocation(zone); err != nil || zone == "" || zone == "Local" {
		return domain.Settings{}, domain.Invalid("timezone must be an IANA name, for example Europe/Madrid")
	}
	var out domain.Settings
	err := s.withTx(ctx, func(tx *sql.Tx) error {
		if err := tx.QueryRowContext(ctx, "SELECT owner_actor_id FROM settings WHERE id=1").Scan(&out.Owner); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, "UPDATE settings SET timezone=? WHERE id=1", zone); err != nil {
			return err
		}
		out.Timezone = zone
		return nil
	})
	return out, err
}
