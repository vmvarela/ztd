# ZTD v2 System Specification

**Date:** 2026-11-19
**Status:** Proposed for implementation planning after independent review; review corrections applied. No implementation has been approved or performed.
**Authors:** Product requirements supplied by Victor; architecture and verification contract drafted with OpenCode.
**Implementation language:** Go 1.27.4, confirmed against https://go.dev/dl/?mode=json on 2026-11-19. The development machine currently has Go 1.27.3 and must receive the patch update before implementation.
**Target product:** A clean Go implementation of ZTD. The existing Zig Markdown product remains operational until an explicit migration decision.

Here, **v2** means the new product generation. It is unrelated to the existing Markdown store's `"format": 2`.

All product code, names, commands, APIs, schemas, errors, technical documentation, fixtures, and example content are in English. Captured user content retains its original language. This document does not translate or modify user data.

## 1. The big idea

ZTD helps one person turn many competing inputs into a small set of deliberate commitments, then carry those commitments through focused work and regular review. The value is not a large task database. It is knowing what deserves attention now, what is still unprocessed, what can safely wait, and why a decision was made.

The product runs on one Mac and guides Zen To Done through an agent connected by a local MCP server. A CLI uses the same application core for automation, recovery, and structured inspection. Durable state lives in one local SQLite database. Markdown becomes an optional read-only export, never a second writable store.

The product deliberately excludes an agent runtime, a mobile service, live device synchronization, an MCP gateway, and an automatic calendar synchronizer. Those additions would hide the method behind infrastructure and would not improve the first working journey.

## 2. Product boundaries and success

### Confirmed decisions

| Area | Contract |
| --- | --- |
| Runtime | One Mac, one filesystem-local database, concurrent local CLI/MCP processes. |
| Capture away from the Mac | Enter notes in an external source; ingest them during a later source review. No live mobile connection. |
| Daily experience | Agent-led ZTD journeys; CLI as a reliable fallback. A TUI is optional and later. |
| Agent autonomy | Capture and register freely; classify only without material ambiguity; proposals for priorities and commitments; confirmation for external writes. |
| Initial input sources | Manual/local input, filesystem folders, GitHub, email, and Jira. |
| Calendar providers | Office 365 for work and Google Calendar for personal events, through separate host-connected sources. |
| Calendar authority | Read events and availability; link relevant work; create confirmed focus blocks only. Do not edit meetings. |
| Trust separation | One database with mandatory logical scopes. This is not physical isolation. |
| Backup | Consistent encrypted Restic backups after an operator chooses and approves a destination. Backup is not synchronization. |
| Method | ZTD as a firm guide with visible exceptions and gradual habit adoption, not silent enforcement. |
| Language | Go. MCP and SQLite must share the same application core; there is no line-by-line Zig translation. |
| Retrieval | Structured links and FTS5 before LLM Wiki synthesis. `sqlite-vec` is explicitly deferred. |

### Success means

- A user can capture once, process an item deliberately, choose one to three MITs and one open focus across every Profile used that day, and review incomplete coverage without data being hidden.
- A new agent session can recover the selected objective, real result, evidence, uncertainty, and next action without the original conversation.
- A failed input source never looks empty or fully reviewed. A calendar read only covers the calendars visible to its Profile: preparing a plan while other configured calendars exist requires a recorded human assertion that they were checked. No declaration is treated as provider evidence.
- A scoped agent cannot read or mutate data outside its authorized scope.
- Only a trusted host adapter can attest `observed` source coverage. Model-authored or narrated batches remain `reported` and unverified.
- Every imported legacy item is imported or explicitly quarantined, with its original preserved. Cutover never depends on an unexplained difference.
- Evaluation reports actual tokens, calls, latency, corrections, and successful completion. It does not infer tokens from byte counts or claim savings without controls.

### Non-goals for this specification

- Multi-user collaboration, conflict-free live synchronization, mobile apps, or a remote API.
- A daemon required for ordinary use. Notifications and scheduled backups use host operating-system schedulers.
- An agent/LLM runtime inside the ZTD process. The host owns model execution and external tool calls.
- Bidirectional task/event synchronization or automatic meeting management.
- Arbitrary MCP proxying, provider credential handling, or a universal connector framework.
- Automatic semantic promotion of AI-generated prose to verified knowledge.
- Vector databases, embeddings, ANN indexes, and `sqlite-vec` in the first releases.
- Direct Markdown editing, dual writes between Markdown and SQLite, or SQL access exposed to the model.

## 3. Vocabulary

These names eliminate the ambiguity between authorization, human context, and task state.

| Term | Meaning |
| --- | --- |
| **Scope** | An authorization and partition domain: `personal`, `opensource`, or a configured work/client scope. Ordinary records, including Sources, Captures, and WorkItems, belong to exactly one scope. |
| **Profile** | A human-configured planning view over an explicit set of Scopes. The personal profile may aggregate `personal` and `opensource`; every work/client profile contains exactly one client Scope. Each Profile has one stable owner actor. |
| **ScopeBinding** | The immutable Profile/Scope allowlist supplied by an operator or host when launching a CLI/MCP session. The model cannot broaden it through a tool argument. |
| **Area** | An ongoing responsibility inside a scope, such as family, health, or personal administration. |
| **Context** | Optional GTD execution context such as `@home`, `@computer`, or `@calls`. It is not an authorization boundary. |
| **Capture** | An immutable original input plus provenance and a mutable, auditable processing state. It is not yet a commitment. |
| **WorkItem** | A processed, actionable commitment with one stable identity. Its status changes; it is not copied between lists. |
| **Project** | A multi-action desired outcome. It is not simply a folder or an Area. |
| **Reference** | Non-actionable material retained for later lookup. |
| **Goal / Subgoal** | A primary goal and a shorter-term contribution to it, linked to plans and reviews. |
| **Source** | A configured input or calendar connection, its scope, non-secret configuration, and retrieval/coverage state. |
| **Coverage** | What a retrieval or review actually examined, including failures, truncation, unparsed entries, and unexamined windows. |
| **Evidence** | An identified result from a command, external provider, or user. An agent declaration alone is not execution evidence. |

Scope selection follows this rule:

```text
Trusted operator/host configuration
  -> ScopeBinding for one session
    -> every app query and mutation receives that binding
      -> store constraints and queries enforce it again
```

A `.ztd.json` or current Git repository may supply a routing hint, never authorization. Only an operator can define a Profile. A personal Profile may be explicitly authorized for `personal` and `opensource`; a work Profile is limited to its configured client and cannot include personal or another client's data. There is no unrestricted cross-client search. A Profile grants visibility to its members; it does not merge their records into one Scope.

The ZTD limits are personal, not additive across Profiles. For each actor and local date, all open daily Plans together may commit one to three MITs and at most one FocusSession may be open, regardless of how many Profiles the actor uses. A primary Goal remains one per Profile because personal and client objectives are distinct planning views. Exception reasons are explicit, recorded, and never silently applied. Enforcing the daily total reads only the actor's aggregate plan/focus metadata through a trusted application check; it does not expose another Scope's task content.

**Implementation note (2026-11-22, ztd-go).** The implementation keeps one internal profile row for planning (`personal`, created by `init` over the declared scopes) and enforces this section through the binding rather than through one profile row per Profile: with no explicit scope a command binds the profile's scopes minus `client:*` and `work`, so a personal view never returns client work, while a client scope requires an explicit selection — `--scope client:<name>`, the host-level `ZTD_SCOPES` list, or a `.ztd.json` hint that resolves to a scope the profile covers — in that precedence order, and no model argument can widen it. The rules above are unchanged: the personal Profile may aggregate `personal` and `opensource`, a `work_client` profile still stores exactly one client scope, and there is no unrestricted cross-client view. The mapping is "the profile declares the scopes, the binding chooses the view" over one shared store — the filter narrows what a command sees; it does not divide or duplicate tasks.

## 4. Architecture and ownership

```text
Agent -> host-owned MCP tools and procedures -> ztd MCP server (stdio)
Human ---------------------------------------> ztd CLI
Optional later TUI --------------------------> same application use cases

Both transports
  -> application commands and queries
    -> domain invariants and ZTD policy
      -> SQLite state, history, and derived indexes

Host, not ZTD:
  -> executes LLM calls and remote provider tools
  -> converts provider results into typed ZTD source envelopes
  -> asks the user for required decisions and external-write approval

OS scheduler, not MCP:
  -> invokes explicit backup, maintenance, and optional notification commands
```

No database transaction may remain open during an LLM or network call. Side effects outside SQLite are coordinated by explicit operation records, not held locks or distributed transaction promises.

### Repository layout

Directories are created with their first meaningful implementation; empty scaffolding is not a goal.

```text
ztd/
  go.mod
  go.sum
  cmd/ztd/main.go

  internal/domain/
    identity.go       # IDs, revisions, provenance, typed references
    work.go           # WorkItem, Project, Area, Context, transitions
    capture.go        # immutable input and typed processing outcomes
    planning.go       # Goal, Plan, PlanItem, Routine, FocusSession
    scope.go          # Profile, ScopeBinding, and authorization invariants
    source.go         # Source kinds, capabilities, and coverage vocabulary
    knowledge.go      # typed knowledge; optional Wiki types arrive later

  internal/app/
    ports.go          # only the required repositories, clock, and ID generator
    collect.go
    process.go
    plan.go
    focus.go
    review.go
    simplify.go
    routines.go
    passion.go
    sources.go
    migrate.go
    backup.go

  internal/store/
    sqlite.go
    migrations/       # embedded, versioned SQL migrations
    work.go
    captures.go
    plans.go
    sources.go
    knowledge.go
    snapshots.go
    exports.go

  internal/cli/
    root.go           # process composition and output mode
    commands.go
    operator.go       # migration, backup, restore, configuration, checks

  internal/mcp/
    server.go         # stdio transport and schema exposure
    tools.go
    prompts.go
    errors.go

  internal/tui/        # only if structured UI earns its place

  internal/legacy/
    markdown.go       # read-only parser for the legacy Markdown format
    agent_export.go   # read-only legacy agent-continuity export importer
    compare.go

  internal/platform/
    paths.go
    process.go
    secrets.go        # references and OS integrations; no secret logging

  test/
    integration/      # processes, concurrency, recovery, migration, backup
    fixtures/         # synthetic data only

  assets/
    procedures/       # versioned English ZTD procedures and forms
    export/           # optional read-only Markdown rendering templates

  docs/
    architecture.md
    ztd.md
    data-model.md
    sources.md
    migration.md
    backup.md
    specs/            # pre/postconditions and verification obligations
```

Dependency direction is one-way: transports depend on `app`; `app` depends on `domain` and narrow ports; `store` implements ports and depends on `domain`; composition happens in `main`. Domain code never imports SQLite, MCP, CLI, TUI, or host packages.

Go code uses English identifiers and `internal/` boundaries rather than generic public plugin APIs. No provider-specific Python, Node, or TypeScript wiki service is embedded.

### Toolchain and dependency policy

Pin development and CI to Go **1.27.4**, including the `go` directive and tested CI toolchain. Later language updates are deliberate changes with fresh checks.

The intended dependencies are:

- `modernc.org/sqlite` after proving FTS5, concurrency, backup, and supported-target behavior without CGo.
- The maintained official Go MCP SDK, after verifying its current API against Go 1.27.4.
- The Go standard library for strict CLI and JSON handling where practical.

Each dependency needs a focused spike before it becomes architectural. Do not add a TUI toolkit, embedding SDK, ORM, generic migration framework, or wiki application preemptively. A working workaround for an immature dependency does not justify building a custom protocol stack.

## 5. Logical data model

The following is the logical model, not permission to create every table before the journey that needs it. The schema is introduced incrementally and migrated with `PRAGMA user_version`.

### Identity and provenance

Every entity has a stable typed ID, revision, creation timestamp, and provenance. IDs are never reused. Imported legacy `T-YYYYMMDD-NNN` IDs remain unchanged and unique.

Every ordinary record carries `scope_id`, including indirect references. Its linked ordinary records must belong to the same Scope. The exceptions are Profile, Goal, Plan, Review, daily-limit metadata, and calendar-review assertions: they carry `profile_id` or `actor_id` and may link records from different Scopes only when the operator-defined Profile explicitly contains those Scopes. Profiles cannot combine personal and work/client Scopes. The focused WorkItem retains its own Scope.

A single identity never duplicates task text across inbox, next, waiting, project, and archived lists. Lists are queries over status and links.

### Capture and outcomes

```text
Capture
  id, scope_id, source_id, external_id?, external_revision?
  original_text utf8, content_hash, source_uri?, occurred_at?
  captured_at, processing_state, processing_outcome?, review_after?, revision

  processing_state = pending | processed | discarded | deferred
  processing_outcome = work_items | reference | immediate | discard | defer
```

- `original_text` is immutable. Reformatting creates a WorkItem title or summary, not a replacement of the original input.
- A capture can produce several WorkItems. One typed processing operation commits all of them atomically.
- `deferred` requires a visible `review_after`; it is not permanent suppression or evidence of empty inbox.
- `immediate` records a real result and evidence. Claims that an action occurred without identified execution evidence are marked as user/agent declarations.
- Discard preserves the original and an explicit reason; durable storage does not mean every item is mandatory forever.
- Initial text ingestion accepts valid UTF-8 within a configured, bounded request size. Unsupported binary files are reported as not ingested, never silently discarded. Source size limits and the exact constants are fixed before implementation and recorded in coverage errors.

`processing_state` changes only through explicit operations:

```text
pending   -> processed | discarded | deferred
deferred  -> pending when review_after is due, or by explicit reopen
processed -> pending only by explicit reopen with a reason (history retained)
discarded -> pending only by explicit reopen with a reason (history retained)
```

Reopening clears the active processing result but never erases prior history. A deferred item becoming due is a query-visible transition, not a hidden side effect.

For external data, `(source_id, external_id, external_revision)` is unique when `external_id` is present. Manual records use a null `external_id` and are excluded by a partial unique index. An empty external identifier is not overloaded as the manual marker. A path/content-hash pair allows a changed local file revision to be captured without duplicating retries of the same bytes. Manual duplicate text is legitimate unless its idempotency key repeats; global text similarity is not deduplication. A changed `external_revision` creates a new immutable Capture linked to the same external identity; it never mutates the previous Capture, and an unchanged revision is deduplicated.

### Work and plans

```text
Context(id, scope_id, name, revision)
Area(id, scope_id, name, revision)
Project(id, scope_id, area_id?, desired_outcome, status, revision)
WorkItem(id, scope_id, area_id?, project_id?, context_id?,
         title, origin_capture_id?, lifecycle,
         waiting_on?, due_at?, closure_kind?, closed_at?, resolution?, revision)

lifecycle = next | waiting | someday | archived
closure_kind = completed | cancelled | unspecified
```

- `waiting` requires `waiting_on`; `archived` requires `closed_at` and a preserved resolution. A legacy archive lacking a classifiable reason imports as `unspecified`, never as a guessed completion.
- `due_at` represents a real deadline. A time reserved for focus is a calendar link, not a fabricated deadline.
- Completion, cancellation, explicit reopening, and other state changes are distinct application operations, not arbitrary field updates.
- Deleting a WorkItem or Project means cancelling/archiving it while preserving its identity and history. There is no ordinary hard delete. A discarded Capture that never produced a linked record may be purged only by an explicit operator command, with a content-free tombstone recording its ID, reason, and time; sensitive content may not remain in history after such a purge. No automatic purge exists.
- Every mutation writes current state and an append-only history event in one transaction. History is evidence, not event sourcing; tables remain directly queryable.

```text
Profile(id, name, kind = personal | work_client, owner_actor_id, timezone, status)
ProfileScope(profile_id, scope_id)

Goal(id, profile_id, kind = primary | subgoal, start_on, end_on, statement, status)
Plan(id, profile_id, kind = daily | weekly, period, status = open | committed, revision)
PlanItem(plan_id, work_item_id, role = mit | big_rock | batch, position)
DailyLimitOverride(id, actor_id, local_date, rule = mit | focus,
                   reason, created_by, created_at)
Routine(id, scope_id, kind, cadence, last_completed_at?, active)
FocusSession(id, profile_id, actor_id, work_item_id, started_at, ended_at?, outcome?)
Checkpoint(id, scope_id, work_item_id, result, evidence_refs,
           uncertainties, next_action, created_at, revision)
Review(id, profile_id, kind = daily | weekly | monthly | yearly,
       period, outcomes, coverage, completion_state, created_at)
CalendarLink(id, scope_id, source_id, work_item_id?, plan_item_id?,
             provider_event_id, relation, provider_version?, last_seen_at)
CalendarReviewAssertion(id, profile_id, actor_id, local_date, statement,
                        created_at)
IdempotencyRecord(command, idempotency_key, request_hash, result_json,
                  created_at)
ExternalOperation(id, scope_id, kind, idempotency_key, request_hash,
                  state = prepared | succeeded | failed | outcome_unknown | reconciled,
                  provider_reference?, result_evidence?, revision)
```

Plans and reviews link IDs. They do not clone WorkItems. Changing a WorkItem updates every relevant view automatically. The `Plan` Profile determines which WorkItem Scopes its items may reference; a Plan is unique per `(profile_id, kind, period)`. The MIT limit is evaluated across all open daily Plans for the same actor and local date, not once per Scope or Profile.

`FocusSession.actor_id` comes from the trusted host/Profile owner and remains stable across restarts; it is not an arbitrary model argument. At most one FocusSession may be open per actor across all Profiles. A partial unique index on open sessions enforces this invariant at the store boundary. Starting elsewhere never silently closes the first focus.

A Goal can have a configured grace/override policy. Plans may be incomplete while open. A committed plan with zero MITs or a daily total above three requires a recorded `DailyLimitOverride`, so an intentional day off or exceptional day is not confused with an invalid plan. One active primary Goal remains per Profile.

Idempotency records are retained for the life of the store by default. An operator may prune records older than 90 days only after resolving every related ExternalOperation; the tombstone of the command and result remains queryable through ordinary history. External operations remain distinguishable from evidence classification:

```text
ExternalOperation.state   prepared | succeeded | failed | outcome_unknown | reconciled
source result_kind        observed | reported
evidence freshness        current | stale | unknown
```

`reconciled` is an operation lifecycle state, not a claim that the provider observed the intended outcome. An external provider remains authoritative for its own data.

### Knowledge

```text
KnowledgeRecord
  id, scope_id, kind = fact | decision | constraint | procedure | reference
  text, state = current | superseded, review_state = draft | verified
  source_refs, valid_from?, reviewed_at?, supersedes_id?, revision

KnowledgeLink(record_id, entity_type, entity_id, relation)
```

- Original evidence, a generated summary, and an agent interpretation remain distinguishable.
- A linked constraint is retrieved by its mandatory relation, not only by text ranking.
- `superseded` knowledge stays in history and cannot silently masquerade as current.
- ZTD procedures are versioned product assets, not mutable LLM-generated knowledge.

## 6. The ten habits as product journeys

All ten habits are part of the functional contract. They are designed completely, delivered incrementally, and adopted gradually. A feature being available does not force the user to practice every habit immediately.

| Habit | Product journey | Required safeguards |
| --- | --- | --- |
| **1. Collect** | Quick text capture; configured manual, directory, GitHub, email, and Jira sources feeding one pending-inbox view. | Capture immediately before interpretation. Preserve original and provenance. Acknowledge only after durable commit. Multiple sources do not imply multiple canonical items. |
| **2. Process** | Return one pending Capture at a time. Choose discard, delegate/wait, do now when practical, defer as WorkItem, save Reference, or consciously postpone review. | Process each item exactly once per accepted operation. No implicit archive, deletion, priority, or commitment from a failed/ambiguous interpretation. Deferred items become visible again. |
| **3. Plan** | Weekly review selects Big Rocks from a Project/Goal; daily preparation chooses one to three MITs across Profiles and batches minor work. | Calendar queries are explicit and scoped. Preserve sources of time constraints and require a human cross-calendar assertion when the Profile does not see every configured calendar. Firm-rule violations require an acknowledged reason; the method never hides remaining commitments. |
| **4. Do** | Open one FocusSession, inspect its latest Checkpoint, capture interruptions, and finish with paused/completed result and next action. | One open focus per actor across all Profiles. Starting another never closes the first silently. Agent statements do not prove external completion. |
| **5. Simple trusted system** | A few stable views: inbox, next, waiting, someday, projects, reference, archive, and routine/review queues. | No tags framework, arbitrary workflow DSL, or generic cross-provider synchronization. Add structure only for a demonstrated need. |
| **6. Organize** | Every Capture ends as an actionable item, Reference, explicit discard, immediate result, or dated defer; WorkItems have a scope, optional Area/Project, and provenance. | One place per entity. Linked references replace copied task state. External originals remain owned by their provider unless explicitly stored. |
| **7. Review** | Guided daily and weekly reviews; monthly/yearly procedures for goals; source coverage and routine debt are first-class. | Review unfinished/partial work and external failures. Never turn missing data into an empty list. A completed review must have evidence for its declared coverage. |
| **8. Simplify** | Generate candidates for elimination, stale commitments, excessive sources, repeated small tasks, and consciously approved simplification batches. | Do not bulk-delete or cancel automatically. Separate eliminating commitments from merely hiding them. Preserve history. |
| **9. Routine** | Morning/end-of-day and weekly routines, personal/work inventories, batching, cadences, and visible overdue runs. | Local schedulers can remind; an inactive MCP server cannot send reminders. Evaluate and adjust routines without losing execution history. |
| **10. Find your passion** | Guided reflection, discoveries, experiments, obstacles, and a chosen daily next action linked to personal goals. | This is coaching and material for reflection, not a deterministic status transition. Keep it personal and outside work profiles. |

The initial guided experience is Minimal ZTD: **Collect, Process, Plan, Do**, with Review introduced early. Procedures for the other habits remain in the specification and become individually activatable journeys, not an invisible automated program.

## 7. Rules and autonomy

Rules are visible application policy, not vague prompt advice.

```text
Default daily MIT count        1..3 across all Profiles for the actor and date
Default primary goals          one active primary per Profile
Focus                          one open FocusSession per actor across Profiles
Inbox retrieval                one item by default; pagination never means processed
Weekly planning                Big Rocks before minor work
Rule override                  explicit reason, author, and timestamp
```

```text
Class A: local record
  capture, source cursor, checkpoint, coverage record
  -> allowed inside an authorized flow

Class B: guided local decision
  unambiguous Capture outcome or next-action text
  -> allowed by the selected flow; ambiguous cases return human_decision_required.
     It never changes due_at, priority, MIT/Big Rock role, lifecycle closure,
     scope, or ownership.

Class C: human commitment
  MIT/Big Rock commitment, priority, goal, cancellation, purge,
  material scope/ownership changes
  -> explicit user decision or host approval gate

Class D: external side effect
  focus-block creation in the first release
  -> exact bounded proposal, explicit human confirmation, durable operation,
     execution by host, recorded result, and reconciliation when uncertain
```

A model-supplied `confirmed: true`, explanatory prose, or prior assistant message is not proof of user approval. Approval must come from a trusted interactive command or host permission boundary. Auto-approval configured only to reduce prompts cannot satisfy Class C or D. Before Stage 3 claims an approval gate, it must document the required host tool permissions and demonstrate that the flow is rejected when gating is absent. ZTD does not invent a generic roles framework for these four classes.

## 8. Sources and calendars

### Shared registry, different capabilities

Every Source has common metadata:

```text
Source
  id, name, scope_id, kind = capture | calendar
  connector = manual | directory | host_mcp
  provider, connection_ref, non_secret_query, cadence
  auth_state, coverage_state, last_attempt_at, last_success_at
```

Secrets are not stored in this table, exports, ordinary logs, or agent-visible configuration. A `connection_ref` identifies provider configuration held by the OS or the authenticated host.

Common identity, scope, read-only defaults, and coverage do not imply one universal response schema:

```text
CaptureSource capability:
  Enumerate(query, cursor, limits) -> captures, next_cursor, coverage

CalendarSource capability:
  Events(window, calendar_selection) -> observations, coverage
  Availability(window, constraints) -> observations, coverage
  Optionally CreateFocusBlock(exact proposal) -> provider reference and evidence
```

### Manual and directory sources

- Manual capture creates the Capture directly, with an automatic source such as `manual-personal`.
- A directory source has operator-approved roots, file-selection rules, size bounds, and scope. First-release ingestion handles text files only.
- The CLI reads directory files itself rather than sending file contents through an LLM. It does not follow symlinks by default, escape approved roots, execute file content, or overwrite source files.
- A file capture records its path, byte hash, and captured text. The source file is not automatically included in ZTD backups. That limitation is visible in provenance and backup documentation.
- Unsupported or changing files produce partial coverage. They never disappear silently because parsing failed.

### GitHub, Jira, and email through the host

ZTD does not embed OAuth flows or provider SDKs in its first connected release. The already authenticated host invokes the relevant MCP/provider tools, then calls one typed ZTD ingestion boundary.

Starting configurations, adjustable without a schema change:

- **GitHub:** triage inputs such as notifications, mentions, and requested reviews, depending on the verified provider capability.
- **Jira:** an operator-defined read-only JQL/query with explicit project/client scope.
- **Email:** operator-defined read-only folders or labels. No “mark read,” deletion, or reply action is implied by capture.

Remote folders, mailboxes, repositories, Jira projects, and tool access are not discovered by the model at write time. An operator registers the source and its scope beforehand.

### Source retrieval contract

A host-supplied source batch contains:

```text
source_id, batch_id, idempotency_key, provider_execution_ref?, result_kind = observed | reported
retrieval: window?, cursor?, requested_limit, provider_returned_limit,
           complete_window, truncated, failures[]
items[]:
  external_id, external_revision, original_text,
  occurred_at?, source_uri?, provider_metadata_summary?
```

Two ingestion paths share this schema, but not their trust level:

- An operator-configured trusted host adapter may submit `result_kind = observed` and complete coverage only when its identity is installed outside model-controlled arguments, is not exposed as a model-facing tool, and records the actual provider exchange. A model cannot impersonate this path.
- The model-facing `record_source_review` call accepts at most a `reported` batch with unverified or explicitly partial coverage. A `provider_execution_ref`, identifier, or other evidence-like field generated by the model does not upgrade its trust level.

For every supplied item, ZTD applies Capture validation, scope checks, immutability, and idempotent storage. It does not trust the host-supplied scope over the registered Source scope. Plain assistant prose claiming retrieval success cannot establish complete coverage. When no trusted adapter is available, complete `observed` coverage is unavailable and the host must present the batch as unverified rather than weakening the claim.

- Cursor advancement occurs only after its corresponding, contiguous retrieval page is committed.
- After a partial page, previously committed captures remain durable, the incomplete region stays pending, and cursor advancement cannot skip it.
- A retry reuses the same external identity and cannot duplicate captures.
- Unknown, partial, malformed, or unauthorized coverage is surfaced in `prepare`, source views, and reviews. Empty with errors is not treated as complete and empty.
- Provider rates, exact page sizing, largest supported input, and whether the source can prove a complete window are integration facts that must be tested, not assumed.

ZTD can promise that a **successfully committed Capture remains recoverable**. It cannot promise that a remote event or file was captured before it disappeared or that a provider returned everything. The product states this limit instead of claiming absolute losslessness.

### Calendar behavior

Calendar sources are ordinary configured Sources with calendar capabilities, not a separate general synchronization subsystem.

- `calendar-work` and `calendar-personal` are separate identities with non-overlapping scopes and provider configuration.
- Microsoft/Google-specific availability, recurrence, timezone, and OAuth behavior belong to the host connector. ZTD queries bounded UTC windows and preserves the returned source reference, relevant timezone, retrieval timestamp, and coverage.
- A calendar is authoritative for events, times, attendees, and recurrence. ZTD is authoritative for Goals, Projects, WorkItems, Plans, and focus intent.
- ZTD stores links and bounded observations needed for planning, not a second authoritative calendar mirror.
- Ordinary meetings never automatically enter the inbox. Only an identified action becomes a Capture or WorkItem.

Daily planning is a three-step process:

1. `prepare` returns Goals, current commitments, candidate MITs/Big Rocks, existing links, constraints, and the calendar windows needed.
2. The host retrieves calendar observations and presents a plan with proposed focus blocks. Missing or partial free/busy data is displayed as uncertainty, never as free availability.
3. The user commits the local Plan and confirms each external focus block. Only then does the host call the calendar provider and record its result.

Focus-block creation includes a stable operation identifier in the provider description or other supported client reference. A lost response records `outcome_unknown`; the host must locate/reconcile the provider operation before another create is attempted. No blind duplicate retry is allowed.

When the actor has configured calendar Sources outside the active Profile, availability and conflict-free planning are **not** implied by the Profile's own calendar reads. Before `prepare` may present day availability or a Plan may be committed, a `CalendarReviewAssertion` for that Profile, actor, and local date must record that the human checked the other configured calendars. The assertion stores only its statement, Profile, actor, local date, and timestamp; it contains no foreign event details. It is evidence of a human declaration, not provider evidence.

Until that assertion exists, `prepare` returns `human_decision_required` and marks cross-calendar coverage incomplete. The model cannot create or infer the assertion from prose, and the host must obtain it through a trusted interactive confirmation. When no calendar Source exists outside the active Profile, no cross-calendar assertion is required.

First release does **not** update meetings, move recurring series, accept invitations, mirror tasks to events, or synchronize task status to calendar completion.

## 9. Interfaces

### CLI

The CLI is both an agent-safe technical interface and an operator recovery path. Human output is concise English; every agent-facing command supports strict JSON with stable errors.

```text
ztd capture TEXT
ztd inbox next
ztd process CAPTURE_ID
ztd prepare [--date DATE | --item WORK_ITEM_ID]
ztd plan commit ...
ztd focus start WORK_ITEM_ID
ztd checkpoint WORK_ITEM_ID ...
ztd focus finish ...
ztd review daily|weekly|monthly|yearly
ztd source list|review|check
ztd find|show|check

Operator-only:
ztd init|config|export|backup|restore
ztd migrate import|verify
ztd install opencode
```

Every mutating domain command supports an expected revision and an idempotency key. An identical retry returns the original result; a reused key with different canonical request bytes returns `idempotency_conflict`.

### MCP

The first transport is local **stdio**, launched by the client as a child process. stdout/stdin carry JSON-RPC only; logs go to stderr. No network listener or always-running server is needed.

```sh
opencode mcp add ztd -- ztd mcp --profile personal
```

The exact host registration syntax is revalidated before release. The profile is configured by a human outside model-controlled arguments. Other hosts use equivalent stdio registration and their own approved profiles.

A plain MCP connection requires no plugin. Optional host procedure installation supplies ZTD guidance where client prompt/resources behavior is insufficient. Those assets use portable content, never absolute paths from the creator's workspace.

The initial model-facing tools are intentionally finite and typed:

| Tool | Effect |
| --- | --- |
| `capture` | Commit a manual Capture and return its ID/revision. |
| `sources` | Return configured source identities, due state, and coverage, not provider contents. |
| `record_source_review` | Ingest a typed model-reported source batch as `reported/unverified`; never as observed execution. |
| `inbox_next` | Return one pending Capture, by default, plus remaining/coverage counts. |
| `process_capture` | Apply one typed Capture outcome with revision and idempotency checks. |
| `prepare` | Read a bounded daily or WorkItem brief, latest checkpoints, constraints, and needed external queries. |
| `commit_plan` | Commit PlanItem references, not copied tasks; require host-gated human approval and rule acknowledgements. |
| `focus_start` | Open the sole focus for this actor across all Profiles or return a conflict. |
| `checkpoint` | Record real result/evidence, uncertainty, and next action without claiming completion. |
| `focus_finish` | Pause or complete the focus with the relevant result, next action, and resolution. |
| `record_review` | Record outcomes and explicit coverage, including an intentionally partial review. |
| `find` | Return a bounded list of IDs, titles, scope-allowed status, provenance, and freshness. |
| `read` | Expand a small set of authorized IDs into body, evidence, links, and required constraints. |

> **Note (2026-11-20):** These are the current tool names. The redundant
> `ztd_` tool prefix was removed; the MCP server itself is still named `ztd`,
> so host permission keys read `ztd_<tool>` (e.g. `ztd_capture`). The old
> `ztd_*` tool names were removed with no aliases.

There is no generic `update`, arbitrary SQL/query language, arbitrary scope parameter, or raw remote-provider tool. Source registration, restore, migration, backup scheduling, and scope configuration remain operator commands.

Every mutating MCP tool requires an idempotency key supplied by the trusted host or SDK and a canonical request hash. A model-generated fresh key cannot prove retry uniqueness; the CLI therefore generates and prints keys and requires explicit confirmation to reuse one. External captures are additionally deduplicated by external identity.

`record_source_review` is model-facing and can attest only `reported` data with `unverified` or partial coverage. A trusted host adapter, configured by the operator and outside model-controlled arguments, may write `observed` evidence through the application layer after a real provider exchange. That adapter is not exposed as an MCP tool.

Class C and D actions require a real trusted human approval boundary. Host auto-approval that suppresses prompts cannot satisfy that requirement, and Stage 3 must document the host permission configuration and demonstrate rejection when gating is absent.

`find` defaults to at most 8 candidates, with a hard configured maximum of 20. `read` expands an explicitly selected small batch, maximum 5, with paginated large content. These limits do not truncate mandatory linked constraints; they prompt for a separate bounded expansion if needed.

MCP prompts mirror the method vocabulary: Collect, Process, Plan, Do, Review, Simplify, Routines, and Passion. Prompts guide conversation; tools enforce state and invariants. MCP availability does not prove that a host automatically loads resources, invokes prompts, schedules habits, or starts a review. A second real MCP client must be tested before portability is claimed.

### Retrieval and token budget

- `prepare` returns the selected Goal/Subgoal, at most three proposed MITs, one next action, mandatory constraints, latest evidence, and known coverage gaps.
- `find` returns summaries and references; `read` performs explicit expansion.
- Mutations return ID, new revision, state/result, and errors—not an entire list or database export.
- Apply scope and validity predicates before text ranking and before returning top-k results.
- Use explicit stable cursors and expose truncation; do not use line number or “first N rows” pagination as a correctness proof.
- No resources or knowledge bases are inserted wholesale into the model context.
- Quantitative evaluation includes Capture creation, retrieval, repeated source calls, maintenance, and human correction costs.

The first retrieval implementation uses structured joins and FTS5. Embeddings and `sqlite-vec` require a separate evaluation showing failures in bilingual/paraphrase recall and a net improvement; no future generic search-backend framework is created now.

## 10. Storage and consistency

### SQLite contract

- The database lives on a local filesystem, not a network share or a live-synced folder.
- Enable `foreign_keys`, WAL mode, and a bounded busy timeout. Use `synchronous=FULL` for durable local commits unless a measured decision explicitly changes and documents this guarantee.
- Write operations use short `BEGIN IMMEDIATE` transactions. Reads use normal consistent SQLite snapshots.
- One writer exists per SQLite database at a time; multiple local CLI/MCP processes must serialize safely without mistaking inter-process contention for a Go data race.
- Concurrent readers/writers never hold application locks during network or LLM work.
- All schema changes are embedded, versioned, transactional migrations. A newer or unrecognized schema is rejected, never adopted speculatively.
- A nonempty unknown SQLite file is not silently initialized as ZTD.
- The model has no direct database file or SQL access.

### Concurrency and idempotency

For mutations on versioned objects:

1. Compute the canonical request bytes and request hash without trusting arbitrary transport formatting.
2. In one transaction, look up the `IdempotencyRecord` by `(command, idempotency_key)`.
3. Replaying the same key and hash returns the original result, even if the entity subsequently changed.
4. The same key with another hash fails without writes.
5. For a new request, validate scope, expected revision, state transition, links, and limits.
6. Commit current state, append-only history, derived index updates, and the `IdempotencyRecord` together.

`IdempotencyRecord`s are retained for the life of the store by default. An operator may prune records older than 90 days only after every related `ExternalOperation` is resolved; a content-free tombstone stays queryable through ordinary history.

Transactions are bounded and have deterministic failure behavior. `go test -race` is useful but does not replace integration tests with multiple real processes.

### Errors

Stable error families include:

```text
invalid_input, invalid_transition, not_found, scope_denied,
human_decision_required, rules_acknowledgement_required,
stale_revision, idempotency_conflict, focus_conflict,
source_coverage_incomplete, external_outcome_unknown,
unsupported_format, destination_not_empty, db_busy, db_incompatible, io_error
```

`not_found` returned to a model does not disclose the existence or contents of an out-of-scope entity. Local diagnostics may distinguish authorization failures without returning the foreign object's data. Errors do not expose raw SQL, credentials, or arbitrary provider payloads.

## 11. Optional LLM Wiki layer

The knowledge layer starts with typed records and explicit links. An LLM Wiki may be added only after ordinary capture, processing, planning, review, migration, and retrieval work reliably.

The evaluated external options are references, not dependencies:

- Karpathy supplies the raw-source/compiled-page workflow.
- OpenWiki inspires durable page-by-page ingestion, checkpoints, and no-op updates.
- Scrinium inspires cited revisions, evidence assessment, and freshness.
- MindBase/wiki-memory inspire explicit proposals and human confirmation.

If that phase is justified, use this internal model rather than another store or service:

```text
WikiPage(id, scope_id, title, state = draft | verified | superseded, current_revision)
WikiRevision(page_id, revision, body, content_hash, created_at)
WikiCitation(page_revision_id, source_entity_id, source_revision?, locator)
WikiProposal(id, scope_id, proposed_changes, evidence_refs,
             state = pending | approved | rejected | applied, revision)
```

- Originals and citations stay canonical in SQLite; Markdown export is a read-only view.
- Ingestion is explicit, selective, durable, resumable page by page, and a no-op when the meaningful source hash has not changed.
- The host's LLM proposes typed changes. It cannot mark its own prose verified, rewrite authoritative ZTD procedures, or correct cited evidence silently.
- A human approves promotion to verified knowledge. The expected page/proposal revision prevents lost updates.
- Inspection is tool-assisted and reviewable. Indexes and logs are computed by the engine, not maintained from memory by the LLM.
- Retrieval uses `find`/`read`, prioritizing constraints and decisions linked to the current item before textual candidates.
- Procedural lint checks broken references, changed evidence hashes, orphans, and scope violations deterministically. LLM-semantic lint may propose contradictions but does not silently resolve them.
- Cost evaluation includes ingestion, maintenance, lint, query, rereading originals, and rejected proposals—not only saved prompt tokens.

This is deliberately a future layer. It must not delay the first trustworthy Minimal ZTD journey.

## 12. Legacy migration and cutover

The existing CLI/TUI continues to operate unchanged while the Go implementation proves itself. The migration does not silently rewrite the current `~/.ztd` Markdown store or its independent agent-continuity SQLite state.

### Inputs and safety

- Import from an operator-approved **copy** of the existing Markdown data, not an active writable store.
- The copy must have a verified quiescent state: copying is allowed only after the legacy store passes `ztd check`. If a legacy journal is pending, run the legacy `ztd recover` under its own rules before copying; never recover or repair the copy from the new implementation.
- Record the legacy version, converting/checking tool, `ztd check` result, and content hash of the source copy in the migration report. Import repeats that this is the verified copy; an unverified or changed copy fails before staging writes.
- Accept only identified, supported legacy versions. Legacy Markdown `"format": 1` must first be converted to the existing identified Markdown `"format": 2` with the supported tooling. No mixed/ambiguous format is guessed.
- Import legacy agent-continuity export version 2 explicitly, preserving its assignments, checkpoints, operations, and knowledge. The two legacy sources are related only by explicit references actually present in the data.
- Never commit personal or client data into public fixtures. Import tests use synthetic stores; a real-data import requires a separate authorization and destination check.

Commands:

```text
ztd migrate import --source COPY --agent-export EXPORT --target STAGING --report REPORT
ztd migrate verify --source COPY --agent-export EXPORT --target STAGING --report REPORT
```

The target must be empty or a recognized staging database owned by the same resumable migration run. Existing arbitrary data is never overwritten.

### Preserving meaning without inventing history

An operator-approved mapping translates legacy routing to the new vocabulary:

```text
legacy context/client -> Scope and, where appropriate, Area
current task context   -> explicit optional GTD Context, only if the operator supplies it
legacy project path   -> Project with preserved original outcome/reference material
```

Legacy inbox lines become Captures. Active/archive lines become one WorkItem each with their original `T-...` identity. Free-text `waiting_on`, `resolution`, timestamps, projects, and unknown fields are preserved. An ambiguous archive resolution is `unspecified`, not automatically completed.

Existing daily/weekly plans become Plan/PlanItem links where references resolve. Unmatched text and human documents are retained as legacy/reference documents rather than dropped or reinterpreted as commitments. Routines preserve cadence and last-run values. When source history is absent, migration creates one identified import event, not a fictional sequence of past transactions.

Agent assignments import as WorkItems or explicitly linked legacy assignments when identity cannot be established safely; checkpoints preserve their actual results and revisions. Legacy operation keys remain distinguishable and preserved for replay safety. Knowledge retains its original IDs, scope, source, revision, and classification. Every mechanically ambiguous relation goes to the report.

### Accounting and cutover gates

For each input entity, the report records exactly one disposition: `imported` or `quarantined` with original and reason. A quarantined item is not silently accepted as partial success; final cutover requires the operator to resolve or explicitly accept every quarantine.

The comparison covers IDs and aliases, original bytes/text, counts by legacy list/type and scope, fields, project/plan references, closures, routine cadence/run state, agent assignment/checkpoint revisions, knowledge, and idempotency records.

Re-running an interrupted migration does not duplicate entities. Two imports of the same source into separate empty staging databases produce equivalent logical output and discrepancy reports.

**No dual-write period is allowed.** A rollback before any new Go write restores the old configuration. After new writes, rollback requires reconciliation/export of those changes; replacing the new database with an old copy would discard work.

Only after explicit user acceptance does configuration select SQLite as canonical. The legacy Markdown source remains read-only until the operator separately archives it. Migration never deletes it.

## 13. Backup and restore

**Implementation note (approved 2026-11-22):** the approved backup path is
`ztd snapshot` to an iCloud-synced directory. Restic remains optional and
unconfigured; the destination and policy below stay unselected.

A complete backup contains all scopes in the shared database. Provider choice therefore requires approval for that combination of information; an encrypted transport alone is not data-owner authorization.

### Backup path

1. `ztd snapshot` uses SQLite online backup or `VACUUM INTO` to produce a consistent point-in-time database. It never copies an active DB/WAL pair naively.
2. `ztd export` produces a versioned, complete JSON export of canonical entities, history, source registry, non-secret configuration, and citations. Derived FTS/vector indexes are rebuilt on restore.
3. A narrow staging manifest records format/schema versions, creation time, and checksums. Exclude live locks, temporary files, credentials, OAuth tokens, and raw secrets.
4. Restic encrypts and versions the snapshot, export, redacted configuration, and manifest to the approved destination. The Restic repository password and provider credentials live outside the store and backup staging.
5. Restic retention, pruning, and repository checks are explicit operator policies. No automatic remote deletion is introduced by the application.

Restic supports S3/B2/Azure/GCS/SFTP; Google Drive/OneDrive require an operator-approved Rclone setup. Choose one when address, cost, and data-owner requirements are known. Backup snapshots are not a substitute for device synchronization or migration rollback.

### Restore proof

Restore targets must be empty. Never overwrite a nonempty live store through ordinary restore.

Verification covers both a restored SQLite snapshot and a clean import of the portable export:

- schema/version compatibility and `ztd check`;
- all entity counts and IDs, original text, state, revisions, links, and provenance;
- source and calendar links without credential restoration;
- repeat lookup and bounded `prepare` queries;
- rebuilt indexes and required constraints;
- no cross-scope disclosure in the restored database.

Schedule recurring restore drills, at least monthly once real data depends on this backup. A backup is not considered working merely because Restic reported a successful upload.

## 14. Security and privacy

- Enforce ScopeBinding in both application and store queries. Test all read, search, expansion, reference, and mutation paths for isolation.
- Do not let model arguments select an unapproved host profile, source query, path, credential, or external capability.
- Store secrets only in OS/host credential facilities. Do not put them in ZTD exports, Markdown views, logs, issues, or public examples.
- Treat every external Capture as untrusted data, never executable commands or system instructions. Preserve it while clearly distinguishing its trust level in source batches and procedures.
- Markdown export renders user content as data and avoids silently interpreting embedded directives or HTML.
- Audit human approvals and external operations without logging sensitive original contents unnecessarily.
- Classify remote execution evidence as `executed`, `reported`, `unknown`, or `reconciled`; do not equate a hyperlink, mention, or assistant assertion with a successful command.
- Isolate the host tooling and MCP profile per work client. Shared filesystem storage strengthens, not weakens, the need for logical isolation tests.

## 15. Methodical specifications

Use `methodical-programming` for behavior where a plausible implementation can silently corrupt meaning: specify pre/postconditions, derive the program from the postcondition, state invariants and finite bounds, discharge verification obligations, then test the exposed edge cases. It is not required as ceremony for rendering or transport glue.

The following contracts are normative even where implementation details remain open.

### Capture

```text
{Pre: request is valid; source/scope is authorized; text fits the input bound;
      idempotency key identifies one canonical command payload}
Capture(request)
{Post: accepted request produces exactly one durable Capture identity,
       original/provenance unchanged, in one transaction with idempotent result;
       identical retry returns the original result;
       same key + different payload or failed validation writes nothing}
```

Obligations: cover manual retry, external retry, two processes racing the same key, UTF-8/input boundaries, duplicate text with different identities, and crash before/after commit. A batch contains finite validated entries, so its bound is the number of entries.

### Process Capture

```text
{Pre: Capture is pending/deferred and due; expected revision matches;
      outcome has all required fields and any required human decision exists}
ProcessCapture(id, outcome)
{Post: exactly one typed outcome is committed with all linked records/history;
       no other Capture is changed;
       malformed or ambiguous outcome writes nothing;
       deferred outcome has a visible review_after;
       an identical retry reproduces the original result}
```

Tests: each outcome, multiple WorkItems atomically, waiting without `waiting_on`, immediate result lacking identified evidence, duplicate retries, stale revision, and a defer becoming due. Never implement Process as a generic partial field update.

### Commit Plan

```text
{Pre: all PlanItem IDs exist and belong to the Plan Profile's Scopes;
      the Profile is authorized; roles are valid for daily/weekly;
      references are unique; required commitment approval exists}
CommitPlan(plan, items)
{Post: committed plan links exactly the supplied IDs in order;
       default 1..3 MITs and one primary goal hold, or a specific override is recorded;
       no WorkItem is copied or implicitly completed;
       a failed validation leaves the original plan unchanged}
```

Tests: empty intentional plan, 1 and 3 MITs, 4 without acknowledgement, an item outside the Plan Profile, a permitted cross-Scope personal/opensource item, duplicate references, stale plan revision, and later WorkItem status changes.

### Focus and checkpoint

```text
{Pre: authorized WorkItem is actionable, meaning lifecycle = next, visible in the
      active Profile, and not archived or cancelled; the actor has no other open
      focus across all Profiles, or an explicit pause operation resolved it;
      a waiting item must first be explicitly reopened/unblocked}
StartFocus(item)
{Post: exactly one open FocusSession exists for the actor across Profiles;
       its identity and latest safe next action are returned;
       failure does not close or alter any existing focus}
```

A Checkpoint records its complete result tuple with its own revision atomically and does **not** increment the WorkItem revision. Progress during a focus session must not turn an unrelated next-action edit into a `stale_revision` failure. Unbounded history is paginated; continuation/reopen behavior must be explicitly tested rather than inherited accidentally from the legacy archive policy.

### Create focus block

```text
{Pre: an exact bounded proposal identifies the Source and calendar, start/end with
      timezone, and a title derived from an authorized WorkItem; the Source belongs
      to the active Profile's Scopes and supports creation; a trusted human approved
      that exact proposal; no unresolved outcome_unknown ExternalOperation exists
      for the Source; one idempotency key identifies the canonical payload;
      provider availability/recurrence is revalidated before the write}
CreateFocusBlock(proposal)
{Post: at most one event is created; one durable ExternalOperation moves from
       prepared to succeeded or outcome_unknown; provider reference/evidence and
       revision are recorded; identical key + payload returns that same operation
       and result without another external write; a different payload fails before
       writing; a new create for the Source is rejected while an unresolved
       outcome_unknown exists}
```

Reconciliation is a separate, explicit operation. It records the observed provider outcome or leaves the operation unresolved; it is never implicit in a retry. A non-idempotent create must not be repeated merely because the local response was lost.

### Source coverage

```text
{Pre: registered source scope matches the session;
      items fit the source batch contract; cursor describes the attempted region;
      observed authentication is established only by an operator-configured trusted
      host adapter outside model arguments}
RecordSourceReview(batch)
{Post: each supplied item is captured once under its external identity;
       observed/complete coverage is written only by the authenticated adapter path;
       a model-facing batch remains reported/unverified at most;
       coverage reflects complete, partial, failed, and unparsed portions;
       cursor never skips an uncommitted region;
       failed/empty coverage never marks pending items as processed}
```

Tests: page failure in the middle, provider-truncated page, repeated external item with unchanged revision, changed source revision, invalid item amid a page, and out-of-scope external metadata.

### Migration

```text
{Pre: source is a supported, read-only copy that passed the legacy `ztd check`
      with no pending journal; its version/check result/content hash are recorded;
      target is an authorized empty/staging DB}
ImportLegacy(source, target)
{Post: every source entity is imported or quarantined exactly once;
       every imported relation resolves or is explicitly quarantined;
       original IDs/text/fields/provenance remain recoverable;
       no new history or resolution is invented;
       a rerun adds no duplicates and leaves an inspectable comparison report}
```

The invariant for resumable pagination/transactions states exactly which source units are committed and which remain unprocessed. Activation/cutover additionally requires every quarantine to be resolved or explicitly accepted.

### Restore

```text
{Pre: target is empty; input has a supported complete manifest/schema}
Restore(backup, target)
{Post: all canonical rows and references are restored exactly once;
       derived indexes are rebuilt; scope and validity checks remain true;
       no credential is read from the backup;
       a failed/partial input leaves the target without activated canonical state}
```

Tests compare logical state rather than raw SQLite bytes and exercise malformed/partial input rejection before activation.

## 16. Verification evidence path

The evidence must establish the claim directly, not just demonstrate that code compiled. Every external-client claim separates configuration written, connection established, and actual tool behavior observed.

| Claim | Minimum evidence | Owner |
| --- | --- | --- |
| Correct local journey | Synthetic capture → process → plan → focus/checkpoint → daily/weekly review through the public CLI; inspect durable state after a new process starts. | Core implementer and evaluating user |
| Atomicity and inter-process concurrency | Two processes with stale revisions; identical idempotency race; crash before/after commit; busy writer; no partial history/index state. | Core/storage implementer |
| Scope isolation | Equivalent entities in personal/opensource/client scopes; query, search, read, references, plans, and mutations return no foreign data or influence. | Core implementer |
| ZTD rule behavior | Boundary/override/next-iteration tests for daily MIT limits and one open focus across Profiles, one active primary goal per Profile, defer/review coverage, and all ten guided procedures. | Method/core implementer |
| Portable Go storage | Go 1.27.4; native tests on macOS; cross-compilation and `go vet` for Linux/Windows; native smoke tests only when another OS is actually supported. Also FTS5, local concurrent processes, snapshot/export/restore. | Storage/release implementer |
| MCP contract | Same domain cases through CLI and stdio MCP; schema limits, error shapes, stdio hygiene, permissions, interrupted process; a second real MCP client for portability claims. | Interface implementer |
| Source coverage | Partial/error envelopes; a model-facing batch proves at most reported/unverified coverage; only the operator-configured trusted adapter proves observed complete coverage and the actual provider exchange. Then real read-only GitHub, Jira, and email retrieval using approved queries. No remote mutation in this check. | Source integrator |
| Calendar correctness | Timezone/recurrence supplied by connector; observed availability partial failure; required cross-Profile `CalendarReviewAssertion`; confirmed focus block; lost response followed by reconciliation and no duplicate. | Calendar integrator |
| Migration correctness | Verified quiescent legacy copy, recorded check result and hash, synthetic corpus, repeated/resumed import, relation and field comparisons, quarantine behavior, restored export; real-data copy only by explicit approval. | Migration implementer and user |
| Restorability | Both snapshot and portable-export restore into empty directories, checks, entity/reference comparison and a scheduled restore drill. | Operator/release implementer |
| Retrieval quality and cost | Fixed synthetic bilingual corpus, exact/paraphrase/constraint cases; actual model token/latency/tool-call measurements where host supports them; manual-note control; human correction counts. | Evaluating user |
| Optional Wiki benefit | Comparison of linked FTS5 retrieval against cited draft/reviewed pages, including maintenance and rejected-proposal costs. Vectors are not part of this gate. | Evaluating user |

The central repository checks after each relevant implementation increment are:

```sh
gofmt -l .
go vet ./...
go test ./...
go test -race ./...
go test ./test/integration -count=1
go mod verify
go build -o ./ztd ./cmd/ztd
```

`gofmt -l .` must print nothing. `go test -race ./...` is not evidence of inter-process locking correctness. CI uses the pinned Go version on the natively supported host, runs its tests there, cross-compiles and vets the other declared targets, and publishes neither personal data nor production credentials.

Small verification affordances are justified: deterministic clock/ID test ports, a fake host source-envelope recorder, process-level crash hooks in integration tests, and `ztd check`/export comparison commands. These are retained only where they make future failures reproducible and diagnosable; they are not a generic test-only service architecture.

## 17. Incremental delivery and acceptance

Do not build all horizontal layers, then discover that the ZTD experience is wrong. Prove vertical journeys and the migration safety net first.

### Stage 0 — Contract and feasibility

- Freeze the vocabulary, command outcomes, state transitions, ScopeBinding, autonomy classes, and legacy source inventory.
- Pin Go 1.27.4 and test `modernc.org/sqlite` plus FTS5 and the official MCP SDK with small focused spikes.
- Inventory legacy Markdown/consumer behavior and the agent export without changing the active store.

**Exit:** accepted specification, dependency evidence, scope/vocabulary mapping outline, and a reproducible migration fixture. No production database switch.

### Stage 1 — Import and storage safety

- Implement identity, scope, Capture/WorkItem/Project/Plan logical records, revision/history, SQLite migrations, and export/check. Create only the tables required by migration and basic storage safety in this stage; defer `FocusSession`, `Review`, `Checkpoint`, `Routine`, and other journey-only tables to the stage that uses them.
- Implement read-only legacy import, comparison, quarantine, resumed import, and restore of the portable export.

**Exit:** repeated equivalent imports and an explained comparison report on synthetic data; restore/isolation/concurrency tests pass. Existing `~/.ztd` remains untouched.

### Stage 2 — Minimal ZTD through CLI

- Deliver manual and directory Capture; one-at-a-time Process; Goal/Subgoal, Plan/PlanItem, and MIT/Big Rock rules; Focus and Checkpoints; daily/weekly Review; Routine due state; snapshot/export/restore.
- Show structured state through CLI queries and optional read-only Markdown export.

**Exit:** all core scoped journeys operate on copied data; backup restore and CLI restart preserve the next action. The app can guide all ten habits at contract level, while only the chosen initial habits activate by default.

### Stage 3a — Agent-first MCP and local journeys

- Expose the bounded MCP tools, ScopeBinding, approval boundaries, prompts, and English procedure assets. Connect through the configured OpenCode profile.
- Evaluate Collect → Process → Plan → Do → Review with the user, including resuming without a transcript.

**Exit:** measured successful completion with existing and new sessions, complete error/coverage handling, and no scope leakage. Do not call tools or prompts portable until a second client is exercised if portability is claimed.

### Stage 3b–3f — Independently deliverable read-only connectors

Each connector is a separate vertical slice with its own configuration, coverage tests, and exit. A connector that fails or is unavailable must not block the others or the completion of Stage 3a.

- **Stage 3b — GitHub:** typed host source envelopes for the operator-approved notification/query scope.
- **Stage 3c — Jira:** typed host source envelopes for the operator-approved read-only JQL scope.
- **Stage 3d — Email:** typed host source envelopes for the operator-approved read-only folders.
- **Stage 3e — Directory:** only if not already delivered by Stage 2; operator-approved paths with no traversal outside the roots.
- **Stage 3f — Calendars read-only:** Office 365 and Google Calendar events/availability for plan preparation, including the required `CalendarReviewAssertion`.

**Exit per connector:** the operator configures its scope, repeated review advances cursors without duplicates, partial/failed reads preserve honest gaps, model-facing review remains `reported/unverified` unless a trusted host adapter reports an actual exchange, and no content leaks outside its Scope.

### Stage 4 — Confirmed calendar focus blocks and experience improvements

- Add proposal/approval/operation/reconciliation for focus-block creation only.
- Implement optional notifications via OS scheduler and a TUI only if the CLI/agent review proves it valuable.

**Exit:** confirmed blocks are unique and recoverable after unknown responses; no general event synchronization exists.

### Stage 5 — Knowledge expansion by demonstrated need

- Evaluate typed knowledge and FTS5. Add the internal cited LLM Wiki only if it improves recall or continuity enough to justify its creation/review/maintenance cost.
- Revisit vector retrieval only if fixed-corpus evaluation exposes meaningful failures not solved by structure and FTS5.

**Exit:** measured benefit with original evidence still recoverable and no weakening of scope/review guarantees.

### Final acceptance before real-data cutover

- User accepts migration comparison and addresses every quarantine.
- Correct minimal journey, external-source coverage, backup and both restore paths have been exercised.
- Single shared DB and its complete backup destination have been explicitly approved for the included scopes.
- New writes happen in exactly one canonical store; rollback/new-write reconciliation is documented and understood.
- The existing Markdown system remains preserved and read-only until a separate archival decision.

## 18. Remaining configuration, not hidden design decisions

These items do not block the contract, but are explicit prerequisites before their corresponding real integrations:

- Select and approve the Restic destination, retention, credentials, and policy for a backup containing all scopes.
- Register actual GitHub source queries, Jira JQL/site access, email folders/labels, filesystem roots, and provider coverage limitations.
- Verify availability and permission policies for the Office 365 tenant and the selected Google MCP/client configuration rather than assuming feature availability from marketing pages.
- Configure IANA timezone, daily planning windows, focus-block defaults, notification preference, ScopeBindings, and per-habit adoption choices.
- Decide whether a future separate client-only export/store is necessary to satisfy a client's remote-backup policy. That is an explicit architectural change, not a filter that silently removes related data from an otherwise complete backup.

This specification creates only this design document. It does not change a repository, Go installation, MCP configuration, operational ZTD data, or remote provider. Implementation requires switching out of Plan mode; real migration, publication, and external writes retain their separate approval gates.
