#!/usr/bin/env bash
# End-to-end tests for `ztd install opencode` and the templates `ztd init`
# seeds, run against the built binary in throwaway HOMEs. Never touches the
# real HOME, the developer workspace or the repository files.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/zig-out/bin/ztd"
[ -x "$BIN" ] || BIN="$ROOT/zig-out/bin/ztd.exe"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ztd-install-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

unset ZTD_ROOT
# Native code needs a platform path for HOME (Git Bash reports POSIX paths).
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then HOME_BASE="$(cygpath -w "$WORK")"; else HOME_BASE="$WORK"; fi ;;
*) HOME_BASE="$WORK" ;;
esac

fails=0
pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
expect_status() { # want got label
    if [ "$1" -eq "$2" ]; then pass "$3 (exit $2)"; else fail "$3 (want $1, got $2)"; fi
}
sha_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
sha_text() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

TARGET="commands/ztd.md"
SRC="$ROOT/integrations/opencode/$TARGET"
SHIPPED="$(sha_file "$SRC")"
OLDER=$'older release bytes\n'
OLDER_HEX="$(sha_text "$OLDER")"

# 1. Fresh install, idempotent rerun, stable manifest, JSON envelope.
h1="$WORK/h1"
mkdir -p "$h1"
rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" install opencode 2>&1)" || rc=$?
expect_status 0 "$rc" "fresh install"
case $out in
*"23 installed"*) pass "fresh install reports 23 installed" ;;
*) fail "fresh install reports 23 installed (got: $out)" ;;
esac
MANIFEST="$h1/.config/opencode/.ztd-assets.json"
if [ -f "$MANIFEST" ]; then pass "manifest written"; else fail "manifest written"; fi
cp "$MANIFEST" "$WORK/manifest.first"
if [ "$(find "$h1/.config/opencode" -type f ! -name '.ztd-assets.json' | wc -l | tr -d ' ')" = "23" ]; then
    pass "23 asset files published"
else
    fail "23 asset files published"
fi

rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" install opencode 2>&1)" || rc=$?
expect_status 0 "$rc" "second install"
case $out in
*"23 unchanged"*) pass "rerun reports 23 unchanged" ;;
*) fail "rerun reports 23 unchanged (got: $out)" ;;
esac
if cmp -s "$MANIFEST" "$WORK/manifest.first"; then pass "manifest byte-stable on rerun"; else fail "manifest byte-stable on rerun"; fi

rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" --json install opencode 2>&1)" || rc=$?
expect_status 0 "$rc" "json rerun"
case $out in
*'"ok":true'*'"installed":0'*'"updated":0'*'"unchanged":23'*'"version"'*)
    pass "json success envelope carries counts and version" ;;
*) fail "json success envelope carries counts and version (got: $out)" ;;
esac

# 2. Dry run reports and writes nothing.
h2="$WORK/h2"
mkdir -p "$h2"
rc=0; out="$(HOME="$HOME_BASE/h2" "$BIN" install opencode --dry-run 2>&1)" || rc=$?
expect_status 0 "$rc" "dry run"
case $out in
*"23 to install"*) pass "dry run reports 23 to install" ;;
*) fail "dry run reports 23 to install (got: $out)" ;;
esac
if [ ! -e "$h2/.config" ]; then pass "dry run writes nothing"; else fail "dry run writes nothing"; fi

# 3. Upgrade: an earlier release's bytes on disk, recorded in the manifest.
printf '%s' "$OLDER" > "$h1/.config/opencode/$TARGET"
sed "s/$SHIPPED/$OLDER_HEX/" "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" install opencode 2>&1)" || rc=$?
expect_status 0 "$rc" "upgrade run"
case $out in
*"1 updated"*"22 unchanged"*) pass "upgrade reports 1 updated, 22 unchanged" ;;
*) fail "upgrade reports 1 updated, 22 unchanged (got: $out)" ;;
esac
if cmp -s "$h1/.config/opencode/$TARGET" "$SRC"; then pass "upgraded bytes restored"; else fail "upgraded bytes restored"; fi
if grep -q "$SHIPPED" "$MANIFEST"; then pass "manifest records shipped bytes"; else fail "manifest records shipped bytes"; fi

# 4. A drifted manifest record is repaired without touching the file.
sed "s/$SHIPPED/$OLDER_HEX/" "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" install opencode 2>&1)" || rc=$?
expect_status 0 "$rc" "stale manifest run"
case $out in
*"23 unchanged"*) pass "file matching the bundle stays unchanged" ;;
*) fail "file matching the bundle stays unchanged (got: $out)" ;;
esac
if cmp -s "$h1/.config/opencode/$TARGET" "$SRC"; then pass "file untouched by manifest repair"; else fail "file untouched by manifest repair"; fi
if grep -q "$SHIPPED" "$MANIFEST"; then pass "drifted record repaired"; else fail "drifted record repaired"; fi

# 5. A user-edited file aborts with exit 1 and no writes at all.
printf 'user content\n' > "$h1/.config/opencode/commands/ztd/inbox.md"
rm "$h1/.config/opencode/skills/ztd/SKILL.md"
cp "$MANIFEST" "$WORK/manifest.before"
rc=0; out="$(HOME="$HOME_BASE/h1" "$BIN" install opencode 2>&1)" || rc=$?
expect_status 1 "$rc" "conflicting file aborts"
case $out in
*"conflict:"*) pass "conflict reported" ;;
*) fail "conflict reported (got: $out)" ;;
esac
case $out in
*"commands/ztd/inbox.md"*) pass "conflicting path listed" ;;
*) fail "conflicting path listed (got: $out)" ;;
esac
if [ ! -e "$h1/.config/opencode/skills/ztd/SKILL.md" ]; then
    pass "no writes after conflict"
else
    fail "no writes after conflict"
fi
if cmp -s "$MANIFEST" "$WORK/manifest.before"; then pass "manifest untouched by conflict"; else fail "manifest untouched by conflict"; fi
if [ "$(cat "$h1/.config/opencode/commands/ztd/inbox.md")" = "user content" ]; then
    pass "edited user file untouched"
else
    fail "edited user file untouched"
fi

# 6. `ztd init` seeds the six templates and keeps an edited one.
s="$WORK/store"
rc=0; HOME="$HOME_BASE/s" "$BIN" init "$s" >/dev/null 2>&1 || rc=$?
expect_status 0 "$rc" "init"
ok=1
for t in day week review journal knowledge project; do
    [ -f "$s/templates/$t.md" ] || ok=0
    cmp -s "$s/templates/$t.md" "$ROOT/method/templates/$t.md" || ok=0
done
if [ "$ok" -eq 1 ]; then pass "six templates seeded from method/templates"; else fail "six templates seeded from method/templates"; fi
printf 'my own plan\n' > "$s/templates/day.md"
rc=0; HOME="$HOME_BASE/s" "$BIN" init "$s" >/dev/null 2>&1 || rc=$?
expect_status 0 "$rc" "init rerun"
if [ "$(cat "$s/templates/day.md")" = "my own plan" ]; then
    pass "edited template never overwritten"
else
    fail "edited template never overwritten"
fi

# 7. Usage: a missing or unknown adapter exits 2.
rc=0; HOME="$HOME_BASE/u" "$BIN" install >/dev/null 2>&1 || rc=$?
expect_status 2 "$rc" "install without adapter"
rc=0; HOME="$HOME_BASE/u" "$BIN" install bogus >/dev/null 2>&1 || rc=$?
expect_status 2 "$rc" "unknown adapter"

# 8. A symlinked leaf aborts (skipped where symlinks cannot be created).
h3="$WORK/h3"
mkdir -p "$h3/.config/opencode/commands"
printf 'x\n' > "$WORK/link-target"
if ln -s "$WORK/link-target" "$h3/.config/opencode/commands/ztd.md" 2>/dev/null; then
    rc=0; out="$(HOME="$HOME_BASE/h3" "$BIN" install opencode 2>&1)" || rc=$?
    expect_status 1 "$rc" "symlink leaf aborts"
    case $out in
    *"conflict:"*symlink*) pass "symlink conflict listed" ;;
    *) fail "symlink conflict listed (got: $out)" ;;
    esac
    if [ ! -e "$h3/.config/opencode/skills" ]; then pass "no writes after symlink conflict"; else fail "no writes after symlink conflict"; fi
    if [ "$(cat "$WORK/link-target")" = "x" ]; then pass "symlink target untouched"; else fail "symlink target untouched"; fi
else
    echo "ok - symlink case skipped (no symlink support here)"
fi

if [ "$fails" -gt 0 ]; then
    echo "install-opencode: $fails failure(s)" >&2
    exit 1
fi
echo "install-opencode: all tests passed"
