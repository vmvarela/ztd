# ztd specification

This document is the contract for the data format and the engine. The tests in
`src/` and `test/` are executable examples.

## 1. Store

The store is a directory of Markdown task data:

```text
<store>/
  contexts.md          # Markdown table; first column is the context name
  config.json          # format and client policy
  inbox.md
  lists/next.md
  lists/waiting.md
  lists/someday.md
  lists/archive.md
  lists/projects/<context>[/<client>]/<project>.md
  plans/daily/YYYY-MM-DD.md
  plans/weekly/
  routines/state.md    # recurring routines and their last run date
  templates/
  .state/              # lock, pending.json, last-transaction.json
  .gitignore           # .state/
  .gitattributes       # * text eol=lf
  README.md
```

`contexts.md` is a Markdown table with `Context` and `Use` columns; optional
`Clients` and `Knowledge` columns follow.

`<store>/.gitignore` contains `.state/`. `.gitattributes` keeps the Markdown LF
across platforms. The binary never runs Git.

Root resolution:

1. `--root PATH`
2. `ZTD_ROOT`
3. `~/.ztd`

`--root` names the store root exactly. The root is never discovered from the
current directory. `ztd status` is the single state probe: it applies root
precedence and reports `root`, `source` (`flag` for `--root`, `env` for
`ZTD_ROOT`, `home` for `$HOME/.ztd`), `exists`, `format` (the `config.json`
format when readable, else `null`) and `binding`. With `--json` these five keys
are the `data` payload of the standard envelope, in that order. `binding` is
`null` when no repository binding is found; otherwise it is
`{path,value,error}`, where `value` is the exact `{context,client,project}`
object or `null` for a malformed binding. A malformed or absent binding does
not prevent root reporting or change status's exit code. Human output prints
`root:`, `source:`, `store:` and `binding:` diagnostics. Status never creates
the store and exits `0` whether or not it exists.

### Repository binding

A `.ztd.json` contains exactly three required keys: nonblank string `context`,
nullable nonblank string `client`, and nonblank fully qualified `project`.
Duplicate, missing or extra keys, invalid types and scope inconsistencies are
errors. The CLI finds the nearest `.ztd.json` from the current directory,
stopping at the current Git repository boundary (including worktrees); a
nested repository does not inherit a parent binding. A malformed nearest
binding is reported without falling back. Discovery never affects root
resolution. A binding is a routing hint, not authorization.

`ztd check --bindings` validates only the selected current-repository binding
against the resolved store: registered context, client policy and registered
project path. It fails if the binding is missing or invalid. It does not scan
other repositories, inspect remotes or resolve clone paths.

## 2. Task line

The data format is version 2: `config.json` carries `"format":2`. Reserved
field names on a task line: `context`, `client`, `project`, `captured_at`,
`closed_at`, `waiting_on`, `resolution`.

```text
- [ ] T-20261111-001 | Title | context: work | client: acme | project: work/acme/demo | captured_at: 2026-11-11
```

- The checkbox is `[ ]` outside `archive` and `[x]` inside it.
- ID: `T-` + 8 digits (`YYYYMMDD`) + `-` + at least 3 digits.
- Fields are `key: value`, separated by ` | `.
- `|` inside a title or value is escaped as `\|`.
- Field order is preserved. New fields are appended.
- `captured_at` is the capture date. `closed_at` is set when a task enters
  `archive`.

### Required fields

| Situation | Requirement |
| --- | --- |
| `inbox` | none |
| any other active list | `context` registered in `contexts.md` |
| `context` in `requireClientFor` | `client` |
| `client` present | `context` in `clientOnlyIn` |
| `waiting` | `waiting_on` |
| `archive` | `resolution`; `closed_at` is added if missing |
| active list | no `resolution` and no `closed_at` |

`waiting_on` is free text. A trailing `@YYYY-MM-DD` is a convention the agent
skills use for follow-up; the CLI does not parse it.

`project` must be a registered path under `lists/projects/`, or a suffix that
resolves to exactly one registered path. A suffix with zero or multiple matches
is `unknown_project`.

## 3. Lists and transitions

| From | To | Allowed |
| --- | --- | --- |
| any active | any active | yes, after validation |
| any active | archive | yes, with `resolution` |
| archive | any | no (`invalid_transition`) |
| same list | same list | yes; the task moves to the end |

`move` applies, in order:

1. `--text` replaces the title.
2. `--field k:v` sets fields.
3. `--unset k` removes fields.
4. Destination validation.
5. On archive: `[x]`, `closed_at` if missing.
6. On active: `[ ]`; reject `resolution`/`closed_at`.

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
`io_error`, `conflict`, plus the agent-store codes of section 11: `unknown_assignment`,
`revision_conflict`, `idempotency_conflict`, `db_busy`, `db_incompatible`,
`invalid_argument`, and the conversion codes of section 12:
`ambiguous_source`, `mixed_signals`, `key_collision`, `destination_exists`,
`path_overlap`, `unsupported_entry`, `stage_invalid`, `source_changed`.

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
- `captured_at` is the local date.

## 7. Check

`check` reads every canonical list and every `.md` under the store root except
`templates/` and `.state/`.
`--bindings` additionally requires and validates the current repository's
`.ztd.json`; without the flag, check does not discover repositories.

Errors:

- duplicate IDs;
- `[x]` outside archive, `[ ]` inside archive;
- missing `resolution` or `closed_at` in archive;
- `resolution`/`closed_at` outside archive;
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
`T-\d{8}-\d{3,}`, deduplicates them, and returns only tasks whose `context` is
`C` (and `client` when given). Unknown IDs are ignored. Archive tasks are
included if referenced.

The plan file is a human document; `ztd` does not rewrite it.

## 9. Routines

`routines/state.md` is a Markdown table with one row per recurring routine:

```text
| routine | cadence | last |
| --- | --- | --- |
| inbox | daily | 2026-11-14 |
| review | weekly:sat | 2026-11-07 |
```

`cadence` is `daily` or `weekly:` followed by a day token (`mon`, `tue`,
`wed`, `thu`, `fri`, `sat`, `sun`; Monday-first); `last` is the date of the
last run. Each row is validated: an unknown cadence, a bad date or a duplicate
id fails with `invalid_field`. Monthly and yearly reviews are dated entries in
`calendar.md`, not routines.

`due` lists the rows whose cadence has elapsed. A daily routine is due when
`last` is before today. A weekly routine is due when the latest occurrence of
its day, counting back from today, is later than `last`. Text output is one
line per routine, `id | cadence | N day(s)`, where N is the number of days
since `last`; an empty result prints `nothing due`. JSON:

```json
{"ok":true,"command":"due","data":{"routines":[{"id":"inbox","cadence":"daily","last":"2026-11-14","days":1}]}}
```

`routine done <id>` sets that row's `last` to `--today`, preserving every
other byte of the file, and commits through the journal. An unknown id fails
with `unknown_id`. With `--dry-run` it reports the change and writes nothing.

`init` seeds `inbox`, `plan` and `review` dated at creation, so a new store
starts with nothing due.

## 10. Agent store

The agent-continuity store is a SQLite database that records what an agent was
asked to do and how far it got: assignments and checkpoints. It is independent
of the Markdown lists and does not replace them — the store root keeps the
human-facing task lists.

Schema version 2 (`PRAGMA user_version`): tables `scope`, `assignment`,
`checkpoint`, `op_log` and `knowledge`, plus the FTS5 index `knowledge_fts`.
A version-1 database is upgraded to version 2 inside the same initialisation
transaction, creating only the knowledge objects; a version-2 database is
verified against the version-2 object set, and any other version fails with
`db_incompatible`.
A zero-version database is initialised only when it has no tables, indexes,
views or triggers of its own; any other database is rejected, never adopted.
The default database path is `--db` > `ZTD_AGENT_DB` > a per-OS default under
the user data directory. Only the default is guaranteed to stay outside the
Markdown store; an explicit path or environment variable can point anywhere
the caller chooses.

Operations, exposed as `ztd agent-capture`, `ztd agent-checkpoint` and
`ztd agent-prepare`:

- `capture` inserts an assignment at rev 1 in its scope.
- `checkpoint` records a checkpoint and increments the assignment rev;
  `kind` is `progress` or `done`.
- `prepare` reads an assignment and its newest checkpoint.

Errors: `scope_denied` (assignment belongs to another scope),
`unknown_assignment`, `revision_conflict`, `idempotency_conflict`, `db_busy`,
`db_incompatible`, and `invalid_argument` for a refused restore or backup
target, a malformed export, or a knowledge refusal (unknown `kind`, a
non-positive `limit`, a malformed FTS5 query).

- `expect_rev` is optimistic concurrency: a checkpoint whose `expect_rev` does
  not match the stored rev fails with `revision_conflict` and writes nothing.
  Recovery then means re-reading with `prepare` and retrying with the new rev,
  not a blind retry.
- Idempotency keys are retained indefinitely; the dedup window is all retained
  `op_log` rows. The same key with the same payload replays the stored result;
  with a different payload it is `idempotency_conflict`. Replay is checked
  before `expect_rev`, so an identical retry succeeds even if the assignment
  has moved on since; a different payload still conflicts.
- Scope is explicit on every command (`--scope`) and the store checks it on
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

### Knowledge

Scoped knowledge records with full-text recall, exposed as `ztd
agent-remember` and `ztd agent-recall`:

- `knowledge` rows: `id` (`K-YYYYMMDD-NNN`), `scope_id`, `kind` (`fact`,
  `decision`, `constraint` or `procedure`), `text`, optional `source`, `rev`
  and `created_at`. Records are append-only: `remember` inserts at rev 1 and
  there is no update or delete operation.
- `knowledge_fts` is a standalone (not external-content) FTS5 index over
  `text`, `source` and `id`, tokenized with `unicode61 remove_diacritics 2`.
  Its row is written in the same transaction as the `knowledge` row it
  mirrors, keyed by `knowledge.rowid`, so the index cannot drift from the
  table; a fresh database builds both in one initialisation transaction and a
  version-1 database gains them through the migration described above.
- `agent-remember --scope S --kind K --text T [--source SRC]` upserts the
  scope and stores one record; a `kind` outside the four values is
  `invalid_argument`. Idempotency keys follow the `capture` contract: the
  same key with the same payload replays the stored record, with a different
  payload it is `idempotency_conflict`.
- `agent-recall --scope S --query Q [--limit N]` is read-only: the SQL
  filters `knowledge.scope_id` before any ranking, joins `knowledge_fts` on
  `knowledge.rowid` and orders by `bm25(knowledge_fts)` (ascending: best
  match first), returning at most `N` rows (`N` is a positive integer at the
  CLI — `--limit 0` is a usage error; the store's `recall` rejects a
  non-positive limit with `invalid_argument` — and without `--limit` the top
  20). An unknown scope returns an empty list; a malformed FTS5 query is
  `invalid_argument`, never `io_error`, while an I/O failure stays
  `io_error`.

Durability, exposed only as `ztd agent-backup`, `ztd agent-export` and
`ztd agent-restore` — operator actions:

- `agent-export --out FILE` writes one JSON object
  `{"format":"ztd-agent-export","version":2,"scopes":[...],"assignments":[...],"checkpoints":[...],"operations":[...],"knowledge":[...]}`.
  Field names are the schema columns — knowledge rows carry the record field
  names `id`, `scope`, `kind`, `text`, `source`, `rev`, `created_at` — rows
  are ordered by id (`op_log` by `key`, `knowledge` by `id`), null columns
  are JSON `null` — never `""` — and `request_sha256` is lowercase hex. The
  file is overwritten if it exists.
- `agent-restore --from FILE` accepts only `format` `ztd-agent-export` with
  `version` 1 or 2 — a version-1 document carries no knowledge array and
  restores no knowledge rows — and refuses everything else with
  `invalid_argument`: a malformed or partial document, unknown or missing
  fields, duplicate ids, a reference to a missing row, bad hex (exactly 64
  hex digits; either case is accepted, export always writes lowercase), a
  `status` or `kind` outside the stored set, checkpoints whose rev is not
  between 2 and their assignment's rev or that repeat a rev within one
  assignment, a knowledge row whose `kind` is outside the four knowledge
  kinds, whose `rev` is not 1, whose `id` is empty or repeated, or whose
  scope is not a scope row of the document, and any non-empty target store
  (a row in any of the tables). All rows are inserted in one transaction —
  each knowledge row together with its `knowledge_fts` row — and the row
  counts (knowledge included) and every assignment rev (`1 + its checkpoint
  count`) are verified before the commit, so a refusal rolls back and the
  store stays untouched. The command returns the inserted counts.
- `agent-backup --out FILE` copies the store with
  `VACUUM INTO '<absolute path>'` (any single quote in the path is doubled).
  An existing file is never overwritten. The copy carries `user_version` and
  opens through the schema gate.
- `agent-prepare ID --scope S --history N` returns at most `N` checkpoints
  newest-first by rev in addition to `latest` and `assignment`. `N` is a
  positive integer at the CLI (`--history 0` is a usage error); the store's
  `history` returns none for a zero limit. Without the flag the response is
  unchanged.

## 11. Format-1 conversion

`ztd migrate --from SOURCE --to DEST [--dry-run] [--json]` converts a format-1
Markdown store into format 2. `SOURCE` and `DEST` are exact store directories;
this command does not use the configured root, infer either path from the
current directory, or modify the source. The destination must not exist, its
parent must already exist, and source and destination must not overlap. A
destination that appears during conversion is never replaced.

The converter accepts an explicit `config.json` format of `1`. A missing
configuration is accepted only when the canonical format-1 store structure and
at least one legacy structural marker agree: the `Contexto` table header, a
legacy reserved task field, or a format-1 routine token. Legitimate v1 stores
initialized before a given file existed are covered by that rule. The converter
then creates format-2 configuration with empty client-policy arrays and reports
that inference. Malformed, unreadable, mixed-format, or ambiguous inputs are
refused. Existing unknown configuration properties are preserved.

Only structural tokens are translated:

- The reserved task fields in the five canonical lists become `context`,
  `client`, `project`, `captured_at`, `closed_at`, `waiting_on`, and
  `resolution`.
- The contexts-table header becomes English.
- An existing routine table uses the format-2 header and cadence tokens:
  `daily` and Monday-first `weekly:mon` through `weekly:sun`.

Task IDs, checkboxes, titles, values, custom fields, field order, context and
client identifiers, project paths, routine IDs, and existing routine dates are
preserved. Other regular files are copied byte-for-byte. The converter never
translates prose or arbitrary Markdown. It refuses malformed task/routine
data, duplicate IDs or fields, key collisions (including collisions with
custom fields), pending transactions, symlinks, special files, and traversal
or access errors. A top-level `.git` or `.state` is not copied; nested ones are
copied as ordinary content.

If `routines/state.md` is genuinely absent, the converter seeds the current
`inbox`, `plan`, and `review` routine rows using one captured conversion date.
These rows establish an initial scheduling baseline; they do not represent
completed reviews or recovered history. Existing routine state is never
re-seeded.

Conversion is staged beside the destination, checked as a format-2 store, and
promoted without replacement. `--dry-run` writes nothing, including temporary
files; it performs source preflight and in-memory structural conversion checks
but cannot run the full store check on a staged copy. A real conversion
validates the staged result before promotion. The original remains unchanged,
but this is a forward-only conversion: keeping the source does not provide a
lossless rollback after new work is written to the format-2 destination.

The report names the destination format (`rewritten` or `synthesized`), the
routine outcome (`transformed` or `seeded`), the captured `seed_date` when rows
were seeded, file and task counts, renamed fields, and whether the staged store
passed the strict check (always false for `--dry-run`). Conversion reads the
source without creating locks or state; a concurrent writer is detected by
comparing a content inventory before and after, so writers must be paused for
the duration, and a writer that ignores that rule can still race the final
promotion window.

## 12. TUI

`ztd tui` opens an interactive, read-only browser over the same store. It
builds the index from `Engine.loadAll()` plus one walk of the store
(`lists/projects/`, `plans/`, `reviews/`, `knowledge/`, `journal/`, `goals/`)
and reads `routines/` through the routine parser. Documents are loaded from
Markdown on selection; nothing is cached to disk.

The command takes no arguments and rejects `--json` and `--dry-run`. It opens
the store in shared mode and releases the lock immediately, so `ztd` writers in
another terminal are never blocked and never see a partial read: each reload
rebuilds the index from complete files.

Key handling is `q` quit, arrows or `j`/`k` move, `ctrl+d`/`ctrl+u` page,
`g`/`G` first/last, `enter`/`space` expand, `tab` switch pane, `h`/`l` collapse
or focus, `/` filter, `?` help, `r` reload. Mouse wheel scrolls the pane under
the pointer, a click selects and focuses, and dragging the divider moves the
split between 20 columns and the width minus 30. Below 100 columns the browser
shows one pane at a time; below 40x8 it prints a size notice.

The tree polls the store once a second by hashing path, mtime and size. When
the signature changes it reloads and keeps the selection by task ID or document
path. Polling runs on the UI thread, so there are no background readers and no
extra file descriptors. Colors follow the terminal's reported light or dark
scheme and are disabled by `NO_COLOR`.

### Hoy, themes and zen

Hoy is the entry index: the active goal from `goals/active.md` plus today's
MITs from the daily plan; a missing goal or plan omits those rows.

| Key | Name | Character |
| --- | --- | --- |
| `paper` | Paper | neutral accent |
| `tea` | Tea | green accent |
| `amber` | Amber | amber accent |

`t` cycles the themes; the default comes from `config.json` →
`"tui": { "theme": "tea" }`, and an absent or invalid value falls back to
`paper`. Selection and theme are session-only and never written back: the TUI
never writes to the store, not even preferences. `z` toggles zen reading mode;
keys, selection, navigation and the once-a-second refresh are unchanged.
