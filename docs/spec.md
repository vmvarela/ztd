# ztd specification

This document is the contract for the data format and the engine. The tests in
`src/` and `test/` are executable examples.

## 1. Workspace

A workspace is a directory containing `ztd/`:

```text
ztd/
  contexts.md          # Markdown table; first column is the context name
  config.json          # format and client policy
  inbox.md
  lists/next.md
  lists/waiting.md
  lists/someday.md
  lists/archive.md
  lists/projects/<contexto>[/<cliente>]/<proyecto>.md
  plans/daily/YYYY-MM-DD.md
  plans/weekly/
  routines/state.md    # recurring routines and their last run date
  templates/
  .state/              # lock, pending.json, last-transaction.json
  .gitignore           # .state/
  .gitattributes       # * text eol=lf
  README.md
```

`ztd/.gitignore` contains `.state/`. `.gitattributes` keeps the Markdown LF
across platforms. The binary never runs Git.

Root resolution:

1. `--root PATH`
2. `ZTD_ROOT`
3. walk from the current directory upwards until `ztd/contexts.md`,
   `ztd/config.json` or `ztd/inbox.md` exists.

`--root` accepts either the repository root or the `ztd/` directory.

## 2. Task line

```text
- [ ] T-20261111-001 | Título | contexto: trabajo | cliente: acme | proyecto: trabajo/acme/demo | capturada: 2026-11-11
```

- The checkbox is `[ ]` outside `archive` and `[x]` inside it.
- ID: `T-` + 8 digits (`YYYYMMDD`) + `-` + at least 3 digits.
- Fields are `key: value`, separated by ` | `.
- `|` inside a title or value is escaped as `\|`.
- Field order is preserved. New fields are appended.
- `capturada` is the capture date. `cerrada` is set when a task enters
  `archive`.

### Required fields

| Situation | Requirement |
| --- | --- |
| `inbox` | none |
| any other active list | `contexto` registered in `contexts.md` |
| `contexto` in `requireClientFor` | `cliente` |
| `cliente` present | `contexto` in `clientOnlyIn` |
| `waiting` | `espera` |
| `archive` | `resolución`; `cerrada` is added if missing |
| active list | no `resolución` and no `cerrada` |

`proyecto` must be a registered path under `lists/projects/`, or a suffix that
resolves to exactly one registered path. A suffix with zero or multiple matches
is `unknown_project`.

## 3. Lists and transitions

| From | To | Allowed |
| --- | --- | --- |
| any active | any active | yes, after validation |
| any active | archive | yes, with `resolución` |
| archive | any | no (`invalid_transition`) |
| same list | same list | yes; the task moves to the end |

`move` applies, in order:

1. `--text` replaces the title.
2. `--field k:v` sets fields.
3. `--unset k` removes fields.
4. Destination validation.
5. On archive: `[x]`, `cerrada` if missing.
6. On active: `[ ]`; reject `resolución`/`cerrada`.

`--expect-line N` checks the 1-based line of the task in its source file before
any write. A mismatch is `stale_task`.

`--dry-run` computes the resulting task and files but does not write or create a
journal.

## 4. JSON envelope

Success:

```json
{"ok":true,"command":"capture","data":{"created":[{"id":"T-20261111-001","list":"inbox","file":"inbox.md","line":3}]}}
```

Domain error:

```json
{"ok":false,"command":"move","error":{"code":"stale_task","message":"StaleTask"}}
```

Stable codes: `usage`, `invalid_workspace`, `unsupported_format`, `unknown_id`,
`duplicate_id`, `unknown_list`, `invalid_transition`, `stale_task`,
`pending_transaction`, `recover_conflict`, `unknown_context`, `invalid_client`,
`unknown_project`, `invalid_field`, `id_exhausted`, `scope_denied`, `read_only`,
`io_error`, plus the agent-store codes of section 11: `unknown_assignment`,
`revision_conflict`, `idempotency_conflict`, `db_busy`, `db_incompatible`,
`invalid_argument`.

Exit: `0` success, `1` domain error, `2` usage.

## 5. Storage and recovery

`Store` exposes:

```text
lock(root, exclusive) -> guard
read(rel) -> bytes          # CRLF normalized to LF
writeAtomic(rel, bytes)     # old or new content, never partial
createIfMissing(rel, bytes) -> created
```

POSIX uses `flock` through `std.Io.File.lock`; Windows uses `NtLockFile`.
Writes use `Dir.createFileAtomic` + `File.sync` + `Atomic.replace`; on POSIX the
directory is fsynced after the rename. On Windows, `AccessDenied` during
`replace` is retried five times (10 ms) before failing.

### Journal

A mutation with changes `C`:

```text
B = current bytes of every changed file
A = intended bytes
```

1. Write `.state/pending.json` with `{version, files:[{path,before,after}]}`.
2. Write every `after` atomically.
3. Delete `.state/last-transaction.json`.
4. Rename `pending.json` to `last-transaction.json`.

`recover`:

- no `pending.json`: nothing to do;
- current == `after`: already applied;
- current == `before`: write `after`;
- otherwise: `recover_conflict`, leave `pending.json` intact.

`recover` is idempotent and never overwrites an external edit.

## 6. Capture

Given the inbox content `inbox0` and texts `t1..tk`:

```text
{Pre : texts non-empty, no newline, no pending journal}
{Post: inbox' = inbox0 ++ render(M+1) ++ ... ++ render(M+k)
       created = those tasks, in order
       M = MAX suffix of T-<today>-* in every list}
```

- `M+1 > 999` is `id_exhausted`; no file is written.
- All texts are validated before the journal. One invalid text aborts the batch.
- The inbox is appended to; a missing final newline is added first.
- `capturada` is the local date.

## 7. Check

`check` reads every canonical list and every `.md` under `ztd/` except
`templates/` and `.state/`.

Errors:

- duplicate IDs;
- `[x]` outside archive, `[ ]` inside archive;
- missing `resolución` or `cerrada` in archive;
- `resolución`/`cerrada` outside archive;
- unknown context;
- client outside `clientOnlyIn`, or missing in `requireClientFor`;
- unknown project;
- malformed task-like lines;
- references to unknown IDs;
- pending journal (`pending_transaction`).

Warnings: legacy project names that resolve to exactly one registered path.
`--strict` turns warnings into errors. Exit `1` when errors remain.

## 8. Plan

`plan --context C` reads `plans/daily/YYYY-MM-DD.md`, extracts IDs matching
`T-\d{8}-\d{3,}`, deduplicates them, and returns only tasks whose `contexto` is
`C` (and `cliente` when given). Unknown IDs are ignored. Archive tasks are
included if referenced.

The plan file is a human document; `ztd` does not rewrite it.

## 9. Routines

`routines/state.md` is a Markdown table with one row per recurring routine:

```text
| rutina | cadencia | última |
| --- | --- | --- |
| inbox | diaria | 2026-11-14 |
| review | semanal:sab | 2026-11-07 |
```

`cadencia` is `diaria` or `semanal:` followed by a day (`lun`, `mar`, `mie`,
`jue`, `vie`, `sab`, `dom`); `última` is the date of the last run. Each row is
validated: an unknown cadence, a bad date or a duplicate id fails with
`invalid_field`. Monthly and yearly reviews are dated entries in `calendar.md`,
not routines.

`due` lists the rows whose cadence has elapsed. A daily routine is due when
`última` is before today. A weekly routine is due when the latest occurrence of
its day, counting back from today, is later than `última`. Text output is one
line per routine, `id | cadencia | N day(s)`, where N is the number of days
since `última`; an empty result prints `nothing due`. JSON:

```json
{"ok":true,"command":"due","data":{"routines":[{"id":"inbox","cadence":"diaria","last":"2026-11-14","days":1}]}}
```

`routine done <id>` sets that row's `última` to `--today`, preserving every
other byte of the file, and commits through the journal. An unknown id fails
with `unknown_id`. With `--dry-run` it reports the change and writes nothing.

`init` seeds `inbox`, `plan` and `review` dated at creation, so a new workspace
starts with nothing due.

## 10. MCP

Transport: JSON-RPC 2.0 over stdio, one object per line, UTF-8. stdout carries
only protocol objects; diagnostics go to stderr.

Methods: `initialize`, `notifications/initialized`, `ping`, `tools/list`,
`tools/call`, `resources/list`, `resources/read`.

Tools and resources are described in [README.md](../README.md). Tool results
use `content:[{type:"text",text:"<json>"}]` and `isError` for domain errors.
Protocol errors use JSON-RPC error objects.

The server starts without a workspace. Every tool then returns
`invalid_workspace`.

`--read-only` rejects mutations with `read_only`. `--scope C` rejects access to
another context with `scope_denied`.

## 11. Agent store

The agent-continuity store is a SQLite database that records what an agent was
asked to do and how far it got: assignments and checkpoints. It is independent
of the Markdown lists and does not replace them — `ztd/` stays the
human-facing task lists.

Schema version 1 (`PRAGMA user_version`): tables `scope`, `assignment`,
`checkpoint` and `op_log`. Any other version fails with `db_incompatible`.
A zero-version database is initialised only when it has no tables, indexes,
views or triggers of its own; any other database is rejected, never adopted.
The default database path is `--db` > `ZTD_AGENT_DB` > a per-OS default under
the user data directory. Only the default is guaranteed to stay outside a
workspace `ztd/`; an explicit path or environment variable can point anywhere
the caller chooses.

Operations, exposed as `ztd agent-capture`, `ztd agent-checkpoint`,
`ztd agent-prepare` and as the three `ztd_agent_*` MCP tools:

- `capture` inserts an assignment at rev 1 in its scope.
- `checkpoint` records a checkpoint and increments the assignment rev;
  `kind` is `progress` or `done`.
- `prepare` reads an assignment and its newest checkpoint.

Errors: `scope_denied` (assignment belongs to another scope),
`unknown_assignment`, `revision_conflict`, `idempotency_conflict`, `db_busy`,
`db_incompatible`, and `invalid_argument` for a refused restore or backup
target or a malformed export (durability commands only).

- `expect_rev` is optimistic concurrency: a checkpoint whose `expect_rev` does
  not match the stored rev fails with `revision_conflict` and writes nothing.
  Recovery then means re-reading with `prepare` and retrying with the new rev,
  not a blind retry.
- Idempotency keys are retained indefinitely; the dedup window is all retained
  `op_log` rows. The same key with the same payload replays the stored result;
  with a different payload it is `idempotency_conflict`. Replay is checked
  before `expect_rev`, so an identical retry succeeds even if the assignment
  has moved on since; a different payload still conflicts.
- Scope is enforced outside tool arguments: the CLI takes `--scope`, MCP takes
  it from server configuration (`--agent-scope`), and the store checks it on
  every operation.
- Writes take a brief `BEGIN IMMEDIATE` transaction after a 5 s busy timeout.
  A competing writer waits and usually proceeds; only a lock still held after
  the timeout returns `db_busy`.
- WAL mode requires a local filesystem on one host; the database must not live
  on a network filesystem.
- Concurrency is between processes, not threads: a single connection per
  process, one writer at a time. Two processes opening a fresh database at once
  are serialised by the initialization lock, and both succeed. Reads need the
  file to be writable at first use (the database becomes WAL); once it is WAL,
  a read-only file still serves `prepare`.
- `kind` is `progress` or `done`; `done` sets the assignment status to `done`.
  A `progress` checkpoint after completion is a note: it is recorded and
  increments the rev, but the status stays `done`. There is no reopen
  operation.

Durability, exposed only as `ztd agent-backup`, `ztd agent-export` and
`ztd agent-restore` — operator actions, deliberately without MCP tools:

- `agent-export --out FILE` writes one JSON object
  `{"format":"ztd-agent-export","version":1,"scopes":[...],"assignments":[...],"checkpoints":[...],"operations":[...]}`.
  Field names are the schema columns, rows are ordered by id (`op_log` by
  key), null columns are JSON `null` — never `""` — and `request_sha256` is
  lowercase hex. The file is overwritten if it exists.
- `agent-restore --from FILE` accepts only `format` `ztd-agent-export` with
  `version` 1 and refuses everything else with `invalid_argument`: a
  malformed or partial document, unknown or missing fields, duplicate ids, a
  reference to a missing row, bad hex (exactly 64 hex digits; either case is
  accepted, export always writes lowercase), a `status` or `kind` outside the
  stored set, checkpoints whose rev is not between 2 and their assignment's
  rev or that repeat a rev within one assignment, and any non-empty target
  store (a row in any of the four tables). All rows are inserted in one
  transaction; the row counts must equal the document's and every assignment
  rev must equal `1 + its checkpoint count`, otherwise the transaction rolls
  back and the store stays untouched. The command returns the inserted counts.
- `agent-backup --out FILE` copies the store with
  `VACUUM INTO '<absolute path>'` (any single quote in the path is doubled).
  An existing file is never overwritten. The copy carries `user_version` and
  opens through the schema gate.
- `agent-prepare ID --scope S --history N` returns at most `N` checkpoints
  newest-first by rev in addition to `latest` and `assignment`. `N` is a
  positive integer at the CLI (`--history 0` is a usage error); the store's
  `history` returns none for a zero limit. Without the flag the response is
  unchanged.

The agent MCP mode (`ztd mcp --agent-scope S [--agent-db PATH]`) exposes only
these three tools and no resources; `--read-only` rejects `capture` and
`checkpoint` and allows `prepare`.
