package integration

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

type installReport struct {
	Installed int      `json:"installed"`
	Updated   int      `json:"updated"`
	Unchanged int      `json:"unchanged"`
	Conflicts []string `json:"conflicts"`
}

// countBundle counts the repository files below the given directories — the
// same set the binary embeds — so the expected install count tracks the
// bundle itself instead of a hardcoded number.
func countBundle(t *testing.T, rels ...string) int {
	t.Helper()
	n := 0
	for _, rel := range rels {
		err := filepath.WalkDir(filepath.Join(repoRoot(), rel), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() {
				n++
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walk %s: %v", rel, err)
		}
	}
	return n
}

// TestInstallOpenCodeDryRun points HOME at a throwaway directory and checks
// the classification without letting the command write anything.
func TestInstallOpenCodeDryRun(t *testing.T) {
	home := t.TempDir()
	db := filepath.Join(t.TempDir(), "ztd.db")

	r := runHome(t, home, db, "install", "opencode", "--dry-run")
	rep := decode[installReport](t, r.wantOK(t, "install"))

	want := countBundle(t,
		filepath.Join("integrations", "opencode", "skills"),
		filepath.Join("integrations", "opencode", "commands"))
	if rep.Installed != want || rep.Updated != 0 || rep.Unchanged != 0 || len(rep.Conflicts) != 0 {
		t.Fatalf("report = %+v, want %d installed", rep, want)
	}
	if _, err := os.Stat(filepath.Join(home, ".config")); !os.IsNotExist(err) {
		t.Fatalf("dry run created %s (err %v)", filepath.Join(home, ".config"), err)
	}
}

// TestInstallTemplates publishes the method templates into the directory of
// --db (a temp store root, never ~/.ztd) and keeps a rerun unchanged.
func TestInstallTemplates(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "ztd.db")
	want := countBundle(t, filepath.Join("method", "templates"))

	r := run(t, db, "install", "templates")
	rep := decode[installReport](t, r.wantOK(t, "install"))
	if rep.Installed != want || rep.Updated != 0 || rep.Unchanged != 0 {
		t.Fatalf("report = %+v, want %d installed", rep, want)
	}

	day, err := os.ReadFile(filepath.Join(dir, "templates", "day.md"))
	if err != nil {
		t.Fatalf("read template: %v", err)
	}
	if len(day) == 0 {
		t.Fatal("templates/day.md is empty")
	}

	raw, err := os.ReadFile(filepath.Join(dir, ".ztd-assets.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var m struct {
		Format int               `json:"format"`
		Assets map[string]string `json:"assets"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if m.Format != 1 || len(m.Assets) != want || m.Assets["templates/day.md"] == "" {
		t.Fatalf("manifest = format %d, %d assets, want format 1 and %d assets", m.Format, len(m.Assets), want)
	}

	r2 := run(t, db, "install", "templates")
	rep2 := decode[installReport](t, r2.wantOK(t, "install"))
	if rep2.Installed != 0 || rep2.Updated != 0 || rep2.Unchanged != want {
		t.Fatalf("rerun report = %+v, want %d unchanged", rep2, want)
	}
}

// TestInstallTemplatesMissingRoot refuses to create a store: the directory
// of --db must already exist, and the command must not make it.
func TestInstallTemplatesMissingRoot(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "missing")
	db := filepath.Join(dir, "ztd.db")

	r := run(t, db, "install", "templates")
	r.wantErr(t, 1, "install", "invalid_input")

	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("missing root was created (err %v)", err)
	}
}
