#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/ztd"
[ -x "$BIN" ] || BIN="$ROOT/zig-out/bin/ztd.exe"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$BIN" init "$TMP" >/dev/null
"$BIN" init --root "$TMP/alt" >/dev/null
"$BIN" --root "$TMP/alt" check >/dev/null
"$BIN" --root "$TMP" --today 2026-11-11 capture "Primera" "Segunda" >/dev/null
"$BIN" --root "$TMP" list --json | grep -q 'T-'
"$BIN" --root "$TMP" move T-20261111-001 next --field contexto:personal >/dev/null
"$BIN" --root "$TMP" show T-20261111-001 | grep -q 'next'
"$BIN" --root "$TMP" check >/dev/null

# dry-run must not write
BEFORE="$(sha256sum "$TMP/ztd/inbox.md" 2>/dev/null || shasum -a 256 "$TMP/ztd/inbox.md")"
"$BIN" --root "$TMP" --dry-run move T-20261111-002 someday --field contexto:personal >/dev/null
AFTER="$(sha256sum "$TMP/ztd/inbox.md" 2>/dev/null || shasum -a 256 "$TMP/ztd/inbox.md")"
[ "$BEFORE" = "$AFTER" ]

# MCP handshake and one tool call
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ztd_list","arguments":{}}}' \
  | "$BIN" --root "$TMP" mcp | grep -q '"tools"'

# A scoped list uses the scope when the request omits context.
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ztd_list","arguments":{}}}' \
  | "$BIN" --root "$TMP" mcp --scope personal --read-only | grep -q 'T-20261111-001'

# Agent store flow: temp DB only, no Markdown workspace involved.
ADB="$TMP/agent.db"
out1="$("$BIN" agent-capture --scope demo --request 'hola' --objective 'terminar el flujo' --idempotency-key k1 --db "$ADB")"
id1="$(printf '%s' "$out1" | grep -o '"id":"A-[^"]*"' | cut -d'"' -f4)"
[ -n "$id1" ]

# Same key and identical payload replays the same assignment.
out2="$("$BIN" agent-capture --scope demo --request 'hola' --objective 'terminar el flujo' --idempotency-key k1 --db "$ADB")"
printf '%s' "$out2" | grep -q '"replayed":true'
id2="$(printf '%s' "$out2" | grep -o '"id":"A-[^"]*"' | cut -d'"' -f4)"
[ "$id1" = "$id2" ]

# Same key with a different payload is a conflict, exit 1.
rc=0
out3="$("$BIN" agent-capture --scope demo --request 'otra cosa' --idempotency-key k1 --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out3" | grep -q '"code":"idempotency_conflict"'

# Checkpoint at rev 1, then a stale expect-rev conflicts.
out4="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 1 --result 'avance' --db "$ADB")"
printf '%s' "$out4" | grep -q '"assignment_rev":2'
rc=0
out5="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 1 --result 'otro avance' --db "$ADB")" || rc=$?
[ "$rc" -eq 1 ]
printf '%s' "$out5" | grep -q '"code":"revision_conflict"'

# prepare returns the objective and the latest checkpoint.
out6="$("$BIN" agent-prepare "$id1" --scope demo --db "$ADB")"
printf '%s' "$out6" | grep -q '"objective":"terminar el flujo"'
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

# Agent-mode MCP: exactly the three agent tools, no legacy tools, no resources.
mcp_agent="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"resources/list"}' \
  | "$BIN" mcp --agent-scope demo --agent-db "$ADB")"
n_agent="$(printf '%s\n' "$mcp_agent" | grep -o '"name":"ztd_agent_[a-z_]*"' | wc -l | tr -d ' ')"
n_all="$(printf '%s\n' "$mcp_agent" | grep -o '"name":"ztd_[a-z_]*"' | wc -l | tr -d ' ')"
[ "$n_agent" -eq 3 ]
[ "$n_all" -eq 3 ]
printf '%s\n' "$mcp_agent" | grep -qF '"resources":[]'

# A wrong-typed optional argument is an error, not a silently dropped field.
mcp_typed="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ztd_agent_capture","arguments":{"scope":"demo","request":"x","constraints":1}}}' \
  | "$BIN" mcp --agent-scope demo --agent-db "$ADB")"
printf '%s\n' "$mcp_typed" | grep -qF '"isError":true'
printf '%s\n' "$mcp_typed" | grep -qF 'invalid_field'

# Durability: a second checkpoint, then export, restore and backup.
out8="$("$BIN" agent-checkpoint "$id1" --scope demo --expect-rev 2 --result 'segundo avance' --db "$ADB")"
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

echo "integration ok"
