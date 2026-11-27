# Architecture

ZTD is one local binary around one SQLite database. An agent can drive it
through the CLI today; MCP will be a second interface over the same application
layer, not a second implementation.

## Dependency direction

```
src/main.zig ──> src/cli.zig ──> src/store/core.zig ──> src/domain.zig
              └─> src/mcp.zig ──┘        │
                                        ├─> src/store/store.zig (migrations, ids, history)
                                        ├─> src/sqlite.zig (C bridge over the amalgamation)
                                        ├─> src/timeutil.zig
                                        ├─> src/errors.zig
                                        └─> src/json.zig
```

- `src/domain.zig` holds the entities and their JSON shapes. Nothing here knows
  about SQL, flags or stdio.
- `src/store/core.zig` is the use-case and persistence layer: it validates
  preconditions, runs one transaction per intent, writes history and
  idempotency records, and renders the same JSON the Go implementation did.
- `src/store/store.zig` owns the connection, the migration runner (0001–0012,
  each SQL plus an optional bounded assertion step) and the identifier
  sequences.
- `src/sqlite.zig` is the only place that touches the C API; the SQLite
  amalgamation lives in `third_party/sqlite` and is compiled with FTS5 and
  JSON1 into the binary.
- `src/cli.zig` parses flags with the same semantics as Go's `flag` package and
  renders the JSON envelope. `src/mcp.zig` is a thin stdio adapter: it embeds
  the tool and prompt payloads, maps the same errors, and calls the same
  `core` functions, so MCP is a second interface, not a second implementation.
- `src/docs.zig` holds the document link graph and the lint report; `src/install.zig`
  publishes the embedded bundles from `src/install_bundle/`.
- `src/timeutil.zig` is the only place that reads the clock or the local
  timezone (through libc); `src/json.zig` is the only place that escapes
  strings, because the request hashes are computed over those exact bytes.

The Markdown legacy importer is not part of this tree: `migrate import|verify|
documents` lives in the Go implementation kept at the `v2-go-final` tag and runs
against a quiescent copy when needed.

## Storage

SQLite is canonical. Markdown is not a second writable copy.

- `foreign_keys=on`, WAL, `synchronous=FULL`, bounded `busy_timeout`.
- Every write uses `BEGIN IMMEDIATE` and short transactions.
- One mutation writes current state, an append-only `history_events` row and an
  `idempotency_records` row in the same transaction.
- Migrations are embedded SQL files applied in order under `PRAGMA user_version`.
  An unknown or newer schema is rejected, never guessed.
- No transaction is held open across an LLM call, network request or user
  prompt.

## Identity and revisions

IDs are stable and opaque:

- `C-YYYYMMDD-NNN` captures
- `T-YYYYMMDD-NNN` work items (the legacy ID shape is preserved on import)
- `P-`, `F-`, `CP-`, `R-`, `K-` for plans, focus sessions, checkpoints,
  reviews and knowledge
- Source IDs are operator-chosen slugs matching `[a-z][a-z0-9_-]{1,63}` —
  they name configuration, they are not generated

A work item changes lifecycle without moving to another file. Revision numbers
guard optimistic concurrency: a stale `expected` value fails with
`stale_revision` and writes nothing.

Retries are idempotent by `(command, idempotency_key)`. The same key and payload
returns the stored result; the same key with different payload fails with
`idempotency_conflict` before any write.

## Scopes and the planning view

A `Scope` is a data partition: `personal`, `opensource`, `work`, or
`client:<name>`. A `ScopeBinding` names the actor and the allowed scopes for
one command. It is established by the CLI or host, not by the model and not by
a tool argument.

There is one planning view over every declared scope. Internally it is stored
as a single profile row (`personal`) because goals, plans and reviews need a
stable owner, but the user never chooses or configures it. `init` creates it
and extends it when new scopes are declared. Every entity still belongs to
exactly one scope, so scope labels and filters remain meaningful.

The binding of a command is a view over that one store, not a second copy of
it: it narrows what a command can see and never splits or duplicates tasks.
By default the binding is the profile's scopes without `client:*` and `work`
scopes, so a personal view never returns client work. A client scope requires
an explicit selection — `--scope client:<name>`, the host-level `ZTD_SCOPES`
variable, or a `.ztd.json` hint that resolves to it — in that precedence
order, and the profile row plus the per-scope ownership of every record stay
unchanged.

Daily limits are global per actor: one to three MITs per day and at most one
open focus session at a time. A committed plan outside that range requires a
recorded `DailyLimitOverride`. The planning view has at most one primary goal.

## Interfaces

The CLI is the current interface and the fallback for every operation. JSON
output is stable enough for scripts and tests.

The MCP server exposes a small typed set of seventeen tools over stdio:
`capture`, `inbox_next`, `process_capture`, `prepare`, `commit_plan`,
`focus_start`, `checkpoint`, `focus_finish`, `record_review`,
`find`, `read`, `sources`, `record_source_review`, `doc_search`, `doc_get`,
`doc_related` and `doc_put`. It does not expose raw SQL, arbitrary updates,
arbitrary scope overrides or provider tools. Document tools may select a
scope only from the fixed session binding.
`sources` returns registry state only; `record_source_review`
ingests `reported` batches and rejects `observed`, which stays reserved for a
trusted host adapter outside model-controlled arguments.
`doc_put` is the only document write: it takes `scope`, `slug`, `title`,
`body` and `expected_revision`, validates the selected scope against the fixed
binding, hardcodes `kind=knowledge` and `status=draft`, and the store refuses
create-only overwrites and any promotion past draft. Reads with duplicate
kind/slug matches require an explicit bound scope rather than choosing one.
The combined slug, title and body input is capped at 512 KiB before persistence
to keep the MCP response within transport limits.

MCP prompts and resources are guidance, not scheduling. A disconnected server
cannot remind anyone; reminders require the operating system scheduler.
`commit_plan` has no model-supplied approval flag; the host must gate the
call with a real human permission prompt.

## Failure model

Errors are values with a stable family and a detail string. The family is part
of the API; the detail is for humans.

| Family | Meaning |
| --- | --- |
| `invalid_input` | Malformed request or missing required field |
| `invalid_transition` | The entity cannot move to that state |
| `not_found` | No such entity in the binding |
| `scope_denied` | The entity exists outside the allowed scopes |
| `stale_revision` | The caller used an outdated revision |
| `idempotency_conflict` | Same key, different payload |
| `focus_conflict` | The actor already has an open focus |
| `human_decision_required` | A human must choose before the operation can proceed |
| `destination_not_empty` | Import, restore or snapshot target already has content |
| `db_incompatible`, `db_busy`, `io_error` | Operational failures |

`check` verifies the invariants that SQL constraints cannot express alone:
required fields, lifecycle rules, capture outcomes, plan membership, duplicate
external identities and the presence of history for mutable entities.

## Deferred layers

- Source connectors that actually retrieve: GitHub, Jira, email, directory
  scanning and calendars — the registry and reported-batch ingestion exist;
  no connector calls a provider yet
- Confirmed external focus blocks and reconciliation (Stage 4)
- Remote backup with Restic (optional, not configured): the approved backup
  path is `ztd snapshot` to an iCloud-synced directory (approved 2026-11-22);
  no encryption or remote verification is claimed for that path
- Knowledge wiki and optional vector search (Stage 5) — search and link
  relations are delivered: `doc search` (FTS5), `doc related`, `doc log`,
  `doc lint` and `doc archive` exist over the document layer, and MCP exposes
  `doc_search`, `doc_get`, `doc_related` and the draft-only `doc_put`. The wiki skill itself, the
  vector search and the LLM Wiki tables remain deferred
- Terminal UI

The delivery order is in the specification, not implied by the presence of a
package.
