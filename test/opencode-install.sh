#!/usr/bin/env bash
# Focused tests for integrations/opencode/install.sh.
# Every case runs with an isolated $HOME under a private temp directory and
# never touches the repository, the developer workspace or the real HOME.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
INSTALLER="$ROOT/integrations/opencode/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ztd-opencode-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

new_home() { mktemp -d "$WORK/home.XXXXXX"; }

installed_file() { echo "$1/.config/opencode/skills/ztd/SKILL.md"; }

# run_installer HOME CWD [SCRIPT]; echoes nothing, returns installer status.
run_installer() {
    local home=$1 cwd=$2 script=${3:-$INSTALLER}
    (cd "$cwd" && HOME="$home" "$script")
}

expect_status() { # want_status got_status label
    if [ "$1" -eq "$2" ]; then pass "$3 (exit $2)"; else fail "$3 (want $1, got $2)"; fi
}

# 1. Path with spaces: source tree and HOME both contain spaces.
t_spaces="$WORK/space dir"
mkdir -p "$t_spaces/unrelated"
cp -R "$ROOT/integrations/opencode" "$t_spaces/op en"
home_spaces="$t_spaces/home with spaces"
mkdir -p "$home_spaces"
rc=0; run_installer "$home_spaces" "$t_spaces/unrelated" "$t_spaces/op en/install.sh" || rc=$?
expect_status 0 "$rc" "install from a source path with spaces"
if cmp -s "$t_spaces/op en/skills/ztd/SKILL.md" "$(installed_file "$home_spaces")"; then
    pass "space-path install is byte-identical"
else
    fail "space-path install is byte-identical"
fi

# 2. Install from an unrelated cwd (assets resolved relative to the script).
home_cwd=$(new_home)
mkdir -p "$WORK/elsewhere"
rc=0; run_installer "$home_cwd" "$WORK/elsewhere" || rc=$?
expect_status 0 "$rc" "install from unrelated cwd"
if cmp -s "$ROOT/integrations/opencode/commands/ztd.md" \
        "$home_cwd/.config/opencode/commands/ztd.md"; then
    pass "unrelated-cwd install is byte-identical"
else
    fail "unrelated-cwd install is byte-identical"
fi

# 3. Idempotent rerun: second run is a no-op with no leftovers.
home_idem=$(new_home)
rc=0; run_installer "$home_idem" "$WORK" || rc=$?
expect_status 0 "$rc" "first install"
rc=0
out=$(run_installer "$home_idem" "$WORK" 2>&1) || rc=$?
expect_status 0 "$rc" "second install (idempotent rerun)"
case $out in
    *"ok - 0 installed, "*" unchanged"*) pass "rerun reports zero installs" ;;
    *) fail "rerun reports zero installs (got: $out)" ;;
esac
leftovers=$(find "$home_idem/.config/opencode" -name '.ztd-install.*' -print || true)
if [ -z "$leftovers" ]; then pass "no stage files left behind"; else fail "stage files left: $leftovers"; fi
if cmp -s "$ROOT/integrations/opencode/skills/ztd/SKILL.md" "$(installed_file "$home_idem")"; then
    pass "rerun keeps files byte-identical"
else
    fail "rerun keeps files byte-identical"
fi

# 4. Conflict preflight: a differing target aborts with zero partial writes.
home_conf=$(new_home)
mkdir -p "$home_conf/.config/opencode/commands"
printf 'user content\n' > "$home_conf/.config/opencode/commands/collect.md"
rc=0
err=$(run_installer "$home_conf" "$WORK" 2>&1) || rc=$?
expect_status 1 "$rc" "conflicting file aborts"
case $err in
    *"conflict:"*"aborting before any writes"*) pass "conflict reported before writes" ;;
    *) fail "conflict reported before writes (got: $err)" ;;
esac
if [ -e "$home_conf/.config/opencode/skills" ]; then
    fail "no partial writes after conflict"
else
    pass "no partial writes after conflict"
fi
if [ "$(cat "$home_conf/.config/opencode/commands/collect.md")" = "user content" ]; then
    pass "conflicting user file untouched"
else
    fail "conflicting user file untouched"
fi

# 5. Symlink conflicts: symlinked ancestor and symlinked leaf both abort.
home_anc=$(new_home)
mkdir -p "$home_anc/.config" "$WORK/elsewhere-ancestor"
ln -s "$WORK/elsewhere-ancestor" "$home_anc/.config/opencode"
rc=0; run_installer "$home_anc" "$WORK" >/dev/null 2>&1 || rc=$?
expect_status 1 "$rc" "symlink ancestor aborts"
if [ -z "$(ls -A "$WORK/elsewhere-ancestor")" ]; then
    pass "nothing written through symlinked ancestor"
else
    fail "nothing written through symlinked ancestor"
fi

home_leaf=$(new_home)
mkdir -p "$home_leaf/.config/opencode/commands"
printf 'target\n' > "$WORK/leaf-target"
ln -s "$WORK/leaf-target" "$home_leaf/.config/opencode/commands/collect.md"
rc=0; run_installer "$home_leaf" "$WORK" >/dev/null 2>&1 || rc=$?
expect_status 1 "$rc" "symlink leaf aborts"
if [ -L "$home_leaf/.config/opencode/commands/collect.md" ] &&
        [ "$(cat "$WORK/leaf-target")" = "target" ]; then
    pass "symlink leaf and its target untouched"
else
    fail "symlink leaf and its target untouched"
fi

# 6. Unrelated config, unrelated files and a fake store stay untouched.
home_keep=$(new_home)
mkdir -p "$home_keep/.config/opencode/commands" "$home_keep/.ztd"
printf '{"keep":true}\n' > "$home_keep/.config/opencode/opencode.json"
printf 'mine\n' > "$home_keep/.config/opencode/commands/my-notes.md"
printf 'store data\n' > "$home_keep/.ztd/inbox.md"
rc=0; run_installer "$home_keep" "$WORK" || rc=$?
expect_status 0 "$rc" "install alongside existing config and store"
ok_all=1
cmp -s "$home_keep/.config/opencode/opencode.json" <(printf '{"keep":true}\n') || ok_all=0
cmp -s "$home_keep/.config/opencode/commands/my-notes.md" <(printf 'mine\n') || ok_all=0
cmp -s "$home_keep/.ztd/inbox.md" <(printf 'store data\n') || ok_all=0
if [ "$ok_all" -eq 1 ]; then
    pass "config, unrelated files and store untouched"
else
    fail "config, unrelated files and store untouched"
fi
if [ -f "$home_keep/.config/opencode/commands/ztd.md" ]; then
    pass "installed files coexist with unrelated ones"
else
    fail "installed files coexist with unrelated ones"
fi

if [ "$fails" -gt 0 ]; then
    echo "opencode-install: $fails failure(s)" >&2
    exit 1
fi
echo "opencode-install: all tests passed"
