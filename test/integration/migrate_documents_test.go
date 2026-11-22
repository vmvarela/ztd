package integration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type documentsReport struct {
	Inserted  int      `json:"inserted"`
	Updated   int      `json:"updated"`
	Unchanged int      `json:"unchanged"`
	Skipped   int      `json:"skipped"`
	Warnings  []string `json:"warnings,omitempty"`
}

// docFixture writes a small legacy copy: two classified documents, one
// project card with a Repositories table, one unknown path, and the store
// bookkeeping files that must never be imported.
func docFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"knowledge/opensource/setup.md": "# Setup\n\nClone lives under repos/.\n",
		"calendar.md":                   "# Calendar\n",
		"stray.md":                      "no place to go\n",
		"README.md":                     "# legacy copy\n",
		"lists/next.md":                 "",
		"contexts.md":                   "| Context |\n| --- |\n| familia |\n",
		"lists/projects/opensource/ztd.md": "# ZTD\n\n## Repositories\n\n" +
			"| Name | Remote | Local path | Status |\n| --- | --- | --- | --- |\n" +
			"| ztd | https://example.com/ztd.git | repos/opensource/ztd | active |\n",
	}
	for rel, content := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// TestMigrateDocuments drives `migrate documents` end to end: the missing
// source precondition, a dry run that writes nothing, the import with its
// warnings and repository extraction, an idempotent re-run and a green check.
func TestMigrateDocuments(t *testing.T) {
	db := filepath.Join(t.TempDir(), "ztd.db")
	initDB(t, db)
	src := docFixture(t)
	workspace := t.TempDir()

	// The project row the card contributes repository fields to.
	run(t, db, "project", "add", "opensource/ztd", "--scope", "opensource").
		wantOK(t, "project add")

	run(t, db, "migrate", "documents").wantErr(t, 1, "migrate", "invalid_input")

	// Dry run: the same plan, no writes.
	dry := decode[documentsReport](t, run(t, db, "migrate", "documents",
		"--source", src, "--workspace", workspace, "--dry-run").wantOK(t, "migrate documents"))
	if dry.Inserted != 3 || dry.Updated != 0 || dry.Unchanged != 0 || dry.Skipped != 1 {
		t.Fatalf("dry-run report = %+v, want inserted=3 skipped=1", dry)
	}
	if len(dry.Warnings) != 1 || !strings.Contains(dry.Warnings[0], "stray.md") {
		t.Fatalf("dry-run warnings = %v, want the stray.md warning", dry.Warnings)
	}
	if docs := decode[[]documentData](t, run(t, db, "doc", "list").wantOK(t, "doc list")); len(docs) != 0 {
		t.Fatalf("documents after dry-run = %+v, want none", docs)
	}

	// The real import.
	got := decode[documentsReport](t, run(t, db, "migrate", "documents",
		"--source", src, "--workspace", workspace).wantOK(t, "migrate documents"))
	if got.Inserted != 3 || got.Updated != 0 || got.Unchanged != 0 || got.Skipped != 1 {
		t.Fatalf("report = %+v, want inserted=3 skipped=1", got)
	}
	if len(got.Warnings) != 1 || !strings.Contains(got.Warnings[0], "stray.md") {
		t.Fatalf("warnings = %v, want the stray.md warning", got.Warnings)
	}

	docs := decode[[]documentData](t, run(t, db, "doc", "list").wantOK(t, "doc list"))
	if len(docs) != 3 {
		t.Fatalf("doc list = %d documents, want 3", len(docs))
	}
	for _, d := range docs {
		if d.Status != "verified" {
			t.Errorf("%s/%s status = %q, want verified", d.Kind, d.Slug, d.Status)
		}
	}

	// Repository extraction: absolute URL, relative clone path against the
	// workspace.
	proj := decode[projectData](t, run(t, db, "project", "show", "opensource/ztd").wantOK(t, "project show"))
	if proj.RepoURL != "https://example.com/ztd.git" {
		t.Errorf("repo_url = %q", proj.RepoURL)
	}
	if want := filepath.Join(workspace, "repos/opensource/ztd"); proj.ClonePath != want {
		t.Errorf("clone_path = %q, want %q", proj.ClonePath, want)
	}

	// Re-running the same copy changes nothing.
	again := decode[documentsReport](t, run(t, db, "migrate", "documents",
		"--source", src, "--workspace", workspace).wantOK(t, "migrate documents"))
	if again.Inserted != 0 || again.Updated != 0 || again.Unchanged != 3 || again.Skipped != 1 {
		t.Fatalf("re-run report = %+v, want 3 unchanged", again)
	}
	if docs := decode[[]documentData](t, run(t, db, "doc", "list").wantOK(t, "doc list")); len(docs) != 3 {
		t.Fatalf("documents after re-run = %d, want 3 (no duplicates)", len(docs))
	}

	chk := decode[checkData](t, run(t, db, "check").wantOK(t, "check"))
	if !chk.OK {
		t.Fatalf("check errors: %v", chk.Errors)
	}
}
