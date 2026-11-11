#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/ztd"
[ -x "$BIN" ] || BIN="$ROOT/zig-out/bin/ztd.exe"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$BIN" init "$TMP" >/dev/null
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

echo "integration ok"
