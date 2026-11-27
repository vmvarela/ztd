# ZTD v3 Product Specification — Zig, lean core, token-efficient loop

**Date:** 2026-11-27
**Status:** Implemented. Shipped as `ztd` 0.4.0; it supersedes the Go specification, which stays readable at the `v2-go-final` tag.
**Implementation:** Zig 0.17.0, SQLite amalgamation vendored, no Zig package dependencies.
**Supersedes decision:** v2 chose Go 1.27.4; v3 reimplements the product in Zig. The Go implementation was the parity oracle during the rewrite and is now frozen at `v2-go-final`; the Markdown store stays a read-only import source.
**Language of this document:** English, matching the repository convention that product code, schemas, commands and technical docs are English while captured user content keeps its original language.

---

## 1. The big idea

ZTD turns many competing inputs into a small set of deliberate commitments, carries them through focused work, and closes the loop with review and learning. The value is not a task database; it is knowing what deserves attention now, what is unprocessed, what can wait, and **why** a decision was made.

v3 adds one product-level requirement: the whole loop must be **cheap to run with an agent**. Every feature is judged by what it costs in tokens, bytes, memory and startup, not only by what it stores.

The loop v3 must close:

```
Capture → Research → Decide → Act → Measure → Learn → Capture
                 \        |        /
                  Shared memory (one SQLite record, every stage linked)
```

v2 implemented the six boxes. v3 implements the arrows: provenance, decisions, derived measurement and knowledge write-back, with a token budget on every read.

## 2. Boundaries

### Confirmed decisions (carried from v2 unless noted)

| Area | Contract |
| --- | --- |
| Runtime | One Mac, one filesystem-local SQLite database, concurrent local CLI/MCP processes. |
| Language | **Zig 0.17.0**, no GC, arena-per-command allocation, vendored SQLite C amalgamation. |
| Connectors | **External to the product.** Host MCPs, host CLIs declared in `AGENTS.md`, or manual input. ZTD defines the ingestion contract, not provider code. The only built-in retrieval is an operator-approved local directory connector. |
| Capture away from the Mac | External source; ingest during a later source review. No live mobile connection. |
| Agent autonomy | Capture/register freely; classify only without material ambiguity; proposals for priorities; confirmation for external writes. |
| Calendar | Read-only via host; no automatic synchronizer; confirmed focus blocks remain a later stage. |
| Trust separation | One database, mandatory logical scopes. Not physical isolation. |
| Backup | `ztd snapshot` to an operator-approved directory (iCloud-synced approved 2026-11-22). Restic optional. |
| Method | ZTD as a firm guide with visible exceptions, not silent enforcement. |
| Retrieval | Structured links + FTS5. No embeddings, no vector DB, no LLM Wiki in v3. |
| Token policy | **First-class.** Compact responses by default, byte caps, metadata-first ingestion, SQL-derived measurement, index-then-card knowledge retrieval. |
| Migration | **Big-bang.** Full Zig rewrite, then one cutover. Schema preserved through 0007; v3 migrations are forward-only. No dual-write. Golden corpus is the pre-cutover acceptance test, not an incremental gate. Verified snapshot before cutover; rollback = restore snapshot + reinstall Go. |
| Knowledge store | **Consolidated into `documents`.** `knowledge_records` is dropped; its rows migrate into `documents` with a `record_kind` subtype. One prose+structured layer, linked by `links`. |

### Non-goals

- Provider connectors inside ZTD (GitHub, Jira, email, calendar APIs). The host owns them.
- An agent/LLM runtime inside ZTD. The host owns model execution.
- Multi-user collaboration, live sync, mobile apps, remote API, MCP gateway.
- Bidirectional task/event sync, automatic meeting management.
- Vector databases, embeddings, ANN, `sqlite-vec`.
- Direct Markdown editing or dual writes. Markdown is read-only import/export.
- A universal connector framework or credential handling.
- Automatic promotion of AI prose to verified knowledge.

## 3. Token economy (new, normative)

Token cost lives in three places: MCP tool schemas loaded per session, tool output volume, and repeated reads. ZTD controls the second and third; the host controls the first.

### Rules

1. **Push, not pull.** ZTD never asks the host to fetch every connector each turn. It reports what is due/unknown; the host schedules ingestion.
2. **One batch, one call.** `source review` accepts a bounded batch and returns counts, a watermark and a bounded sample of IDs. No per-item round trips.
3. **Metadata first.** Store external ID, revision, title/excerpt, URI, occurred-at, hash and a bounded provider summary. Full bodies stay at the origin and are fetched on demand.
4. **Dedupe at the boundary.** External triple `(scope, source, external_id, external_revision)` and content hash skip duplicates before the model sees them.
5. **Advisory watermark.** Reported batches expose `last_reported_cursor` / `last_reported_at` so the host can query "since last time". This is a hint, never coverage.
6. **Decision packet, not dump.** `prepare --packet` returns goal, due items, ≤3 candidates and evidence references. Never the whole inbox or history.
7. **Measure in SQL.** Counts and durations are computed in the database; the model interprets an aggregate, not a week of rows.
8. **Index then card.** Knowledge is found via FTS/links; only the requested card is read. Verified state prevents re-derivation.
9. **Byte caps are contracts.** Every compact response has a maximum serialized size, enforced by tests. `--full` is an explicit opt-in for humans/debugging.
10. **No fan-out research agent.** A loop pass must not traverse all connected MCPs and dump them into context.

### Budgets (targets, verified by benchmark)

| Response | Cap (serialized JSON) |
| --- | --- |
| `prepare --packet` | ≤ 1.5 KiB |
| `source review` compact result | ≤ 1 KiB |
| `trace ID` | ≤ 1 KiB |
| `inbox next` | ≤ 1 KiB |
| `review --derive` metrics block | ≤ 1 KiB |
| `doc search` default page | ≤ 2 KiB |

**Truncation is normative, not best-effort.** A capped response that would exceed its cap truncates in a fixed order and adds `"truncated": true` and `"omitted": N`; it never emits invalid JSON or cuts mid-string. Per response:

- `inbox next`: capture excerpt ≤280 chars; the full body is fetched by `show`/`read`, never inlined.
- `prepare --packet`: ≤3 candidates, title ≤120 chars, IDs for evidence; no bodies. The **default `prepare` (v2 full brief) is intentionally uncapped** — it is the human/debug view; hosts opt into `--packet` for the compact decision view. The ≥30% journey goal assumes the host uses `--packet`.
- `source review`: counts, watermark and at most 10 capture IDs plus a fetch hint, so a 500-item batch fits; `--full` returns the complete list.
- `trace`: first hop from each endpoint, middle summarized as `"omitted": N`; labels are never shortened. Fan-out is bounded deterministically: neighbors ordered by `(relation, to_id)` and truncated in that order, so cap−1/cap+1 fixtures are stable.
- `review --derive`: metrics only; narrative stays in the stored review, read explicitly.
- `doc search`: up to 10 hits (v2 default), snippet ≤80 chars, reduced with `truncated`/`omitted` when the 2 KiB cap binds; the card body is fetched by `doc get`.

Each cap has a boundary fixture at cap−1 and cap+1 bytes.

Journey-level token reduction is measured against the Go baseline on the same fixtures. **Goal, not gate:** ≥30% fewer total tokens for the daily plan + process + review journey, with a written waiver if the host's own overhead makes it unattainable. The eval is a fixed script: same fixture DB, same host and model, same prompts, counting every request/response token and every tool call; the baseline run is recorded in Stage 0 and both runs are stored with the build. Language choice alone does not save tokens; the protocol does.

## 4. Architecture in Zig

### Modules

```
src/main.zig       entrypoint, arg dispatch, exit codes
src/cli.zig        command table, flag parsing, JSON/text output
src/domain.zig     entities and their JSON shapes
src/store/core.zig use cases, validation, SQL, history, idempotency
src/store/store.zig SQLite binding, migrations, transactions, ID sequences
src/sqlite.zig     C wrapper over the vendored amalgamation
src/mcp.zig        JSON-RPC 2.0 stdio server, tool/prompt registry
src/docs.zig       document link graph and lint
src/install.zig    embedded asset bundles and the no-clobber publish
src/trace logic    provenance read model (in store/core.zig)
src/metrics logic  SQL-derived review measurement (in store/core.zig)
src/timeutil.zig   local dates, timezones, ISO weeks, cadence math
src/errors.zig     error families and the CLI envelope
src/json.zig       Go-compatible JSON writer and readers
```

Dependency direction: `main → cli → store/core → domain`, `store/core → store/store → sqlite`. There is no interface layer: the CLI and the MCP server call the same functions, and validation lives with the use case that owns it. The Markdown importer is not part of this binary; it runs from the `v2-go-final` Go build.

### Build and dependencies

- `build.zig` + `build.zig.zon`; pin Zig 0.17.0.
- Vendor `sqlite3.c` amalgamation with `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_JSON1`, `SQLITE_THREADSAFE=1`. Compile as C, link statically. No system SQLite dependency.
- No third-party Zig packages. JSON: `std.json`. HTTP: none. MCP: hand-written JSON-RPC over stdio (no SDK).
- Release build: `-Doptimize=ReleaseFast`, strip, LTO where stable, baseline CPU target for portability.
- One binary serves CLI and `ztd mcp`.

### SQLite durability (preserve v2 exactly)

- `PRAGMA foreign_keys = ON`
- `PRAGMA journal_mode = WAL`
- `PRAGMA busy_timeout = 5000`
- `PRAGMA synchronous = FULL`
- Every write transaction is `BEGIN IMMEDIATE`.
- Migrations tracked by `PRAGMA user_version`; each migration in its own transaction.
- Prepared-statement cache per connection; arena allocator per command/request; no long-lived allocations.

### Time handling (explicit module)

Zig std has no timezone database, DST rules or ISO-week support, and v2 relies on Go's `time` for all of them: `profiles.timezone`, local "today", `YYYY-Www` weekly periods, weekday cadences and `review_after`. `src/timeutil` owns this through libc `localtime_r`/`mktime` on the Darwin target (the product is one Mac), with a pure ISO-week calculator tested against known boundaries. DST transitions, week 52/53 and the Sunday/Monday week-start edge are fixtures in the golden corpus. No timezone library is vendored.

### MCP server

Hand-rolled JSON-RPC 2.0 over stdio implementing `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `prompts/list`, `prompts/get`, `ping`, and `notifications/cancelled`. Normative behavior:

- **Protocol version:** negotiate against the client's requested revision; pin one revision (2025-06-18 or the revision v2's SDK negotiates) and reject unknown versions in `initialize` with the supported list. No batching.
- **Notifications never get a response**, including unknown notifications; requests with unknown methods get `-32601`.
- **Cancellation:** a `notifications/cancelled` for an in-flight request aborts it and suppresses the response; a cancelled request must not leave a half-applied write (each request is one transaction).
- **Pagination:** `tools/list` and `prompts/list` return everything in one page and omit `nextCursor`; a client-sent cursor is ignored, not an error.
- **Errors:** JSON-RPC error codes for transport/protocol, the v2 error family inside `isError` tool results.

Tool names and argument shapes stay compatible with v2 where unchanged. **New capability folds into existing tools** rather than adding schemas: `doc_put` takes `record_kind`/`rationale`/`options`/`evidence`; `record_review` takes `derive`; `prepare` takes `packet`; `doc_search` takes `record_kind`. Any new capability folds into existing tools or displaces one; `trace` is the single approved new-tool exception.

**`tools/list` budget (re-baselined).** The payload must not grow over the **measured v2 baseline**, which Stage 0 pins. A dev build of repo main measures ~31 KiB (17 default tools; `delete_source` is opt-in behind `--allow-delete-source`), dominated by `outputSchema`, not descriptions (`prepare` alone ~5.3 KiB, of which ~4.8 KiB is `outputSchema`). The earlier 12 KiB aspiration is **dropped as unsatisfiable** without a breaking change. Omitting `outputSchema` from `tools/list` would shrink it dramatically but is a host-visible breaking change and is explicitly out of scope unless separately approved. The corpus and baseline pin the exposure configuration (default 17 vs 18 registered + `trace` = 19). No MCP SDK dependency. The server is a thin adapter over `app`; it contains no business logic.

## 5. Data model

### Existing schema (preserved verbatim, migrations 0001–0007)

`scopes`, `profiles`, `profile_scopes`, `contexts`, `areas`, `projects`, `captures`, `work_items`, `plans`, `plan_items`, `routines`, `knowledge_records` (dropped by 0010), `daily_limit_overrides`, `calendar_review_assertions`, `history_events`, `idempotency_records`, `import_runs`, `legacy_records`, `focus_sessions`, `checkpoints`, `reviews`, `goals`, `sources`, `source_reviews`, `documents`, `documents_fts` (FTS5), plus `work_items.custom_fields`, `projects.repo_url`, `projects.clone_path`.

The SQL migrations are language-agnostic and run unchanged in Zig. Existing databases open without conversion.

**Migration runner format (extended for v3).** v2's runner executes one plain `.sql` file per migration and bumps `user_version`; it has no place for branching assertions. The v3 runner extends the format: a migration may declare SQL **plus bounded post-step assertions keyed by migration id** (row counts, field non-null checks, `PRAGMA foreign_key_check` returning no rows, FTS consistency, collision pre-checks that abort with an explicit list). 0001–0007 remain plain files; 0009/0010 use the extended form. Assertions run inside the migration transaction and roll back on failure.

### New migrations (v3)

**0008 — provenance on captures and sources**

```sql
ALTER TABLE captures ADD COLUMN source_review_id TEXT REFERENCES source_reviews(id);
ALTER TABLE captures ADD COLUMN batch_id TEXT;
ALTER TABLE captures ADD COLUMN provider_metadata TEXT NOT NULL DEFAULT '{}';
ALTER TABLE sources ADD COLUMN reported_cursor TEXT NOT NULL DEFAULT '';
ALTER TABLE sources ADD COLUMN last_reported_at TEXT;
```

`provider_metadata` is a bounded JSON summary (≤2 KiB), not a raw payload. `reported_cursor`/`last_reported_at` are advisory; the trusted `cursor` still moves only on `observed`.

**0009 — connector enum rebuild**

SQLite cannot alter a CHECK constraint in place. Rebuild `sources` with `connector IN ('manual','directory','host_mcp','host_cli')`, preserving rows and indexes. `host_cli` represents a CLI declared in the host's `AGENTS.md`; it is still `reported` unless a trusted adapter attests otherwise.

**Ordering and FK safety (mandatory).** `source_reviews.source_id` references `sources(id)`, so `DROP TABLE sources` with `foreign_keys=ON` fails as soon as one review exists. `PRAGMA foreign_keys=OFF` is a no-op inside a transaction. Therefore 0009 starts with `PRAGMA defer_foreign_keys = ON` (valid inside the transaction), **stages the existing rows into a temp backup table before any DROP**, drops `sources`, recreates it with the **full post-0008 column set** including `reported_cursor` and `last_reported_at`, copies the staged rows back, recreates indexes, drops the temp table, and ends by asserting `PRAGMA foreign_key_check` returns no rows. The migration runner aborts and rolls back on any violation. (The drop/recreate-same-name pattern with deferred FKs is verified sound against SQLite; the staging step is what preserves the rows.)

**0010 — knowledge consolidation and links**

`documents` becomes the single knowledge layer. Add nullable structured columns (no table rebuild needed):

```sql
ALTER TABLE documents ADD COLUMN record_kind TEXT
    CHECK (record_kind IS NULL OR record_kind IN ('fact','decision','constraint','procedure','reference'));
ALTER TABLE documents ADD COLUMN rationale TEXT;
ALTER TABLE documents ADD COLUMN options_json TEXT;
ALTER TABLE documents ADD COLUMN approved_by TEXT;
ALTER TABLE documents ADD COLUMN approved_at TEXT;
ALTER TABLE documents ADD COLUMN valid_from TEXT;
ALTER TABLE documents ADD COLUMN source_refs TEXT NOT NULL DEFAULT '[]';
ALTER TABLE documents ADD COLUMN supersedes_id TEXT REFERENCES documents(id);
```

**Row mapping (normative — nothing is lost).**

| `knowledge_records` | `documents` |
| --- | --- |
| `id` | `id` (same value, so `supersedes_id` and links stay valid) |
| `scope_id` | `scope_id` |
| `kind` | `record_kind`; document `kind='knowledge'` |
| `text` | `body` |
| — | `title`: first non-empty line with Markdown heading markers stripped, trimmed to 80 chars; fallback `id` |
| — | `slug`: `kr/<id>` (namespaced, cannot collide with legacy importer slugs) |
| `state` + `review_state` | `status` per truth table below |
| `source_refs` | `source_refs` |
| `valid_from` | `valid_from` |
| `reviewed_at` | `approved_at` (`approved_by` stays NULL: unknown) |
| `supersedes_id` | `supersedes_id` |
| `revision` | `revision` |
| `created_at` | `created_at` |
| — | `updated_at = COALESCE(reviewed_at, created_at)` |

Status truth table: `state='superseded'` → `superseded` regardless of review state; otherwise `review_state='verified'` → `verified`; otherwise `draft`. (A superseded verified row stays superseded.)

**Ordering and FK safety.** 0010 starts with `PRAGMA defer_foreign_keys = ON`: `supersedes_id` is self-referential, so rows can arrive in any order, and the constraint is checked at commit. It ends with `PRAGMA foreign_key_check` returning no rows.

**Guards.** Before mutating, 0010 fails with an explicit list if a migrated `id` already exists in `documents` or if any `documents(scope_id,'knowledge','kr/<id>')` slug already exists. After the insert it asserts migrated row count equals the pre-migration `knowledge_records` count and that no migrated row has NULL `title`/`body`/`updated_at`. `documents_fts` is maintained by the 0007 triggers, so no manual rebuild; the migration asserts the FTS row count for migrated IDs matches. Only then `DROP TABLE knowledge_records`. The Zig legacy importer writes `documents` directly; it never recreates `knowledge_records`.

Generic provenance edges:

```sql
CREATE TABLE links (
    from_type TEXT NOT NULL,
    from_id   TEXT NOT NULL,
    to_type   TEXT NOT NULL,
    to_id     TEXT NOT NULL,
    relation  TEXT NOT NULL CHECK (relation IN ('evidence','decided','produced','reviewed','learned','supersedes','measured')),
    scope_id  TEXT NOT NULL REFERENCES scopes(id),
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_type, from_id, to_type, to_id, relation)
);
CREATE INDEX links_to ON links(to_type, to_id);
```

Existing 1:1 FKs (`work_items.origin_capture_id`, `focus_sessions.work_item_id`, `plan_items`) remain; `links` carries the n:m edges the loop needs. `from_type`/`to_type` are validated in `app` against the entity list rather than a fragile CHECK (entity kinds grow). Deletion removes an entity's links in the same transaction; `trace` ignores dangling rows and `check` reports any it finds.

**0011 — derived review metrics**

```sql
ALTER TABLE reviews ADD COLUMN metrics_json TEXT NOT NULL DEFAULT '{}';
```

Metrics are computed, not asserted: `mit_planned`, `mit_completed`, `plan_items`, `completed_items`, `captures_received`, `captures_processed`, `focus_sessions`, `focus_minutes`, `overdue_routines`. Human `outcomes`/`coverage` text remains required.

**0012 — excerpt-first source items**

```sql
ALTER TABLE captures ADD COLUMN body_ref TEXT;
```

`original_text` may be a bounded excerpt; `body_ref` points at the origin. `MaxSourceItemBytes` stays 64 KiB; `MaxSourceBatchItems` stays 500.

**Export format (breaking, versioned).** The canonical table list changes: `knowledge_records` leaves, `links` enters, and the new `documents`/`captures`/`sources` columns flow through automatically. `ztd export` writes `format: "ztd-export", version: 2`. `restore` accepts version 1 by routing `knowledge_records` rows through the 0010 mapping and rejecting duplicate `kr/<id>` slugs before writing; it rejects version 2 on a v2 binary with a clear message. **v1 table-presence exception:** v2's restore rejects any missing canonical table and any unknown table. For `version: 1` only, `links` may be absent (defaults empty) and `knowledge_records` is accepted and routed through the 0010 mapping; every other table keeps the strict both-ways check. `snapshot` is a raw SQLite copy and is unaffected. A v2 binary cannot restore a v3 export; that is expected and documented.

### Knowledge store decision (confirmed)

One layer: `documents`. Prose cards and structured records share the table; `record_kind` distinguishes `fact`, `decision`, `constraint`, `procedure`, `reference` within `kind='knowledge'`. `knowledge_records` is dropped after its rows are migrated. Decisions are documents with `record_kind='decision'` plus `rationale`, `options_json`, `approved_by`, `approved_at`, `source_refs`, `supersedes_id`. The `links` table carries provenance edges to captures, work items, plans, reviews and other documents. This removes the orphaned v2 table and the dual-store ambiguity at the cost of a one-time consolidation migration.

## 6. Feature inventory

### Existing features (must reach parity)

| Area | CLI | MCP tool | Notes |
| --- | --- | --- | --- |
| Identity/config | `init`, `scope add/list`, `install opencode/templates` | — | Scopes: personal/work/client/opensource. Profiles own scopes. |
| Capture | `capture`, `inbox next` | `capture`, `inbox_next` | Pending/processed/discarded/deferred; deferred requires `review_after`. |
| Process | `process --outcome K` | `process_capture` | Outcomes: `work_items` (requires titles), `reference` (free-text `--reason` pointer to a card), `immediate` (requires `--evidence`), `discard` (requires `--reason`), `defer` (requires `--review-after`); human gate for ambiguity. |
| Work items | `show`, `find`, `list`, `move` | `find`, `read` | Lifecycles next/waiting/someday/archive; closure kinds; optimistic revision. |
| Goal | `goal set/show/complete/cancel` | — | One active primary goal per profile. |
| Plan | `prepare`, `plan`, `plan commit` | `prepare`, `commit_plan` | Daily/weekly; MIT/big_rock/batch; 1–3 MITs; commit requires human approval. |
| Focus | `focus start/checkpoint/finish` | `focus_start`, `checkpoint`, `focus_finish` | One open focus per actor; checkpoints carry evidence/uncertainty/next action. |
| Review | `review daily/weekly/monthly/yearly` | `record_review` | One per profile/kind/period; outcomes+coverage required. |
| Routines | `routines due/done/add`, `due`, `routine` | — | Cadence daily/weekly; due reporting. |
| Sources | `source add/apply/list/review/delete` | `sources`, `record_source_review`, `delete_source` | Registry + reported batches; `observed` rejected without trusted adapter. |
| Contexts | `context add/list` | — | Scope-owned. |
| Documents | `doc put/get/list/search/related/log/lint/archive` | `doc_search`, `doc_get`, `doc_related`, `doc_put` | FTS5; wikilink/Markdown link graph; MCP `doc_put` is draft-only. |
| Projects | `project add/list/show` | — | Desired outcome, status, repo_url, clone_path. |
| Migration | `migrate import/verify/documents` | — | Read-only legacy copy; mapping file; quarantine. |
| Durability | `export`, `restore`, `snapshot`, `check`, `recover` | — | `check --bindings` validates `.ztd.json`; `recover` is a compatibility no-op. |
| Environment | `status`, `version`, `mcp` | — | DB resolution `--db` > `ZTD_DB` > `~/.ztd/ztd.db`. |
| MCP prompts | — | Collect, Process, Plan, Do, Review, Simplify, Routines, Passion | Method prompts. |

Scope binding precedence: `--scope` > `ZTD_SCOPES` > `.ztd.json` hint > profile scopes minus `client:*`/`work`. Source config: `--file` > `ZTD_SOURCES` > `~/.ztd/sources.json`.

Integrations: OpenCode skills (`ztd`, `ztd-collect`, `ztd-do`, `ztd-knowledge`, `ztd-plan`, `ztd-process`, `ztd-repo`, `ztd-review`, `ztd-simplify`, `ztd-trusted-system`) and method templates (`day`, `week`, `review`, `journal`, `project`, `knowledge`). These are host-side; v3 keeps them working against the same CLI/MCP contract.

**Parity matrix is generated, not hand-written.** Stage 0 derives the command/flag matrix from the Go binary's help output and the MCP schemas, and freezes it into the corpus plan. The table above is orientation, not coverage. Flags that must appear in the matrix: `plan commit --override`, `capture --stdin`, `find/list --context/--project`, `doc search --limit` (max 50), `doc log --limit` (max 500), `doc lint --strict`, and the MCP defaults (`find` 8/20, `read` ≤5, `doc_put` derived idempotency key, 512 KiB body limit).

**v2 quirks resolved in v3 (no dead schema).**

- `daily_limit_overrides` gains its writer: `override add --rule mit|focus --date YYYY-MM-DD --reason R [--actor A]`. `plan commit --override ID` requires a matching `rule='mit'` row for the actor and local date (narrowed to that id when supplied) and returns a validation error if absent; the row is not consumed.
- `calendar_review_assertions` gains writer and reader: `review daily --calendar-assert S` records the row; `check` warns when a daily review for the local date exists without an assertion. A review never fails for a missing assertion.

### New features (v3)

#### A. Provenance edges (the arrows)

- `captures.source_review_id`, `batch_id`, `provider_metadata` persist the batch that produced a capture.
- `links` table connects source review → capture → decision → work item/plan → focus/checkpoint → review → knowledge.
- `trace ID` (CLI) / `trace` (MCP): read-only compact chain for any entity. Returns IDs, relations and short labels; never bodies. Cap ≤1 KiB.
- `doc related` extended to follow `links` to non-document entities, still compact.

#### B. Decisions as first-class records

- `doc put --kind knowledge --record-kind decision --slug S --body T [--rationale R] [--options JSON] [--evidence ID...] [--scope S]` creates a draft decision linked to evidence.
- Human verification uses the existing `doc put --status verified --expected N` gate, extended with `--approved-by A` to record `approved_by`/`approved_at`. MCP `doc_put` stays draft-only and never verifies.
- `doc supersede OLD NEW` marks supersession (`supersedes_id`) and links it.
- A decision may link to the work item/plan it produced (`produced`). `process` and `plan commit` accept an optional `--decision ID` to record the edge.
- `doc search --record-kind decision` reuses FTS over `documents.body`; no new search engine.

#### C. Derived measurement

- `review daily|weekly|monthly|yearly --derive` computes `metrics_json` from plans, work items, captures, focus sessions and routines for the period, then stores the human outcomes/coverage alongside.
- `review show --period P` returns the metrics block compactly.
- Metrics link to goal/project via `links` with relation `measured` (review → goal/project) when the review references them; no free-text-only outcomes.

#### D. Learning write-back

- `learn propose --review ID` creates draft knowledge cards/records linked to the review and its evidence (`learned`). Draft-only. **`learn propose` is CLI-only**; over MCP the host runs the CLI command. `doc_put`'s `evidence` fold uses relation `evidence`, not `learned`, so it approximates but does not replace the `learned` edge until a later fold.
- Human `doc put --status verified --approved-by A` (CLI) promotes. MCP stays draft-only.
- Verified knowledge is never re-derived automatically; supersession is explicit.
- Method templates and skills remain host-side; v3 does not port skill workflows into the binary.

#### E. Token-efficient ingestion

- `source review` compact result by default: `{review_id, source_id, batch_id, created, deduped, captures:[≤10 ids], omitted, watermark, truncated}`. `--full` opt-in returns the complete ID list and retrieval detail.
- `sources` / `source list` expose `reported_cursor` and `last_reported_at` as advisory hints.
- `prepare --packet` returns the decision packet (goal, due, ≤3 candidates, evidence refs) under cap.
- Source items may carry an excerpt + `body_ref`; full body stays at origin.
- Built-in **directory connector** (`connector=directory`) is the only `observed` retrieval: operator-approved roots, no traversal outside roots, no network. Roots are absolute paths stored in `sources.connection_ref` and approved through `source add` (CLI only, never MCP). Symlinks are resolved before the containment check; a root that resolves outside itself is rejected. A *complete window* means the recursive listing finished with no read errors and every item's mtime/size were captured; only then does the trusted `cursor` advance, and any error keeps it unchanged. Overlapping roots dedupe by resolved `(device, inode, path)` plus content hash. Everything else is `reported`.
- `host_cli` connector kind for host-declared CLIs; still `reported`.

#### F. Refactor / optimization

- Single validation module in `app`; `store` calls it instead of mirroring checks.
- Generic history + idempotency helpers; no per-entity duplication.
- Comptime CLI command table replaces per-command flag boilerplate.
- Arena-per-command allocation; prepared-statement cache; no reflection.
- Target store+app ≤9k production LOC, total ≤12k with waiver (Go baseline ~14k prod / ~26.5k total). Tests are ported or replaced by golden parity, never deleted to hit a number.

## 7. Contracts

### Error taxonomy (preserve)

`Invalid`, `NotFound`, `ScopeDenied`, `IOError`, conflict/revision errors. CLI exit codes are 0/1/2 as in v2, with the error family in the JSON envelope. Preserve the v2 behavior where a failing read still carries data (`doc lint --json` keeps its findings on a non-zero exit); losing it would break golden outputs and host skills.

### Invariants (preserve)

- One open focus per actor; one active primary goal per profile; one plan per profile/kind/period; one review per profile/kind/period.
- `waiting` requires `waiting_on`; `archived` requires `closed_at` + `resolution`.
- `deferred` capture requires `review_after`.
- Optimistic concurrency via `revision` / `--expected N`.
- Idempotency via `(command, idempotency_key, request_hash)`; replay returns the stored result. **`request_hash` is byte-identical to v2:** `sha256` over Go-style canonical JSON of the request struct (fields in declaration order, HTML-escaping of `<`, `>`, `&`). Zig implements a canonical marshaller for hashed payloads so a retry issued after cutover with a pre-cutover key still replays instead of erroring on `storedHash != hash`. Where v2 already keeps a legacy hash path (`captureHashVersion` / `legacyHash` for captures), v3 preserves it. The corpus pins a pre-cutover idempotency row and asserts replay; DB diffs normalize `request_hash` only when the canonical bytes are proven equal.
- Append-only `history_events` for every mutation.
- Scope enforcement on every read/write; a scoped agent cannot cross scopes.

### Trust and approval

- `observed` coverage requires a trusted adapter (built-in directory connector). Host MCP/CLI batches are `reported`, never verified coverage.
- Class C/D actions (external writes, commitments) require a real human approval boundary. MCP `commit_plan`, `doc put --status verified` promotion and external writes are gated by the host; ZTD records the approval provenance (`approved_by`, `approved_at`) but does not invent a roles framework.
- A model-supplied `confirmed: true` is not proof of approval.

## 8. CLI / MCP surface changes

Additive only; existing commands keep their flags and JSON shape unless a compact default is introduced with `--full` escape.

New CLI: `trace`, `override add`, `doc supersede`, `learn propose`, `review --derive`, `review --calendar-assert`, `review show`, `prepare --packet`, `source review --full`. Extended `doc put`: `--record-kind`, `--rationale`, `--options`, `--evidence`, `--approved-by`. Extended `doc search`: `--record-kind`.
New MCP: `trace` only. `record_review` gains `derive`; `prepare` gains `packet`; `doc_put` gains `record_kind`/`rationale`/`options`/`evidence` and remains draft-only; `doc_search` gains a `record_kind` filter. No `record_decision`, `review_derive` or `prepare_packet` tools: those are argument shapes, not schemas. `delete_source` remains behind `--allow-delete-source`.

Byte caps in §3 are tested on the serialized JSON of every compact response.

## 9. Migration and cutover (big-bang, confirmed)

One rewrite, one cutover. No dual-write, no incremental parity gates. The golden corpus is the acceptance test run **before** cutover; if it fails, cutover does not happen. The §12 stages are delivery order inside that single rewrite, not separate releases; a Stage-1 corpus run is partial by design and only the final run is the gate.

1. **Baseline + golden corpus.** Measure Go binary size, RSS, startup, DB size, token usage and `tools/list` bytes on a fixed fixture corpus. Capture golden JSON outputs for every command and MCP tool, plus DB dumps after each journey. This corpus is the contract the Zig build must satisfy.
2. **Full Zig rewrite.** Build system, vendored SQLite, migration runner, CLI, app/domain/store, MCP server, legacy importer, directory connector, time module. All existing features plus v3 features (migrations 0008–0012, edges, decisions, metrics, learn, token caps) land in the same rewrite. Go is frozen immediately.
3. **Acceptance.** Run the full golden corpus against Zig: JSON diffs, DB diffs, MCP handshake/tool parity, legacy import parity, `check`/`migrate verify`. Every difference is either a bug or an intentional, documented v3 change. No silent drift.
4. **Optimization pass.** Benchmarks against §10 targets; refactor until gates pass.
5. **Cutover checklist.** (a) `ztd snapshot` to an approved directory; (b) restore it into a staging DB and run `ztd check` + `migrate verify`; (c) install the Zig binary **in place at the same absolute path** the hosts already reference; (d) restart the hosts so MCP registrations reload; (e) apply migrations 0008–0012; (f) update README/docs to v3 and keep Go 0.3.0 installable as a frozen tag.
6. **Rollback.** Migrations are forward-only; Go cannot open a migrated database. Rollback = restore the pre-cutover snapshot + reinstall Go 0.3.0 **at the same path** + restart hosts. The snapshot is mandatory, not optional.

**Golden corpus coverage (normative).** The generated matrix comes from the Go binary, so it cannot contain the v3-only surface. **The matrix is extended with the hand-listed v3 additions (§8)** — `trace`, `override add`, `learn propose`, `review show`, `review --derive`, `review --calendar-assert`, `prepare --packet`, `source review --full`, `doc put --record-kind/--rationale/--options/--evidence/--approved-by`, `doc search --record-kind`, and the directory-connector `observed` path — with their compact/`--full` variants and error paths, reviewed like the corpus itself. These have no Go oracle; their goldens are authored from the spec and asserted directly. A run is credible only if it covers:

- every command and flag in the generated **and extended** matrix, each in JSON and text, for success **and** error paths (`Invalid`, `NotFound`, `ScopeDenied`, revision conflict);
- idempotent replay (same key/request returns the stored result) and stale `--expected` rejection;
- all five `process` outcomes, including `reference` and `immediate`;
- MCP tools and 8 prompts: handshake/version negotiation, notifications, cancellation, unknown method, error results. Tool count is pinned by exposure config: 17 default (`delete_source` opt-in behind `--allow-delete-source`), 18 registered, +`trace` = 19; the Stage-0 baseline and corpus state which config they measure;
- full journeys: capture→process→plan→focus→review; knowledge draft→verify→supersede; source reported batch→review→capture; legacy import including quarantine cases; **directory connector** (clean complete window → trusted cursor advances; read error → cursor unchanged; symlink escaping root rejected);
- a **pre-cutover idempotency row** replayed after cutover (byte-identical `request_hash`, §7);
- export/restore roundtrip (v1→v3 and v3→v3) and snapshot/restore;
- migrations 0001–0012 on a fresh DB and on a v2 DB with source reviews and knowledge rows;
- a concurrent CLI+MCP writer case (busy timeout, no lost update);
- timezone/DST and ISO-week boundaries.

Diffs normalize generated IDs, timestamps and ordering. **Legacy import parity is modulo 0010:** Go writes `knowledge_records`, Zig writes `documents`, so the diff tool maps `knowledge_records` rows to their `kr/<id>` document equivalents before comparing; a raw table diff is not the goal.

Schema compatibility: existing `~/.ztd/ztd.db` opens unchanged up to 0007; 0008+ apply forward only at cutover. Export/restore is versioned (§5); snapshot is a raw copy. The consolidation migration (0010) must preserve every `knowledge_records` row in `documents` and keep `documents_fts` consistent; `migrate verify` and `check` gate it.

## 10. Optimization targets and measurement

Targets are goals to verify, not claims. Baseline measured first.

| Metric | Go baseline | v3 target | Method |
| --- | --- | --- | --- |
| Binary size | 12.2 MB (Homebrew 0.3.0) | ≤ 3.0 MB stripped | `ls -l`, strip + LTO |
| RSS (`status`, `prepare`) | measure | ≤ 12 MB | `/usr/bin/time -l`, repeated runs |
| Startup to first output | measure | ≤ 8 ms | hyperfine, cold/warm |
| Production LOC | ~14,026 | store+app ≤ 9,000; total ≤ 12,000 | `wc -l`, excluding tests; waiver above 12k with rationale |
| DB size after journeys | measure | ±5% | `sqlite3 .db 'PRAGMA page_count*page_size'` |
| Compact response bytes | n/a | caps in §3 | test assertions |
| `tools/list` bytes | measure in Stage 0 (~31 KiB dev build, default 17 tools) | no growth over measured v2 baseline; 12 KiB aspiration dropped | serialized `tools/list` response, pinned exposure config |
| Journey tokens | measure on fixtures | goal ≥30% reduction, waiver allowed | fixed eval script, actual tokens/calls |

Binary size, RSS and startup are plausible for a static SQLite-linked ReleaseFast binary; **LOC is the least certain target** and the store is the reason (Go leans on `database/sql`; Zig has no equivalent and no std regexp). LOC is never met by deleting validation, error handling or tests. Durability is never traded for speed: `synchronous=FULL`, WAL, `BEGIN IMMEDIATE` stay. No `mmap` tricks that risk corruption. Benchmarks run on the same machine and fixtures as baseline.

## 11. Verification and acceptance gates

- All Go behavior covered by the golden corpus; no silent behavior drift.
- `ztd check` and `check --bindings` pass on migrated and fresh databases.
- `migrate verify` passes on the legacy copy; quarantine preserved.
- Migrations 0001–0012 apply cleanly on fresh and existing DBs; `user_version` correct; `PRAGMA foreign_key_check` empty after 0009/0010.
- 0010 preserves every `knowledge_records` row (count + field assertions) and `documents_fts` matches `documents`.
- Export/restore roundtrips: v1→v3 mapped, v3→v3 native.
- Byte-cap and truncation-boundary tests fail the build on regression; `tools/list` does not grow over the measured v2 baseline (pinned exposure config).
- Benchmark gates in §10 met or explicitly waived with rationale.
- Token eval reports actual tokens, calls, latency and corrections; the ≥30% reduction is a goal with a written waiver, not a silent pass.
- MCP handshake/notification/cancellation/version tests pass; `observed` still rejected for host batches.
- The binary makes no network calls; directory connector stays within approved roots and resolves symlinks before the containment check.

## 12. Delivery history (big-bang)

- **Stage 0:** baseline measurement + golden corpus + Zig build spike (SQLite C + FTS5 + JSON-RPC echo).
- **Stage 1:** Zig rewrite of core + CLI + store + time module + `install`; corpus run green.
- **Stage 2:** MCP server (18 tools, 8 prompts) + directory connector + `host_cli` kind.
- **Stage 3:** v3 features: migrations 0008–0012, edges, decisions, metrics, learn, token caps.
- **Stage 4:** acceptance run of the full corpus, including the v3 additions.
- **Stage 5:** optimization pass + benchmarks (results in `docs/benchmarks/baseline.md`).
- **Stage 6:** snapshot + cutover + docs; Go frozen at `v2-go-final`; 0.4.0 released for the twelve build targets.
- **Later (not v3):** calendar focus blocks, external connectors beyond directory, LLM Wiki, TUI, a Zig port of the Markdown importer.

## 13. Decisions and remaining risks

### Resolved and implemented (2026-11-27)

1. **Migration strategy: big-bang.** Full rewrite, one cutover. Mitigation: a defined golden corpus is the hard pre-cutover acceptance gate, plus a verified snapshot for rollback.
2. **Knowledge store: consolidate into `documents`.** `knowledge_records` dropped after a field-complete migration; `record_kind` subtype avoids a CHECK rebuild. Mitigation: normative row mapping, collision pre-check, count/FTS assertions.
3. **Toolchain: Zig 0.17.0 pinned.** Installed at `/Users/victor/bin/zig`. Mitigation: pin exactly, vendor the build, isolate std usage behind small wrappers so a future version bump is localized.
4. **Export format breaks.** Version 2 with `links`; restore handles v1 by mapping. Documented, not silent.
5. **Dead v2 schema revived.** `daily_limit_overrides` and `calendar_review_assertions` get writer and reader (`override add`, `review daily --calendar-assert`).
6. **LOC target rescoped.** Store+app ≤9k, total ≤12k with waiver; correctness and validation are never cut to hit it.

### Remaining risks

7. **Big-bang drift.** The golden corpus is the only safety net; its coverage is the real risk, not the language. §9's coverage list is the minimum, and the corpus itself must be reviewed like code.
8. **Rollback is restore-only.** Forward-only migrations mean Go cannot open a migrated DB. The pre-cutover snapshot (verified in staging) is the only rollback path; losing it loses rollback.
9. **Host re-pointing.** Hosts register the MCP binary by absolute path; the swap must happen in place or the host keeps running Go. Restart hosts after cutover.
10. **Token savings are protocol-driven.** MCP schemas are the largest per-session cost and the host controls loading them. `tools/list` is capped and new capability folds into existing tools, but a host that dumps full bodies will defeat the target.
11. **MCP hand-rolled compliance.** Without an SDK, notifications, cancellation, version negotiation and error shapes need explicit tests against the Go SDK client.
12. **Time correctness.** Timezone/DST and ISO weeks are new code with no std support; boundary fixtures are mandatory.
13. **Zig std churn.** 0.17.0 may be a development line; a mid-migration stable release could force rework. Wrapper isolation limits the blast radius.
14. **Spec location.** This file lives in the plan directory. On approval, move to `docs/spec.md` (v3) and update README/architecture.
