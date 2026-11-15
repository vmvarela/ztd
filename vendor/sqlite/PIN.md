# SQLite pin

Vendored, unmodified, from the official amalgamation. Public domain; keep the
upstream header comments intact (they carry the dedication and `SQLITE_SOURCE_ID`).

- Version: **3.54.1** (released 2026-10-16). 3.54.1 fixes a 32-bit heap overflow;
  the release matrix still ships 32-bit targets, so do not downgrade.
- Source: <https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip>
- Zip SHA3-256 (upstream): `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`
- Zip SHA-256 (computed): `0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9`
- `sqlite3.c` SHA3-256 (upstream): `e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81`
- `sqlite3.c` SHA-256 (computed): `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`
- `sqlite3.h` SHA-256 (computed): `d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c`

Only `sqlite3.c` and `sqlite3.h` are vendored; `shell.c` and `sqlite3ext.h` are not needed.

## Compile flags (must match `build.zig`)

`SQLITE_THREADSAFE=0` assumes one connection per process on one thread. The CLI is
one-shot and the MCP server is a sequential loop, so cross-process concurrency is
handled by SQLite's file locks and `busy_timeout`, not by SQLITE_THREADSAFE. If any
second thread ever touches the DB, switch to `=1` and recompile; no data migration.

`SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0`, `SQLITE_DEFAULT_FOREIGN_KEYS=1`,
`SQLITE_DEFAULT_WAL_SYNCHRONOUS=1` (WAL + NORMAL: a power loss may lose recent
commits but cannot corrupt), `SQLITE_ENABLE_FTS5` (the amalgamation ships FTS5
compiled out by default; the `knowledge_fts` index needs it).

## Upgrade rule

Replace both files, update the hashes above, update the version assertion in
`src/db.zig`, and rebuild. Schema compatibility is stable across minor releases.

WAL requires a local filesystem on one host; never place the store on a network
share or a multi-machine synced folder.
