# Dependency spikes (Pass 0)

Run on 2026-11-19, macOS arm64, Go 1.27.4 (`/Users/victor/go/1.27.3/bin/go1.27.4`).

## Go

`go version go1.27.4 darwin/arm64`.

The wrapper binary is used because the inherited `GOROOT` points at 1.27.3.
`env -u GOROOT /Users/victor/sdk/go1.27.4/bin/go` is equivalent.

## SQLite: modernc.org/sqlite v1.62.0

`go run ./spikes/sqlite` output:

```text
fts hit=K-1 journal=wal snapshot=32768 bytes
```

Evidence:

- `_pragma=journal_mode(WAL)`, `foreign_keys(1)`, `busy_timeout(5000)`,
  `synchronous(FULL)` open successfully.
- FTS5 virtual table with `tokenize='unicode61 remove_diacritics 2'` matched
  accented Spanish content from an unaccented query.
- `VACUUM INTO` produced a readable 32 KiB snapshot under WAL.
- No CGo, no external SQLite library.

Two-process `BEGIN IMMEDIATE` contention is covered by the integration suite,
not by this single-process spike. If it fails there, fall back to
`mattn/go-sqlite3` (CGo, macOS-only is acceptable for this product).

## MCP: github.com/modelcontextprotocol/go-sdk v1.8.0

`go build ./spikes/...` succeeds on Go 1.27.4. Registration shape:

```text
opencode mcp add ztd-spike -- <binary>
```

API used: `mcp.NewServer`, `mcp.AddTool`, `server.Run(ctx, &mcp.StdioTransport{})`.
This is a pinned dependency decision only; no MCP product code ships before
Stage 3a.
