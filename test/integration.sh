#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/ztd"
[ -x "$BIN" ] || BIN="$ROOT/zig-out/bin/ztd.exe"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic root precedence: no ambient ZTD_ROOT.
unset ZTD_ROOT
# Native code needs a platform path for HOME (Git Bash reports POSIX paths).
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
    if command -v cygpath >/dev/null 2>&1; then HOME_BASE="$(cygpath -w "$TMP")"; else HOME_BASE="$TMP"; fi ;;
*) HOME_BASE="$TMP" ;;
esac

# An explicit path is the store directory itself: no `ztd` component is appended.
"$BIN" init "$TMP" >/dev/null
[ -f "$TMP/config.json" ]
[ ! -e "$TMP/ztd" ]
"$BIN" init --root "$TMP/alt" >/dev/null
"$BIN" --root "$TMP/alt" check >/dev/null
"$BIN" --root "$TMP" --today 2026-11-11 capture "First" "Second" >/dev/null
# Capture before grepping: `grep -q` closes the pipe early and races the
# writer's remaining chunks (BrokenPipe).
listing="$("$BIN" --root "$TMP" list --json)"
printf '%s' "$listing" | grep -q 'T-'
"$BIN" --root "$TMP" move T-20261111-001 next --field context:personal >/dev/null
shown="$("$BIN" --root "$TMP" show T-20261111-001)"
printf '%s' "$shown" | grep -q 'next'
"$BIN" --root "$TMP" check >/dev/null

# status: active root, source and format; it works without creating a store.
st="$("$BIN" --root "$TMP" status --json)"
printf '%s' "$st" | grep -q '"source":"flag"'
printf '%s' "$st" | grep -q '"exists":true'
printf '%s' "$st" | grep -q '"format":2'
human="$("$BIN" --root "$TMP" status)"
printf '%s' "$human" | grep -q '^source: flag$'
st="$(HOME="$HOME_BASE/statushome" ZTD_ROOT="$TMP" "$BIN" status --json)"
printf '%s' "$st" | grep -q '"source":"env"'
printf '%s' "$st" | grep -q '"exists":true'
st="$(HOME="$HOME_BASE/statushome" ZTD_ROOT="$TMP" "$BIN" --root "$TMP/alt" status --json)"
printf '%s' "$st" | grep -q '"source":"flag"'
printf '%s' "$st" | grep -q 'alt'
st="$(HOME="$HOME_BASE/statushome" "$BIN" status --json)"
printf '%s' "$st" | grep -q '"source":"home"'
printf '%s' "$st" | grep -q '"exists":false'
[ ! -e "$TMP/statushome" ]

# init: global by default, --local for the portable ./ztd, exact paths only.
HOME="$HOME_BASE/globalhome" "$BIN" init >/dev/null
st="$(HOME="$HOME_BASE/globalhome" "$BIN" status --json)"
printf '%s' "$st" | grep -q '"source":"home"'
printf '%s' "$st" | grep -q '"exists":true'
HOME="$HOME_BASE/globalhome" "$BIN" check >/dev/null
mkdir -p "$TMP/localdir"
(cd "$TMP/localdir" && "$BIN" init --local >/dev/null)
st="$(cd "$TMP/localdir" && "$BIN" --root ztd status --json)"
printf '%s' "$st" | grep -q '"exists":true'
printf '%s' "$st" | grep -q '"format":2'
rc=0; "$BIN" init --local "$TMP/conflict" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]
rc=0; "$BIN" --local check >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]

# A foreign format is refused before anything is created.
mkdir -p "$TMP/foreign"
printf '{"format":1}\n' >"$TMP/foreign/config.json"
rc=0; "$BIN" init "$TMP/foreign" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]
rc=0; "$BIN" --dry-run init "$TMP/foreign" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]
[ ! -e "$TMP/foreign/.state" ]
[ ! -e "$TMP/foreign/contexts.md" ]
[ ! -e "$TMP/foreign/inbox.md" ]

# No upward discovery: a store on the way up is ignored without --root.
mkdir -p "$TMP/box/sub"
"$BIN" init "$TMP/box/ztd" >/dev/null
rc=0
(cd "$TMP/box/sub" && HOME="$HOME_BASE/nohome" "$BIN" check >/dev/null 2>&1) || rc=$?
[ "$rc" -ne 0 ]
st="$(cd "$TMP/box/sub" && HOME="$HOME_BASE/nohome" "$BIN" status --json)"
printf '%s' "$st" | grep -q '"exists":false'

# Repository binding: status reports it, check --bindings validates it.
"$BIN" --root "$TMP" check >/dev/null
mkdir -p "$TMP/repo/nested" "$TMP/lists/projects/personal"
printf '# Binding demo\n' >"$TMP/lists/projects/personal/binding-demo.md"
(cd "$TMP/repo" && git init -q .)
st="$(cd "$TMP" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" status --json)"
printf '%s' "$st" | grep -q '"binding":null'
rc=0; (cd "$TMP/repo/nested" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" check --bindings >/dev/null 2>&1) || rc=$?
[ "$rc" -eq 1 ]
printf '{"context":"personal","client":null,"project":"personal/binding-demo"}\n' >"$TMP/repo/.ztd.json"
st="$(cd "$TMP/repo/nested" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" status --json)"
printf '%s' "$st" | grep -q '"project":"personal/binding-demo"'
printf '%s' "$st" | grep -q '"error":null'
(cd "$TMP/repo/nested" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" check --bindings >/dev/null)
printf '{"context":"personal","project":"personal/binding-demo"}\n' >"$TMP/repo/.ztd.json"
st="$(cd "$TMP/repo/nested" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" status --json)"
printf '%s' "$st" | grep -q '"value":null'
printf '%s' "$st" | grep -q '"error":"'
rc=0; (cd "$TMP/repo/nested" && HOME="$HOME_BASE/bindhome" "$BIN" --root "$TMP" check --bindings >/dev/null 2>&1) || rc=$?
[ "$rc" -eq 1 ]
printf '{"context":"personal","client":null,"project":"personal/binding-demo"}\n' >"$TMP/repo/.ztd.json"

# dry-run must not write
BEFORE="$(sha256sum "$TMP/inbox.md" 2>/dev/null || shasum -a 256 "$TMP/inbox.md")"
"$BIN" --root "$TMP" --dry-run move T-20261111-002 someday --field context:personal >/dev/null
AFTER="$(sha256sum "$TMP/inbox.md" 2>/dev/null || shasum -a 256 "$TMP/inbox.md")"
[ "$BEFORE" = "$AFTER" ]

# Routines: `due` follows the cadence and `routine done` stamps the run date.
for r in inbox plan review; do
  "$BIN" --root "$TMP" --today 2026-11-14 routine done "$r" >/dev/null
done
"$BIN" --root "$TMP" --today 2026-11-14 due | grep -q 'nothing due'
due15="$("$BIN" --root "$TMP" --today 2026-11-15 due)"
[[ "$due15" == *"inbox | daily | 1 day"* ]]
[[ "$due15" != *review* ]]
[[ "$("$BIN" --root "$TMP" --today 2026-11-21 due)" == *"review | weekly:sat | 7 days"* ]]
[[ "$("$BIN" --root "$TMP" --today 2026-11-15 due --json)" == *'"days":1'* ]]
"$BIN" --root "$TMP" --today 2026-11-15 --dry-run routine done inbox >/dev/null
[[ "$("$BIN" --root "$TMP" --today 2026-11-15 due)" == *inbox* ]]
if "$BIN" --root "$TMP" routine done nope >/dev/null 2>&1; then exit 1; fi

# Check fails closed: malformed lines, legacy reserved keys, strict warnings.
cp "$TMP/inbox.md" "$TMP.inbox.backup"
printf '%s\n' '- [ ] broken line' >>"$TMP/inbox.md"
rc=0; out="$("$BIN" --root "$TMP" check --json)" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out" | grep -q 'malformed task'
rc=0; "$BIN" --root "$TMP" list >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ]

cp "$TMP.inbox.backup" "$TMP/inbox.md"
printf '%s\n' '- [ ] T-20261111-090 | Legacy | context: personal | contexto: personal' >>"$TMP/inbox.md"
rc=0; out="$("$BIN" --root "$TMP" check --json)" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out" | grep -q 'legacy field contexto'

# Strict promotes warnings: captured_at must agree with the id date.
cp "$TMP.inbox.backup" "$TMP/inbox.md"
printf '%s\n' '- [ ] T-20261111-091 | Mismatch | captured_at: 2026-01-01' >>"$TMP/inbox.md"
"$BIN" --root "$TMP" check >/dev/null 2>&1
rc=0; "$BIN" --root "$TMP" check --strict >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ]

cp "$TMP.inbox.backup" "$TMP/inbox.md"
"$BIN" --root "$TMP" check >/dev/null

# Agent store flow: temp DB only, no Markdown workspace involved.
ADB="$TMP/agent.db"
out1="$("$BIN" agent-capture --scope demo --request 'hello' --objective 'finish the flow' --idempotency-key k1 --db "$ADB")"
id1="$(printf '%s' "$out1" | grep -o '"id":"A-[^"]*"' | cut -d'"' -f4)"
[ -n "$id1" ]

# Same key and identical payload replays the same assignment.
out2="$("$BIN" agent-capture --scope demo --request 'hello' --objective 'finish the flow' --idempotency-key k1 --db "$ADB")"
printf '%s' "$out2" | grep -q '"replayed":true'
id2="$(printf '%s' "$out2" | grep -o '"id":"A-[^"]*"' | cut -d'"' -f4)"
[ "$id1" = "$id2" ]

# Same key with a different payload is a conflict, exit 1.
rc=0
out3="$("$BIN" agent-capture --scope demo --request 'something else' --idempotency-key k1 --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out3" | grep -q '"code":"idempotency_conflict"'

# Checkpoint at rev 1, then a stale expect-rev conflicts.
out4="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 1 --result 'progress' --db "$ADB")"
printf '%s' "$out4" | grep -q '"assignment_rev":2'
rc=0
out5="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 1 --result 'more progress' --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out5" | grep -q '"code":"revision_conflict"'

# prepare returns the objective and the latest checkpoint.
out6="$("$BIN" agent-prepare "$id1" --scope demo --db "$ADB")"
printf '%s' "$out6" | grep -q '"objective":"finish the flow"'
printf '%s' "$out6" | grep -q '"latest":{"id":"C-'
# without --history the response keeps its original shape
if printf '%s' "$out6" | grep -q '"history"'; then
    echo "unexpected history field without --history" >&2
    exit 1
fi

# Another scope cannot read the assignment.
rc=0
out7="$("$BIN" agent-prepare "$id1" --scope other --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out7" | grep -q '"code":"scope_denied"'

# Durability: a second checkpoint, then export, restore and backup.
out8="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 2 --result 'second progress' --db "$ADB")"
printf '%s' "$out8" | grep -q '"assignment_rev":3'

EXPORT="$TMP/export.json"
"$BIN" agent-export --out "$EXPORT" --db "$ADB" >/dev/null
grep -q '"format":"ztd-agent-export"' "$EXPORT"
grep -q "$id1" "$EXPORT"
grep -q '"request_sha256":"' "$EXPORT"
# the export parses as JSON (skipped when python3 is unavailable; the strict
# restore below parses it too)
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$EXPORT"
fi

RESTORED="$TMP/restored.db"
"$BIN" agent-restore --from "$EXPORT" --db "$RESTORED" >/dev/null
# both checkpoints, newest-first
out9="$("$BIN" agent-prepare "$id1" --scope demo --db "$RESTORED" --history 2)"
hist="$(printf '%s' "$out9" | grep -o '"history":\[.*\]')"
n_hist="$(printf '%s' "$hist" | grep -o '"id":"C-' | wc -l | tr -d ' ')"
[ "$n_hist" -eq 2 ]
case "$hist" in
    *'"rev":3'*'"rev":2'*) ;;
    *) echo "history is not newest-first" >&2; exit 1 ;;
esac

# restoring again into the non-empty store fails and writes nothing
rc=0
out10="$("$BIN" agent-restore --from "$EXPORT" --db "$RESTORED" 2>&1)" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out10" | grep -q '"code":"invalid_argument"'

# a backup opens and answers prepare
"$BIN" agent-backup --out "$TMP/backup.db" --db "$ADB" >/dev/null
out11="$("$BIN" agent-prepare "$id1" --scope demo --db "$TMP/backup.db")"
printf '%s' "$out11" | grep -q '"rev":3'
# and never overwrites the existing file
rc=0
out12="$("$BIN" agent-backup --out "$TMP/backup.db" --db "$ADB" 2>&1)" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out12" | grep -q '"code":"invalid_argument"'
# a single quote in the backup path is doubled, not tripled
# (skipped under MSYS/MinGW: the emulated shell rewrites path arguments that contain quotes)
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) ;;
*)
    "$BIN" agent-backup --out "$TMP/it's.db" --db "$ADB" >/dev/null || { echo "quoted backup failed" >&2; exit 1; }
    "$BIN" agent-prepare "$id1" --scope demo --db "$TMP/it's.db" >/dev/null || { echo "quoted backup does not open" >&2; exit 1; }
    ;;
esac
# a malformed restore file is a domain error, not an io error
printf '%s' '{"format":"ztd-agent-export","version":1,"scopes":[]}' > "$TMP/broken.json"
rc=0
out13="$("$BIN" agent-restore --from "$TMP/broken.json" --db "$TMP/broken.db" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || { echo "malformed restore exited $rc: $out13" >&2; exit 1; }
printf '%s' "$out13" | grep -q '"code":"invalid_argument"' || { echo "malformed restore: $out13" >&2; exit 1; }

# Flags a command does not use are rejected, not silently discarded.
if "$BIN" agent-capture --scope demo --request probe --evidence now --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected capture --evidence to fail" >&2
    exit 1
fi
if "$BIN" agent-checkpoint A-19700101-001 --scope demo --expect-rev 1 --result r --constraints c --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected checkpoint --constraints to fail" >&2
    exit 1
fi
if "$BIN" agent-backup --scope demo --out "$TMP/other.db" --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected backup --scope to fail" >&2
    exit 1
fi
if "$BIN" agent-restore --scope demo --from "$TMP/export.json" --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected restore --scope to fail" >&2
    exit 1
fi
if "$BIN" agent-prepare A-19700101-001 --scope demo --out x --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected prepare --out to fail" >&2
    exit 1
fi
if "$BIN" agent-recall --scope demo --query build --limit 0 --db "$TMP/agent.db" >/dev/null 2>&1; then
    echo "expected recall --limit 0 to fail" >&2
    exit 1
fi

# Two processes opening a fresh database at once both succeed.
CONC="$TMP/conc.db"
race_pids=""
for n in 1 2; do
    (
        rc=0
        "$BIN" agent-capture --scope demo --request "race $n" --db "$CONC" >"$TMP/race$n.out" 2>&1 || rc=$?
        printf '%s' "$rc" >"$TMP/race$n.rc"
    ) &
    race_pids="$race_pids $!"
done
for p in $race_pids; do wait "$p" || true; done
for n in 1 2; do
    rc="$(cat "$TMP/race$n.rc")"
    if [ "$rc" -ne 0 ]; then
        echo "concurrent first open $n exited $rc: $(cat "$TMP/race$n.out")" >&2
        exit 1
    fi
done
"$BIN" agent-export --out "$TMP/race-export.json" --db "$CONC" >/dev/null
race_json="$(cat "$TMP/race-export.json")"
[ "$(printf '%s' "$race_json" | grep -o '"request":"race ' | wc -l | tr -d ' ')" -eq 2 ] || {
    echo "concurrent first open lost an assignment" >&2
    exit 1
}

# Of two checkpoints competing for the same revision, exactly one wins.
cid="$(printf '%s' "$race_json" | grep -o 'A-[0-9]\{8\}-[0-9]\{3\}' | head -1)"
win_pids=""
for n in 1 2; do
    (
        rc=0
        "$BIN" agent-checkpoint "$cid" --scope demo --expect-rev 1 --result "competing $n" --db "$CONC" >"$TMP/win$n.out" 2>&1 || rc=$?
        printf '%s' "$rc" >"$TMP/win$n.rc"
    ) &
    win_pids="$win_pids $!"
done
for p in $win_pids; do wait "$p" || true; done
wins=0
for n in 1 2; do
    rc="$(cat "$TMP/win$n.rc")"
    if [ "$rc" -eq 0 ]; then
        wins=$((wins + 1))
    else
        printf '%s' "$(cat "$TMP/win$n.out")" | grep -q '"code":"revision_conflict"'
    fi
done
[ "$wins" -eq 1 ] || { echo "competing checkpoints: $wins winners" >&2; exit 1; }
prepped="$("$BIN" agent-prepare "$cid" --scope demo --db "$CONC")"
printf '%s' "$prepped" | grep -q '"rev":2'

# Knowledge: remember two records in demo, recall ranks them, another scope sees none.
outk1="$("$BIN" agent-remember --scope demo --kind fact --text 'the build cache lives in zig-out' --db "$ADB")"
kid1="$(printf '%s' "$outk1" | grep -o '"id":"K-[^"]*"' | cut -d'"' -f4)"
[ -n "$kid1" ]
printf '%s' "$outk1" | grep -q '"rev":1'
outk2="$("$BIN" agent-remember --scope demo --kind decision --text 'build cache' --db "$ADB")"
kid2="$(printf '%s' "$outk2" | grep -o '"id":"K-[^"]*"' | cut -d'"' -f4)"
[ -n "$kid2" ]
[ "$kid1" != "$kid2" ]

# recall finds both, the newer (and better matching) record ranked first
outk3="$("$BIN" agent-recall --scope demo --query 'build cache' --db "$ADB")"
case "$outk3" in
    *"$kid2"*"$kid1"*) ;;
    *) echo "recall is not bm25-ranked newest first: $outk3" >&2; exit 1 ;;
esac
n_k="$(printf '%s' "$outk3" | grep -o '"id":"K-' | wc -l | tr -d ' ')"
[ "$n_k" -eq 2 ]

# another scope finds nothing
outk4="$("$BIN" agent-recall --scope other --query 'build cache' --db "$ADB")"
printf '%s' "$outk4" | grep -q '"knowledge":\[\]'

# an unknown kind is a domain error, not a usage error
rc=0
outk5="$("$BIN" agent-remember --scope demo --kind banana --text 'x' --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$outk5" | grep -q '"code":"invalid_argument"'

# export keeps knowledge; restoring into a fresh store answers recall
"$BIN" agent-export --out "$TMP/kexport.json" --db "$ADB" >/dev/null
grep -q '"version":2' "$TMP/kexport.json"
grep -q '"knowledge":\[' "$TMP/kexport.json"
grep -q "$kid1" "$TMP/kexport.json"
KREST="$TMP/krestored.db"
"$BIN" agent-restore --from "$TMP/kexport.json" --db "$KREST" >/dev/null
outk6="$("$BIN" agent-recall --scope demo --query 'build cache' --db "$KREST")"
n_kr="$(printf '%s' "$outk6" | grep -o '"id":"K-' | wc -l | tr -d ' ')"
[ "$n_kr" -eq 2 ]
printf '%s' "$outk6" | grep -q "$kid1"
printf '%s' "$outk6" | grep -q "$kid2"

# Version-1 upgrade: the binary only writes version 2, so build a v1 store by
# hand and open it through the CLI. The db.zig unit test always covers the
# migration; this exercises it end to end when python3 is available.
if command -v python3 >/dev/null 2>&1; then
    V1DB="$TMP/v1.db"
    python3 - "$V1DB" <<'PYEOF'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE scope (id TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE assignment (
  id TEXT PRIMARY KEY,
  scope_id TEXT NOT NULL REFERENCES scope(id),
  request TEXT NOT NULL,
  objective TEXT,
  constraints TEXT,
  project TEXT,
  status TEXT NOT NULL,
  rev INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX assignment_scope ON assignment(scope_id);
CREATE TABLE checkpoint (
  id TEXT PRIMARY KEY,
  assignment_id TEXT NOT NULL REFERENCES assignment(id),
  kind TEXT NOT NULL,
  result TEXT NOT NULL,
  evidence TEXT,
  next_action TEXT,
  rev INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX checkpoint_assignment ON checkpoint(assignment_id);
CREATE TABLE op_log (
  key TEXT PRIMARY KEY,
  request_sha256 BLOB NOT NULL,
  result_json TEXT NOT NULL,
  created_at TEXT NOT NULL
) WITHOUT ROWID;
INSERT INTO scope (id) VALUES ('demo');
INSERT INTO assignment (id, scope_id, request, status, rev, created_at, updated_at)
VALUES ('A-20260101-001', 'demo', 'legacy assignment', 'open', 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
PRAGMA user_version = 1;
""")
db.commit()
db.close()
PYEOF
    outv1="$("$BIN" agent-prepare A-20260101-001 --scope demo --db "$V1DB")"
    printf '%s' "$outv1" | grep -q '"request":"legacy assignment"'
    uv1="$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$V1DB")"
    [ "$uv1" = "2" ] || { echo "v1 upgrade ended at user_version $uv1" >&2; exit 1; }
else
    echo "note: version-1 upgrade exercised by the db.zig unit test only (no python3)" >&2
fi

# Format-1 conversion: copy-only, no destination on dry-run, source untouched.
V1="$TMP/v1"
mkdir -p "$V1/lists/projects/personal" "$V1/routines"
printf '# Inbox\n' >"$V1/inbox.md"
printf '# Next\n\n- [ ] T-20261111-001 | Legacy | contexto: personal | proyecto: personal/v1demo | capturada: 2026-11-11\n' >"$V1/lists/next.md"
printf '# Waiting\n' >"$V1/lists/waiting.md"
printf '# Someday\n' >"$V1/lists/someday.md"
printf '# Archive\n' >"$V1/lists/archive.md"
printf '# Projects\n' >"$V1/lists/projects/index.md"
printf '# Demo\n' >"$V1/lists/projects/personal/v1demo.md"
printf '# Contextos activos\n\n| Contexto | Uso |\n| --- | --- |\n| personal | Personal |\n' >"$V1/contexts.md"
printf '{"format":1,"policy":{"requireClientFor":[],"clientOnlyIn":[]}}\n' >"$V1/config.json"
printf '# Routines\n\n| rutina | cadencia | última |\n| --- | --- | --- |\n| review | semanal:sab | 2026-11-14 |\n' >"$V1/routines/state.md"
v1sum() { (cd "$TMP/v1" && find . -type f | sort | xargs shasum | shasum); }
V1BEFORE="$(v1sum)"
"$BIN" migrate --from "$TMP/v1" --to "$TMP/v2" --dry-run --today 2026-11-17 >/dev/null
[ ! -e "$TMP/v2" ]
"$BIN" migrate --from "$TMP/v1" --to "$TMP/v2" --today 2026-11-17 >/dev/null
grep -q '"format":2' "$TMP/v2/config.json"
grep -q 'context: personal' "$TMP/v2/lists/next.md"
grep -q 'captured_at: 2026-11-11' "$TMP/v2/lists/next.md"
grep -q '| routine | cadence |' "$TMP/v2/routines/state.md"
grep -q 'weekly:sat' "$TMP/v2/routines/state.md"
"$BIN" --root "$TMP/v2" check --strict >/dev/null
[ "$V1BEFORE" = "$(v1sum)" ]
rc=0; "$BIN" migrate --from "$TMP/v1" --to "$TMP/v2" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ]
rc=0; "$BIN" --root "$TMP" migrate --from "$TMP/v1" --to "$TMP/v3" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ]

# `install templates` adopts the templates init seeded and records a manifest.
TS="$TMP/tplstore"
"$BIN" init "$TS" >/dev/null
out="$("$BIN" --root "$TS" install templates --dry-run)"
printf '%s' "$out" | grep -q '6 unchanged'
[ ! -e "$TS/.ztd-assets.json" ]
out="$("$BIN" --root "$TS" install templates)"
printf '%s' "$out" | grep -q '6 unchanged'
[ -f "$TS/.ztd-assets.json" ]
j="$("$BIN" --root "$TS" install templates --json)"
printf '%s' "$j" | grep -q '"adapter":"templates"'
printf '%s' "$j" | grep -q '"unchanged":6'
# the manifest is not a store file that breaks check
"$BIN" --root "$TS" check >/dev/null
# a missing store is an error and nothing is created
rc=0; "$BIN" --root "$TMP/nostore" install templates >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]
[ ! -e "$TMP/nostore" ]

# Every command the binary dispatches must be visible in --help.
HELP="$("$BIN" --help 2>&1)"
for c in init status install migrate capture list show move plan check recover due routine version \
         agent-capture agent-checkpoint agent-prepare agent-remember agent-recall \
         agent-backup agent-export agent-restore; do
    printf '%s' "$HELP" | grep -q "  $c" || { echo "help omits $c" >&2; exit 1; }
done

echo "integration ok"
