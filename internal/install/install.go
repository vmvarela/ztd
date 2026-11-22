// Package install publishes an embedded bundle under a no-clobber preflight,
// with a hidden manifest that turns later runs into upgrades instead of
// conflicts. The whole bundle is classified before the first write: any
// conflict aborts the run and nothing is written at all.
package install

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// ManifestName is the hidden manifest next to the installed assets: it
// records every managed path with the SHA-256 of the bytes the installer
// wrote, so a later run can tell an upgrade from a file the user edited.
// Only this package reads it; OpenCode ignores dotfiles in its config dir.
const ManifestName = ".ztd-assets.json"

const manifestFormat = 1

// maxAssetBytes caps a read: a file at or above this limit cannot match the
// embedded bytes, so it is reported as differing instead of being loaded.
const maxAssetBytes = 1 << 20

// ErrMissingRoot marks a store root that is absent or not a directory;
// `install templates` never creates a store.
var ErrMissingRoot = errors.New("store root missing or not a directory; run `ztd init` first")

// Config is one bundle publish. Prefix is where the bundle lives inside the
// source FS and Root is the install base holding the manifest.
type Config struct {
	Prefix      string
	Root        string
	RequireRoot bool
	Version     string
	DryRun      bool
}

// Report classifies every asset of the bundle. Conflicts is empty only when
// the run may proceed; when it is not, nothing was written.
type Report struct {
	Installed int      `json:"installed"`
	Updated   int      `json:"updated"`
	Unchanged int      `json:"unchanged"`
	Conflicts []string `json:"conflicts,omitempty"`
}

type manifest struct {
	Format      int               `json:"format"`
	ZTDVersion  string            `json:"ztd_version"`
	InstalledAt string            `json:"installed_at"`
	Assets      map[string]string `json:"assets"`
}

type action uint8

const (
	actInstall action = iota
	actUpdate
	actUnchanged
)

type asset struct {
	rel  string // path relative to the bundle root, slash-separated
	data []byte
}

// Run classifies the whole bundle against Root and, unless DryRun or a
// conflict stops it, writes the missing and upgraded assets plus the
// manifest. A file whose bytes differ from both the bundle and the recorded
// manifest is a conflict: it was edited or never belonged to this installer.
func Run(fsys fs.FS, cfg Config) (Report, error) {
	entries, err := bundle(fsys, cfg.Prefix)
	if err != nil {
		return Report{}, err
	}
	if len(entries) == 0 {
		return Report{}, fmt.Errorf("no assets embedded under %q", cfg.Prefix)
	}
	if cfg.RequireRoot {
		st, err := os.Lstat(cfg.Root)
		switch {
		case errors.Is(err, os.ErrNotExist):
			return Report{}, fmt.Errorf("%s: %w", cfg.Root, ErrMissingRoot)
		case err != nil:
			return Report{}, err
		case st.Mode()&os.ModeSymlink != 0, !st.IsDir():
			return Report{}, fmt.Errorf("%s: %w", cfg.Root, ErrMissingRoot)
		}
	}

	// Every directory this run creates or traverses must be a real directory
	// when it exists: a symlink or a file where a directory belongs is a
	// conflict. Missing components are fine — the publish phase creates them.
	dirs := []string{cfg.Root}
	if _, err := os.Stat(cfg.Root); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return Report{}, err
		}
		if parent := filepath.Dir(cfg.Root); parent != cfg.Root {
			dirs = append(dirs, parent)
		}
	}
	for _, a := range entries {
		dirs = append(dirs, ancestorDirs(cfg.Root, a.rel)...)
	}
	var conflicts []string
	for _, d := range dirs {
		if msg := checkDir(d); msg != "" {
			conflicts = append(conflicts, msg)
		}
	}

	// A malformed or unsupported manifest is treated as absent: differing
	// files then conflict instead of being silently adopted.
	manifestPath := filepath.Join(cfg.Root, ManifestName)
	old, msg, err := readManifest(manifestPath)
	if err != nil {
		return Report{}, err
	}
	if msg != "" {
		conflicts = append(conflicts, msg)
	}

	managed := make(map[string]bool, len(entries))
	actions := make([]action, len(entries))
	for i, a := range entries {
		managed[a.rel] = true
		want := sha256Hex(a.data)
		target := filepath.Join(cfg.Root, filepath.FromSlash(a.rel))
		st, err := os.Lstat(target)
		switch {
		case errors.Is(err, os.ErrNotExist):
			actions[i] = actInstall
			continue
		case err != nil:
			return Report{}, err
		case st.Mode()&os.ModeSymlink != 0:
			conflicts = append(conflicts, fmt.Sprintf("symlink %s", target))
			continue
		case !st.Mode().IsRegular():
			conflicts = append(conflicts, fmt.Sprintf("not a regular file %s", target))
			continue
		case st.Size() > maxAssetBytes:
			conflicts = append(conflicts, fmt.Sprintf("differs %s", target))
			continue
		}
		disk, err := os.ReadFile(target)
		if err != nil {
			return Report{}, err
		}
		got := sha256Hex(disk)
		switch {
		case got == want:
			actions[i] = actUnchanged // already the shipped bytes
		case old.Assets[a.rel] == got:
			actions[i] = actUpdate // the bytes of an earlier release
		default:
			conflicts = append(conflicts, fmt.Sprintf("differs %s", target))
		}
	}
	if len(conflicts) > 0 {
		return Report{Conflicts: conflicts}, nil
	}

	installed, updated, unchanged := 0, 0, 0
	for _, a := range actions {
		switch a {
		case actInstall:
			installed++
		case actUpdate:
			updated++
		case actUnchanged:
			unchanged++
		}
	}
	if cfg.DryRun {
		return Report{Installed: installed, Updated: updated, Unchanged: unchanged}, nil
	}

	// The manifest is rewritten only when the recorded bytes or the version
	// change, so a rerun from the same binary keeps it byte-identical.
	next := make(map[string]string, len(old.Assets)+len(entries))
	for p, sha := range old.Assets {
		// Entries a future release dropped stay recorded: their files are
		// outside the bundle now, but remain managed instead of foreign.
		if !managed[p] {
			next[p] = sha
		}
	}
	for _, a := range entries {
		next[a.rel] = sha256Hex(a.data)
	}
	var text []byte
	if old.ZTDVersion != cfg.Version || !sameShas(old.Assets, next) {
		if text, err = renderManifest(cfg.Version, next); err != nil {
			return Report{}, err
		}
	}

	if err := os.MkdirAll(cfg.Root, 0o755); err != nil {
		return Report{}, err
	}
	for _, a := range entries {
		if d := path.Dir(a.rel); d != "." {
			if err := os.MkdirAll(filepath.Join(cfg.Root, filepath.FromSlash(d)), 0o755); err != nil {
				return Report{}, err
			}
		}
	}
	// Preflight saw the layout before any directory existed, so a symlink
	// planted in between must not be written through either. Only empty
	// directories can exist after such an abort.
	var recheck []string
	for _, d := range dirs {
		if msg := checkDir(d); msg != "" {
			recheck = append(recheck, msg)
		}
	}
	if len(recheck) > 0 {
		return Report{Conflicts: recheck}, nil
	}

	for i, a := range entries {
		if actions[i] == actUnchanged {
			continue
		}
		target := filepath.Join(cfg.Root, filepath.FromSlash(a.rel))
		var werr error
		if actions[i] == actInstall {
			// Exclusive publication: a racer that filled the leaf aborts
			// instead of clobbering it; a rerun turns it into a no-op.
			werr = createExclusive(target, a.data)
		} else {
			werr = replaceFile(target, a.data)
		}
		if werr != nil {
			return Report{}, werr
		}
	}
	if text != nil {
		if err := replaceFile(manifestPath, text); err != nil {
			return Report{}, err
		}
	}
	return Report{Installed: installed, Updated: updated, Unchanged: unchanged}, nil
}

// bundle lists the regular files under prefix with paths relative to prefix.
func bundle(fsys fs.FS, prefix string) ([]asset, error) {
	root := "."
	if prefix != "" {
		root = prefix
	}
	var out []asset
	err := fs.WalkDir(fsys, root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !d.Type().IsRegular() {
			return nil
		}
		data, err := fs.ReadFile(fsys, p)
		if err != nil {
			return err
		}
		rel := p
		if prefix != "" {
			rel = strings.TrimPrefix(strings.TrimPrefix(p, prefix), "/")
		}
		out = append(out, asset{rel: rel, data: data})
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// ancestorDirs are the directories under base that hold rel, outermost first.
func ancestorDirs(base, rel string) []string {
	dir := path.Dir(rel)
	if dir == "." {
		return nil
	}
	var out []string
	acc := ""
	for _, comp := range strings.Split(dir, "/") {
		if acc == "" {
			acc = comp
		} else {
			acc += "/" + comp
		}
		out = append(out, filepath.Join(base, filepath.FromSlash(acc)))
	}
	return out
}

// checkDir returns a conflict message unless path is absent or a real
// directory; absent is fine because the publish phase creates it.
func checkDir(path string) string {
	st, err := os.Lstat(path)
	if err != nil {
		return "" // absent: the publish phase creates it
	}
	switch {
	case st.Mode()&os.ModeSymlink != 0:
		return fmt.Sprintf("symlink ancestor %s", path)
	case !st.IsDir():
		return fmt.Sprintf("not a directory %s", path)
	}
	return ""
}

// readManifest loads the previous manifest. It returns a conflict message
// when the manifest exists but is not a regular file; a missing, oversized
// or malformed manifest is treated as absent.
func readManifest(path string) (manifest, string, error) {
	empty := manifest{Format: manifestFormat, Assets: map[string]string{}}
	st, err := os.Lstat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return empty, "", nil
	case err != nil:
		return empty, "", err
	case !st.Mode().IsRegular():
		return empty, fmt.Sprintf("not a regular file %s", path), nil
	case st.Size() > maxAssetBytes:
		return empty, "", nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return empty, "", err
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil || m.Format != manifestFormat {
		return empty, "", nil
	}
	if m.Assets == nil {
		m.Assets = map[string]string{}
	}
	return m, "", nil
}

func sameShas(old, next map[string]string) bool {
	if len(old) != len(next) {
		return false
	}
	for p, sha := range next {
		if old[p] != sha {
			return false
		}
	}
	return true
}

func renderManifest(version string, assets map[string]string) ([]byte, error) {
	m := manifest{
		Format:      manifestFormat,
		ZTDVersion:  version,
		InstalledAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		Assets:      assets,
	}
	b, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

func createExclusive(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// replaceFile writes through a temporary file in the same directory, so a
// crash never leaves a truncated asset behind.
func replaceFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".ztd-tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
