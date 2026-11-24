# A smaller ZTD model

Design proposal based on commit `88275c198933d8b68fe85ecbb06a6d3ad6375eaa`.
This document specifies a target model, not an implemented schema migration.

## Product boundary

ZTD remembers what one person has collected, committed to, learned and left
unfinished. The daily loop is capture, clarify, choose, do and review.
SQLite remains the authority; CLI and MCP call the same application service.
External services remain authoritative for their tickets, messages and calendars.

## Findings in the current implementation

- `internal/store/migrations/0001_core.sql` defines profiles, profile membership,
  areas, knowledge records, calendar assertions and limit overrides in addition
  to tasks. The application describes one user and one planning view.
- `0006_documents.sql` adds eleven document kinds, including plans, reviews and
  routines, which also have dedicated tables. Narrative and operational state
  have no explicit linking contract.
- `internal/store/core.go` processes a reference by storing an outcome kind;
  it does not create a document or persist a document foreign key. Full outcome
  details survive in history, but normal capture reads only reconstruct the kind.
  `ztd-process/SKILL.md` consequently describes two non-atomic writes and putting
  a document ID in the reason string.
- `ztd-plan/SKILL.md` says weekly plans and structured reviews lack direct read
  commands. Its fallback is asking the user or reading review documents.
- `ztd-process/SKILL.md` describes captures as scope-free; `Store.Capture`
  assigns the first bound scope. The vocabulary is inconsistent.
- `CalendarReviewAssertion` is defined and its table exported, but there is no
  application workflow for it. MIT overrides are read by planning, with test
  fixtures inserting rows directly. These are not a useful daily interface.
- `sources` anticipates connectors, cursors and authentication state even though
  no provider connector runs. Reported batch ingestion does exist and must survive.

The problem is overlapping concepts and incomplete workflows, not SQLite or Go.
Reducing file length alone would not resolve it.

## Functional model

| Action | Result |
| --- | --- |
| Capture | Save original text in a scope's inbox without requiring project or context |
| Clarify | Create one or more tasks, save a reference, record an immediate result, discard, or defer |
| Choose | Select existing tasks for a day or week; never copy their state |
| Do | Work on one task; optionally start focus; record progress or close the task |
| Review | Read the period's plan and outcomes, record reflection, adjust commitments explicitly |

Captures and tasks remain separate. A capture can produce several tasks or no
task. Processing must atomically save its decision and its resulting records.
An immediate action remains a capture outcome with evidence; no artificial task
is necessary. Deferring a capture means postponing clarification; `someday`
means an already clarified task that is not a current commitment.

## Canonical records

Fields below are domain fields. Mutable records also have `revision`,
`created_at` and `updated_at`; append-only entries have an ID and timestamp.
Foreign keys and scope validation apply to all relationships.

| Record | Fields and responsibility |
| --- | --- |
| Scope | `id, name, kind`: personal/open-source/work/client visibility boundary |
| Capture | `id, scope_id, text, source_id?, external_id?, external_revision?, source_uri?, occurred_at?, state, defer_until?, outcome?, reason?, evidence?, document_id?` |
| Task | `id, scope_id, project_id?, context_id?, capture_id?, title, status, waiting_on?, due_at?, closed_at?, resolution?` |
| Project | `id, scope_id, title, desired_outcome, status, repo_url?, clone_path?` |
| Context | `id, scope_id, name`: optional task filter, not another ownership hierarchy |
| Plan | `id, kind, period, exception_reason?`: one saved selection per day/week |
| Plan item | `plan_id, task_id, position`: a reference, never copied task text or status |
| Document | `id, scope_id, slug, title, body, status, project_id?, purpose?, period?`: all reference material and written reviews |
| Checkpoint | `id, task_id, result, evidence, next_action, uncertainties`: append-only continuity |
| Routine | `id, scope_id, title, cadence, last_completed_at?, active`: recurring maintenance |
| Goal | `id, scope_id, statement, start_on, end_on?, status`: at most one active goal in the store |

This is not a promise of eleven physical tables. Supporting tables for focus,
sources, provenance, retries, history and migration still have distinct jobs.

Task statuses are `next`, `waiting`, `someday`, `completed`, `cancelled`.
Archive is a view over closed tasks, not an additional state combined with a
second closure enum. Imported closures with unknown meaning retain an explicit
legacy `closed_unknown` value until classified; never guess they were completed.
Waiting requires a dependency. Closed tasks require a closure timestamp and
resolution. Reopening explicitly clears closure fields.

Capture states remain `pending`, `deferred`, `processed`, `discarded`.
Keep the outcome and evidence as readable fields, not only history payloads.
Tasks point to their origin capture; reference outcomes point to their document.
Creating/updating a reference and processing its capture share a transaction,
revision check and idempotency key. Both scopes must be allowed if the destination
differs; cross-scope links must not reveal inaccessible document metadata.

## Remove overlapping representations

| Current concept | Target |
| --- | --- |
| Profile + profile scopes | Store settings for owner/timezone; declared scopes plus a runtime allowed-scope binding |
| Area | Optional context classification; retain the old value in migration provenance if ambiguous |
| Knowledge record + knowledge document | One document representation; preserve old IDs, verification, provenance and supersession links during conversion |
| Daily/weekly plan documents | Historical narrative documents; operational selection exists only in Plan + Plan item |
| Review rows + review documents | Scoped documents with `purpose=review` and a period; no second mutable review representation |
| Routine documents | Supporting reference text only; cadence and completion live in Routine |
| Eleven mandatory document kinds | Optional purpose such as review/journal/reference; identity is `(scope, slug)` |
| Knowledge indexes | Optional documents; search works without maintaining an index |
| MIT / big-rock / batch roles | Ordered daily priorities or weekly priorities; routine tasks stay in ordinary lists |
| Plan open/committed states | Proposals stay in the conversation; a saved plan is the selected plan |
| Daily limit override rows | Explicit exception reason on the plan, written with it |
| Calendar assertions | Review text describing what was actually checked |
| Goal primary/subgoal hierarchy | One active scoped goal; projects and tasks supply the next concrete steps |

Daily planning recommends 1–3 priorities. Saving more requires an explicit
exception reason; an empty plan is valid for a day off. The plan is global,
but task content is filtered by the fixed binding. Partial views cannot replace
hidden plan items: a scoped edit patches visible memberships and preserves the
others. A full replacement requires access to all affected scopes. Limits count
the entire plan without disclosing hidden task content. Scope-owned review
documents cannot silently contain a combined report of other clients.

## Supporting state stays small

- Settings: a singleton owner and IANA timezone; local dates are computed from
  that timezone, while instants remain UTC. No configurable profile graph.
- Focus: optional session records with one open session in the store. A task
  need not have a timer. Checkpoints work without a focus session.
- Sources: scoped configuration plus append-only reported batches. Keep external
  identity deduplication, batch IDs and honest coverage reporting. Derive latest
  coverage from batches; reserve connector-specific cursors and authentication
  state for an actual connector implementation. Do not erase existing provenance.
- History and idempotency remain technical tables. They solve concurrent agent
  retries and explain changes; they are not additional user concepts.
- Legacy custom fields are preserved as migration metadata, not silently dropped
  or promoted into an extensible business schema. Existing due dates and external
  references require explicit mappings.

Scope bindings remain fixed by the host for MCP sessions. Project/context filters
only narrow them. Removing profiles must never remove authorization checks.
Default personal views continue to exclude work/client scopes; explicit host
selection enables those scopes. A local routing hint is not an authorization grant.

## Interface contract

The proposed surface uses task terminology consistently, regardless of existing
internal names. This is a target contract, not commands available today.

- `capture`, `inbox`, `process`: collect and clarify.
- `task list|show|update|done|cancel`: read and change canonical tasks, including
  project/context and explicit clearing of optional fields.
- `plan show|set`: both daily and weekly, with the same read/write contract.
- `prepare`: a composed read of goal, priorities, next tasks and last checkpoints.
- `checkpoint` and optional `focus start|finish`: preserve continuity.
- `review show|save`: a convenience interface over scoped review documents.
- `doc list|show|put|search`: one knowledge/reference store.
- Project, context, routine, source, backup and import commands remain secondary.

Existing CLI spellings can be compatibility aliases over these use cases; they
must not keep separate business logic. MCP exposes the same behavior within its
fixed binding and human authorization rules. Preserve draft-only knowledge writes
unless deliberately changing that separate policy.

## Migration and implementation sequence

1. Add complete reads for weekly plans and structured reviews. Fix instructions
   that contradict capture scoping. This removes workarounds before storage changes.
2. Unify reference processing and documents, with a real foreign key and atomic
   transaction. Migrate knowledge records with an explicit ID map. Preserve
   source references, verification dates, validity and supersession metadata.
3. Migrate review content to scoped documents. Never guess the scope of a legacy
   profile-wide review: require a mapping or keep it in restricted legacy storage.
   Resolve `(scope, slug)` collisions deterministically, retain aliases and rewrite
   links; kinds currently permit duplicate slugs.
4. Remove profiles and areas after migrating their references and proving scope
   equivalence. Multiple legacy profiles or conflicting plans require explicit
   reconciliation; they must not be silently collapsed. Preserve historical goals
   and subgoals as archived material with old-ID mappings.
5. Simplify task and plan states. Preserve unknown closures and old plan roles in
   migration provenance. Keep historical plan prose without re-importing it as
   operational task state. Convert overrides only when their meaning is clear.
6. Update exports/restores, `check`, CLI, MCP, installed skills and documentation
   together. Retire legacy aliases only in a declared breaking release.

Use new migrations, never rewrite applied migration files. First migrate a copy
from a snapshot, validate it, and retain the original. Existing export formats
need a versioned reader. Ambiguous records are reported and preserved, never
discarded merely to reach the smaller model.

Acceptance checks:

- A capture creates several tasks exactly once, including retry after lost response.
- A reference write failure leaves its capture pending; success is discoverable
  by capture ID and document search after closing and reopening the database.
- Daily and weekly plan reads match their writes; task completion is reflected
  without updating a second document.
- A checkpoint resumes work without a plan or focus session.
- Scoped reads, goal/review reads, retries and partial plan edits cannot disclose
  or overwrite another scope's records.
- Migration preserves record content and references, verifies foreign keys and
  supports export/restore round trips. Legacy collisions and unknown states are
  explicitly reported.
- A real workflow can be completed through either CLI or MCP without hidden SQL,
  duplicate notes or asking the user for data already stored.

Implementation is tracked in [implementation-plan.md](implementation-plan.md).
See [current-model.md](current-model.md) for the shipped contract, compatibility
adapters and explicit migration limitations. This document records the original
design intent; implementation details take precedence.
