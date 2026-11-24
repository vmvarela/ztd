package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"ztd/internal/domain"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

const sqliteMagic = "SQLite format 3\x00"

type migration struct {
	version int
	name    string
	body    string
}

// Open creates or opens the SQLite database at path and applies every embedded
// migration not yet recorded in PRAGMA user_version, each in its own
// transaction. A nonempty file that is not SQLite, an SQLite file with tables
// but no ZTD version, or a user_version newer than the highest embedded
// migration is rejected with domain.DBIncompatible. ":memory:" is a normal,
// fully migrated database.
func Open(path string) (*Store, error) {
	if strings.TrimSpace(path) == "" {
		return nil, domain.Invalid("database path is required")
	}
	dsnPath := path
	if path != ":memory:" {
		abs, err := filepath.Abs(path)
		if err != nil {
			return nil, domain.NewError(domain.IOError, "resolve database path: %v", err)
		}
		dsnPath = abs
		if err := checkSQLiteHeader(abs); err != nil {
			return nil, err
		}
	}
	// _txlock=immediate makes every BeginTx a BEGIN IMMEDIATE; the _pragma list
	// runs on each pooled connection, so foreign_keys and synchronous are never
	// missing on a second connection. The same statements are re-asserted by
	// bootstrap below for the connection that runs the migrations.
	dsn := dsnPath + "?_txlock=immediate" +
		"&_pragma=foreign_keys(1)" +
		"&_pragma=journal_mode(WAL)" +
		"&_pragma=busy_timeout(5000)" +
		"&_pragma=synchronous(FULL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, openError(err)
	}
	if path == ":memory:" {
		// A second pooled connection would open a different, empty memory DB.
		db.SetMaxOpenConns(1)
	}
	s := &Store{db: db, path: dsnPath}
	if err := s.bootstrap(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) bootstrap(ctx context.Context) error {
	for _, pragma := range []string{
		"PRAGMA foreign_keys = ON",
		"PRAGMA journal_mode = WAL",
		"PRAGMA busy_timeout = 5000",
		"PRAGMA synchronous = FULL",
	} {
		if _, err := s.db.ExecContext(ctx, pragma); err != nil {
			return openError(err)
		}
	}
	migrations, err := loadMigrations()
	if err != nil {
		return err
	}
	var version int
	if err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return openError(err)
	}
	if highest := migrations[len(migrations)-1].version; version > highest {
		return domain.NewError(domain.DBIncompatible,
			"database schema version %d is newer than the highest supported version %d", version, highest)
	}
	if version == 0 {
		var tables int
		if err := s.db.QueryRowContext(ctx,
			"SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").Scan(&tables); err != nil {
			return openError(err)
		}
		if tables > 0 {
			return domain.NewError(domain.DBIncompatible,
				"existing SQLite file has tables but no ZTD schema version; refusing to initialize it")
		}
	}
	if version > 0 && version < migrations[len(migrations)-1].version && s.path != "" && s.path != ":memory:" {
		backup := fmt.Sprintf("%s.before-v%d-%d.db", s.path, migrations[len(migrations)-1].version, time.Now().UnixNano())
		if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", backup); err != nil {
			return domain.NewError(domain.IOError, "cannot snapshot before migration: %v", err)
		}
	}
	for _, m := range migrations {
		if m.version <= version {
			continue
		}
		if err := s.applyMigration(ctx, m); err != nil {
			return err
		}
	}
	return nil
}

// applyMigration runs one migration file and its user_version bump in a single
// transaction: user_version changes are transactional, so a failed migration
// leaves both the schema and the recorded version untouched.
func (s *Store) applyMigration(ctx context.Context, m migration) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return openError(err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, m.body); err != nil {
		return domain.NewError(domain.DBIncompatible, "migration %s failed: %v", m.name, err)
	}
	rows, err := tx.QueryContext(ctx, "PRAGMA foreign_key_check")
	if err != nil {
		return err
	}
	broken := rows.Next()
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if broken {
		return domain.NewError(domain.DBIncompatible, "migration %s left invalid references", m.name)
	}
	if _, err := tx.ExecContext(ctx, "PRAGMA user_version = "+strconv.Itoa(m.version)); err != nil {
		return domain.NewError(domain.DBIncompatible, "migration %s failed to record its version: %v", m.name, err)
	}
	if err := tx.Commit(); err != nil {
		return openError(err)
	}
	return nil
}

// checkSQLiteHeader rejects nonempty files that are not SQLite before the
// driver ever touches them; an absent or zero-byte file is a fresh database.
func checkSQLiteHeader(path string) error {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return domain.NewError(domain.IOError, "open database file: %v", err)
	}
	defer f.Close()
	var hdr [len(sqliteMagic)]byte
	n, err := io.ReadFull(f, hdr[:])
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return domain.NewError(domain.IOError, "read database header: %v", err)
	}
	if n == 0 {
		return nil
	}
	if string(hdr[:]) != sqliteMagic {
		return domain.NewError(domain.DBIncompatible, "%s is a nonempty file that is not a SQLite database", path)
	}
	return nil
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationFS, "migrations")
	if err != nil {
		return nil, domain.NewError(domain.DBIncompatible, "read embedded migrations: %v", err)
	}
	var ms []migration
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		v, err := strconv.Atoi(strings.SplitN(strings.TrimSuffix(e.Name(), ".sql"), "_", 2)[0])
		if err != nil {
			return nil, domain.Invalid("migration %s: filename must start with a numeric version", e.Name())
		}
		b, err := migrationFS.ReadFile("migrations/" + e.Name())
		if err != nil {
			return nil, domain.NewError(domain.IOError, "read migration %s: %v", e.Name(), err)
		}
		ms = append(ms, migration{version: v, name: e.Name(), body: string(b)})
	}
	if len(ms) == 0 {
		return nil, domain.NewError(domain.DBIncompatible, "no embedded migrations found")
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i].version < ms[j].version })
	for i := 1; i < len(ms); i++ {
		if ms[i].version == ms[i-1].version {
			return nil, domain.Invalid("duplicate embedded migration version %d", ms[i].version)
		}
	}
	return ms, nil
}

// openError classifies failures that happen while opening or migrating the
// database; content problems are DBIncompatible, contention DBBusy, filesystem
// problems IOError.
func openError(err error) error {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "busy"), strings.Contains(msg, "locked"):
		return domain.NewError(domain.DBBusy, "%v", err)
	case strings.Contains(msg, "readonly"), strings.Contains(msg, "unable to open"), strings.Contains(msg, "permission denied"):
		return domain.NewError(domain.IOError, "%v", err)
	default:
		return domain.NewError(domain.DBIncompatible, "%v", err)
	}
}
