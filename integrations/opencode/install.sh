#!/usr/bin/env bash
# ztd OpenCode adapter installer.
#
# Installs the static skills/ and commands/ bundle that ships next to
# this script into $HOME/.config/opencode/{skills,commands}.
#
# - Assets are resolved relative to this script, never the caller's cwd.
# - It never initializes or modifies a ZTD store, never edits OpenCode
#   configuration, never configures MCP and never overwrites user files.
# - The whole bundle is preflighted before the first target write: a missing
#   leaf installs, a byte-identical existing regular file is a no-op, and any
#   differing file, symlink, special type or symlink ancestor below $HOME is a
#   conflict that aborts with no writes at all.
# - Each file is published from a stage inside the target directory through an
#   exclusive hard link (atomic, no-replace). A partial failure can leave
#   already-published files behind; those are byte-identical, so a rerun is
#   safe (preflight turns them into no-ops).
#
# Exit codes: 0 installed/unchanged; 1 conflict or publish abort; 2 usage or
# source-bundle error.
#
# Portability note: publishing relies on hard links in the target directory.
# If the filesystem cannot create them, this installer stops with exit 1
# instead of falling back to a clobbering rename — no-clobber is never weakened.
set -euo pipefail

me="install.sh"
usage() { echo "$me: $*" >&2; exit 2; }

# Absolute directory of this script, following symlinks (no readlink -f).
script_dir() {
    local src=$1 dir target
    while [ -L "$src" ]; do
        dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd -P)
        target=$(readlink "$src")
        case $target in
            /*) src=$target ;;
            *) src=$dir/$target ;;
        esac
    done
    CDPATH= cd -- "$(dirname -- "$src")" && pwd -P
}

[ -n "${HOME:-}" ] || usage "HOME is not set"
SCRIPT_DIR=$(script_dir "$0")
cd "$SCRIPT_DIR"

for bundle in skills commands; do
    [ -d "$SCRIPT_DIR/$bundle" ] || usage "missing source bundle: $SCRIPT_DIR/$bundle"
done

# Source integrity: only regular files, no symlinks or special types. A
# traversal error fails closed (exit 2) instead of being masked.
bad=$(find skills commands ! -type d ! -type f -print) || {
    echo "$me: source bundle traversal failed" >&2
    exit 2
}
[ -z "$bad" ] || usage "source bundle contains non-regular entries:
$bad"

list=$(find skills commands -type f -print) || {
    echo "$me: source bundle traversal failed" >&2
    exit 2
}
[ -n "$list" ] || usage "source bundle is empty"
files=()
while IFS= read -r rel; do
    files+=("$rel")
done < <(printf '%s\n' "$list" | LC_ALL=C sort)
[ "${#files[@]}" -gt 0 ] || usage "source bundle is empty"

TARGET_BASE="$HOME/.config/opencode"

# ---- Preflight: no target write happens before this loop finishes. ----
conflicts=()
noop=0
for rel in "${files[@]}"; do
    dst="$TARGET_BASE/$rel"
    case $dst in
        "$HOME"/*) ;;
        *) usage "target outside HOME: $dst" ;;
    esac

    # Ancestors below $HOME must be real directories (never symlinks).
    rest=${dst#"$HOME"/}
    acc=$HOME
    while [ "${rest%/*}" != "$rest" ]; do
        comp=${rest%%/*}
        rest=${rest#*/}
        acc="$acc/$comp"
        if [ -L "$acc" ]; then conflicts+=("symlink ancestor $acc"); fi
        if [ -e "$acc" ] && [ ! -d "$acc" ]; then conflicts+=("not a directory $acc"); fi
    done

    if [ -L "$dst" ]; then
        conflicts+=("symlink $dst")
    elif [ -e "$dst" ]; then
        if [ ! -f "$dst" ]; then
            conflicts+=("not a regular file $dst")
        elif ! cmp -s "$SCRIPT_DIR/$rel" "$dst"; then
            conflicts+=("differs $dst")
        else
            noop=$((noop + 1))
        fi
    fi
done

if [ "${#conflicts[@]}" -gt 0 ]; then
    for c in "${conflicts[@]}"; do
        echo "$me: conflict: $c" >&2
    done
    echo "$me: aborting before any writes (${#conflicts[@]} conflict(s))" >&2
    exit 1
fi

# ---- Publish: stage in the target directory, then exclusive hard link. ----
STAGE=""
trap 'if [ -n "${STAGE:-}" ]; then rm -f "$STAGE" || true; fi' EXIT

installed=0
unchanged=$noop
for rel in "${files[@]}"; do
    src="$SCRIPT_DIR/$rel"
    dst="$TARGET_BASE/$rel"

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        continue
    fi

    dir=${dst%/*}
    mkdir -p "$dir" || { echo "$me: cannot create directory $dir" >&2; exit 1; }
    if [ -L "$dir" ]; then
        echo "$me: conflict: symlinked directory $dir" >&2
        exit 1
    fi

    STAGE=$(mktemp "$dir/.ztd-install.XXXXXX") || {
        echo "$me: cannot stage in $dir" >&2; exit 1
    }
    if ! cp -p "$src" "$STAGE"; then
        echo "$me: copy failed for $rel" >&2
        exit 1
    fi

    if ln "$STAGE" "$dst" 2>/dev/null; then
        rm -f "$STAGE"
        STAGE=""
        installed=$((installed + 1))
        continue
    fi
    rm -f "$STAGE"
    STAGE=""

    # ln failed: either a racer published the leaf, or hard links are unusable.
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
            unchanged=$((unchanged + 1))
            continue
        fi
        echo "$me: conflict: $dst appeared during install and differs" >&2
        exit 1
    fi
    echo "$me: cannot publish $dst: hard link failed; no no-clobber fallback is attempted" >&2
    exit 1
done

echo "$me: ok - $installed installed, $unchanged unchanged"
