# Architecture

ZTD is one local binary around one SQLite database. An agent can drive it
through the CLI today; MCP will be a second interface over the same application
layer, not a second implementation.

## Dependency direction

```
cmd/ztd
  └── internal/cli ──> internal/app ──> internal/domain
  └── internal/mcpserver ──> internal/app
                         ^                ^
                         │                │
                    internal/store ───────┘
                    internal/legacy ──────┘
```

- `internal/domain` holds entities, identifiers, error families and invariants.
  It imports no storage, transport or framework.
- `internal/app` holds use cases and the `Repo` port. It validates
  preconditions and orchestrates one call per user intent.
- `internal/store` implements `Repo` on SQLite. It owns transactions, SQL,
  migrations and the append-only history. `internal/store/sources.go` holds
  the source registry and recorded batches; `internal/store/documents.go`
  holds contexts, documents and projects — the document layer the Markdown
  skills used to keep as files.
- `internal/legacy` parses the old Markdown store and agent export. It is
  read-only and has no dependency on the new store.
- `internal/cli` parses flags and renders text or JSON. It contains no domain
  rules; `cmd/ztd/main.go` only composes the CLI.
- `internal/mcpserver` is a thin stdio adapter over `app.Service`. It fixes the
  `ScopeBinding` at process start, maps `scope_denied` to `not_found` for model
  callers and enforces tool-level bounds. It contains no storage rules.

The source layer follows the same direction: `domain.Source`,
`SourceRetrieval`, `SourceItem` and `SourceReview` are vocabulary;
`app.SourceCmd` and `app.SourceReviewCmd` with `AddSource`, `ListSources` and
`RecordSourceReview` are the use cases — the service rejects `observed`
coverage there, because no trusted host adapter exists; `store/sources.go`
persists the registry and the batches. The CLI `source` commands and the
`sources` / `record_source_review` tools are adapters over those
methods, not a second implementation.

`internal/legacy` may be deleted once the migration window closes. Nothing else
depends on it.

The document layer follows the same direction: `domain.Document`,
`DocumentKind` and `DocumentStatus` are vocabulary; `app.ContextCmd`,
`DocumentCmd` and `ProjectCmd` with `AddContext`, `PutDocument` and
`AddProject` are the use cases — the service rejects unknown kinds, statuses,
relative clone paths and credentialed repository URLs there; `store/documents.go`
and `store/projects.go` persist them, with `PutDocument` idempotent by
`(scope, kind, slug)` plus the expected revision, and a draft-only guard on the
MCP path that keeps writes at `status=draft` and Expected 0 create-only. The CLI `context`, `doc` and
`project` commands and `check --bindings` are adapters over those methods, not
a second implementation. The skill workflows themselves are not ported yet:
this layer stores the records they will read.

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
scope overrides or provider tools.
`sources` returns registry state only; `record_source_review`
ingests `reported` batches and rejects `observed`, which stays reserved for a
trusted host adapter outside model-controlled arguments.
`doc_put` is the only document write: it takes `slug`, `title`, `body` and
`expected_revision`, hardcodes `kind=knowledge` and `status=draft` under the
fixed binding, and the store refuses create-only overwrites and any promotion
past draft.

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
