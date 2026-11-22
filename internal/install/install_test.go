package install

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// testFiles is a small bundle: two nested leaves so the directory preflight
// and the ancestor re-check are both exercised.
var testFiles = map[string]string{
	"skills/ztd/SKILL.md":  "# ztd\n",
	"skills/ztd-do/DO.md":  "# do\n",
	"commands/ztd.md":      "/ztd\n",
	"commands/ztd/plan.md": "# plan\n",
	"templates/day.md":     "# day\n",
}

func testFS(files map[string]string) fstest.MapFS {
	m := make(fstest.MapFS, len(files))
	for p, body := range files {
		m[p] = &fstest.MapFile{Data: []byte(body)}
	}
	return m
}

func shaHex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func readManifestFile(t *testing.T, root string) manifest {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(root, ManifestName))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	return m
}

func mustRun(t *testing.T, fsys fstest.MapFS, cfg Config) Report {
	t.Helper()
	rep, err := Run(fsys, cfg)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(rep.Conflicts) != 0 {
		t.Fatalf("unexpected conflicts: %v", rep.Conflicts)
	}
	return rep
}

func TestFreshInstallWritesFilesAndManifest(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	rep := mustRun(t, testFS(testFiles), Config{Root: root, Version: "v1"})
	if rep.Installed != len(testFiles) || rep.Updated != 0 || rep.Unchanged != 0 {
		t.Fatalf("report = %+v, want %d installed", rep, len(testFiles))
	}
	for rel, body := range testFiles {
		got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		if string(got) != body {
			t.Fatalf("%s = %q, want %q", rel, got, body)
		}
	}
	m := readManifestFile(t, root)
	if m.Format != manifestFormat || m.ZTDVersion != "v1" || m.InstalledAt == "" {
		t.Fatalf("manifest header = %+v", m)
	}
	if len(m.Assets) != len(testFiles) {
		t.Fatalf("manifest assets = %d, want %d", len(m.Assets), len(testFiles))
	}
	for rel := range testFiles {
		if m.Assets[rel] == "" {
			t.Fatalf("manifest has no entry for %s", rel)
		}
	}
}

func TestRerunIsUnchangedWithStableManifest(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	fsys := testFS(testFiles)
	mustRun(t, fsys, Config{Root: root, Version: "v1"})
	before, err := os.ReadFile(filepath.Join(root, ManifestName))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	rep := mustRun(t, fsys, Config{Root: root, Version: "v1"})
	if rep.Installed != 0 || rep.Updated != 0 || rep.Unchanged != len(testFiles) {
		t.Fatalf("report = %+v, want all %d unchanged", rep, len(testFiles))
	}
	after, err := os.ReadFile(filepath.Join(root, ManifestName))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("manifest changed on rerun:\nbefore: %s\nafter:  %s", before, after)
	}
}

func TestEditedFileConflictsAndWritesNothing(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	fsys := testFS(testFiles)
	mustRun(t, fsys, Config{Root: root, Version: "v1"})

	edited := "skills/ztd/SKILL.md"
	removed := "skills/ztd-do/DO.md"
	if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(edited)), []byte("user content\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, filepath.FromSlash(removed))); err != nil {
		t.Fatal(err)
	}
	manifestBefore, err := os.ReadFile(filepath.Join(root, ManifestName))
	if err != nil {
		t.Fatal(err)
	}

	rep, err := Run(fsys, Config{Root: root, Version: "v1"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(rep.Conflicts) == 0 {
		t.Fatal("want conflicts, got none")
	}
	want := filepath.Join(root, filepath.FromSlash(edited))
	found := false
	for _, c := range rep.Conflicts {
		if strings.Contains(c, want) {
			found = true
		}
	}
	if !found {
		t.Fatalf("conflicts %v do not name %s", rep.Conflicts, want)
	}
	if rep.Installed != 0 || rep.Updated != 0 || rep.Unchanged != 0 {
		t.Fatalf("report = %+v, want zero counts", rep)
	}
	// Nothing was written: the edit stands and the removed file stays gone.
	got, err := os.ReadFile(want)
	if err != nil || string(got) != "user content\n" {
		t.Fatalf("edited file = %q (%v)", got, err)
	}
	if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(removed))); !os.IsNotExist(err) {
		t.Fatalf("removed file came back (err %v)", err)
	}
	manifestAfter, err := os.ReadFile(filepath.Join(root, ManifestName))
	if err != nil {
		t.Fatal(err)
	}
	if string(manifestBefore) != string(manifestAfter) {
		t.Fatal("manifest changed despite conflicts")
	}
}

func TestManifestDrivenUpdate(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	v1 := testFS(testFiles)
	mustRun(t, v1, Config{Root: root, Version: "v1"})

	// A later release ships new bytes for one leaf; the manifest records the
	// old ones, so the run upgrades instead of conflicting.
	rel := "skills/ztd/SKILL.md"
	next := map[string]string{}
	for p, body := range testFiles {
		next[p] = body
	}
	next[rel] = "# ztd v2\n"
	rep := mustRun(t, testFS(next), Config{Root: root, Version: "v1"})
	if rep.Updated != 1 || rep.Installed != 0 || rep.Unchanged != len(testFiles)-1 {
		t.Fatalf("report = %+v, want 1 updated", rep)
	}
	got, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != next[rel] {
		t.Fatalf("%s = %q, want %q", rel, got, next[rel])
	}
	m := readManifestFile(t, root)
	if m.Assets[rel] != shaHex(next[rel]) {
		t.Fatalf("manifest[%s] = %s, want %s", rel, m.Assets[rel], shaHex(next[rel]))
	}
}

func TestSymlinkTargetConflicts(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	fsys := testFS(testFiles)
	mustRun(t, fsys, Config{Root: root, Version: "v1"})

	rel := "skills/ztd/SKILL.md"
	target := filepath.Join(root, filepath.FromSlash(rel))
	elsewhere := filepath.Join(t.TempDir(), "elsewhere")
	if err := os.WriteFile(elsewhere, []byte("not ours\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, target); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	rep, err := Run(fsys, Config{Root: root, Version: "v1"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	want := filepath.Join(root, filepath.FromSlash(rel))
	found := false
	for _, c := range rep.Conflicts {
		if strings.Contains(c, "symlink") && strings.Contains(c, want) {
			found = true
		}
	}
	if !found {
		t.Fatalf("conflicts %v do not name the symlink %s", rep.Conflicts, want)
	}
	// The link target outside the tree is untouched.
	kept, err := os.ReadFile(elsewhere)
	if err != nil || string(kept) != "not ours\n" {
		t.Fatalf("link target = %q (%v)", kept, err)
	}
}

func TestDryRunWritesNothing(t *testing.T) {
	root := filepath.Join(t.TempDir(), "opencode")
	rep := mustRun(t, testFS(testFiles), Config{Root: root, Version: "v1", DryRun: true})
	if rep.Installed != len(testFiles) {
		t.Fatalf("report = %+v, want %d installed", rep, len(testFiles))
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatalf("dry run created %s (err %v)", root, err)
	}
}

func TestRequireRootMissingRootErrors(t *testing.T) {
	base := t.TempDir()
	missing := filepath.Join(base, "nostore")
	for _, dry := range []bool{false, true} {
		_, err := Run(testFS(testFiles), Config{Root: missing, RequireRoot: true, Version: "v1", DryRun: dry})
		if !errors.Is(err, ErrMissingRoot) {
			t.Fatalf("dry=%v: err = %v, want ErrMissingRoot", dry, err)
		}
		if _, err := os.Stat(missing); !os.IsNotExist(err) {
			t.Fatalf("dry=%v: missing root was created (err %v)", dry, err)
		}
	}

	// A file in place of the root is the same error and stays untouched.
	fileRoot := filepath.Join(base, "store-file")
	if err := os.WriteFile(fileRoot, []byte("not a store\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(testFS(testFiles), Config{Root: fileRoot, RequireRoot: true, Version: "v1"}); !errors.Is(err, ErrMissingRoot) {
		t.Fatalf("err = %v, want ErrMissingRoot", err)
	}
	kept, err := os.ReadFile(fileRoot)
	if err != nil || string(kept) != "not a store\n" {
		t.Fatalf("file root = %q (%v)", kept, err)
	}
}
