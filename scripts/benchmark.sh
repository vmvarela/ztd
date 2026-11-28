#!/usr/bin/env bash
# Release measurements for the Zig build: size, startup, RSS, tools/list bytes
# and database size after a fixed journey. Prints a Markdown table.
# Requires: zig, hyperfine, sqlite3. Earlier Go-vs-Zig numbers are kept in
# docs/benchmarks/baseline.md as the rewrite baseline.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
ZIG=${ZIG:-/Users/victor/bin/zig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== build =="
"$ZIG" build --release=fast
zigbin="$root/zig-out/bin/ztd"

size() { stat -f %z "$1"; }
rss() { /usr/bin/time -l "$1" version 2>&1 >/dev/null | awk '/maximum resident set size/ {print $1}'; }

# One JSON-RPC stdio session; prints the byte length of the tools/list response.
toolsbytes() {
	local bin=$1 db=$2
	"$bin" --db "$db" init --non-interactive --scope id=personal,kind=personal,name=Personal >/dev/null
	{ printf '%s\n' \
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bench","version":"0"}}}' \
		'{"jsonrpc":"2.0","method":"notifications/initialized"}' \
		'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 1; } |
		"$bin" mcp --db "$db" 2>/dev/null |
		awk '/"id":2/ { print length($0); exit }'
}

journey() {
	local bin=$1 db=$2
	local id item item2
	"$bin" --db "$db" init --non-interactive --scope id=personal,kind=personal,name=Personal >/dev/null
	id=$("$bin" --db "$db" capture "alpha capture one" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["id"])')
	item=$("$bin" --db "$db" process --outcome work_items --title "Alpha one" "$id" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["work_items"][0]["id"])')
	id=$("$bin" --db "$db" capture "beta capture two" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["id"])')
	item2=$("$bin" --db "$db" process --outcome work_items --title "Beta two" "$id" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["work_items"][0]["id"])')
	"$bin" --db "$db" capture "gamma capture three" >/dev/null
	"$bin" --db "$db" move --waiting-on "Someone" "$item" waiting >/dev/null
	"$bin" --db "$db" doc put --kind knowledge --slug baseline/note --title "Nota" --body "cuerpo de prueba" >/dev/null
	"$bin" --db "$db" project add alpha --desired-outcome "Baseline recorded" >/dev/null
	"$bin" --db "$db" goal set --statement "Ship v3" >/dev/null
	"$bin" --db "$db" routine add --id weekly-review --cadence weekly:mon >/dev/null
	"$bin" --db "$db" review daily --period "2026-11-27" --outcomes "2 completed" --coverage "0.8" >/dev/null
	"$bin" --db "$db" focus start "$item2" >/dev/null
	sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
	echo $(( $(size "$db") + $( [ -f "$db-wal" ] && size "$db-wal" || echo 0 ) ))
}

echo
echo "| métrica | ztd (Zig) |"
echo "|---|---|"
echo "| binario (bytes) | $(size "$zigbin") |"
echo "| arranque medio (ms) | $(hyperfine --warmup 10 --runs 30 --style basic --export-json "$tmp/zig.json" "$zigbin version" >/dev/null 2>&1; python3 -c "import json;print(round(json.load(open('$tmp/zig.json'))['results'][0]['mean']*1000,2))") |"
echo "| RSS máximo (bytes) | $(rss "$zigbin") |"
echo "| tools/list (bytes) | $(toolsbytes "$zigbin" "$tmp/tools-zig.sqlite") |"
echo "| DB tras journey (bytes) | $(journey "$zigbin" "$tmp/j-zig.sqlite") |"
