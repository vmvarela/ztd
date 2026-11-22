package main

// Dependency spike: WAL + FTS5 + VACUUM INTO under modernc.org/sqlite.
// Kept as executable evidence; not part of the product build.

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

func main() {
	dir, err := os.MkdirTemp("", "ztd-sqlite-spike-")
	must(err)
	defer os.RemoveAll(dir)
	dbPath := filepath.Join(dir, "spike.db")

	db, err := sql.Open("sqlite", dbPath+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=synchronous(FULL)")
	must(err)
	defer db.Close()

	_, err = db.Exec(`CREATE TABLE scope (id TEXT PRIMARY KEY);
CREATE VIRTUAL TABLE knowledge_fts USING fts5(text, source, id UNINDEXED, tokenize='unicode61 remove_diacritics 2');
INSERT INTO scope VALUES ('demo');
INSERT INTO knowledge_fts VALUES ('decisión sobre arquitectura', 'spec', 'K-1');`)
	must(err)

	var id string
	err = db.QueryRow(`SELECT id FROM knowledge_fts WHERE knowledge_fts MATCH 'decision'`).Scan(&id)
	if err == sql.ErrNoRows {
		err = db.QueryRow(`SELECT id FROM knowledge_fts WHERE knowledge_fts MATCH 'decisión'`).Scan(&id)
	}
	must(err)

	var mode string
	must(db.QueryRow(`PRAGMA journal_mode`).Scan(&mode))

	out := filepath.Join(dir, "snapshot.db")
	_, err = db.Exec(`VACUUM INTO '` + out + `'`)
	must(err)
	info, err := os.Stat(out)
	must(err)

	fmt.Printf("fts hit=%s journal=%s snapshot=%d bytes\n", id, mode, info.Size())
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
