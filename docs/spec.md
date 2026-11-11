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
  templates/
  .state/              # lock, pending.json, last-transaction.json
```

`ztd/.gitignore` contains `.state/`. The binary never runs Git.

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
`io_error`.

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

## 9. MCP

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
