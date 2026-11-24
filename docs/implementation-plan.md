# Simplify ZTD and add an agent-friendly knowledge wiki

Baseline: `88275c198933d8b68fe85ecbb06a6d3ad6375eaa` (master, checked 2026-11-23).
Target: [model-simplification.md](model-simplification.md).

## Delivery order

| Phase | Deliverable | Acceptance |
| --- | --- | --- |
| 1. Baseline and contracts | Reproducible Go toolchain, existing checks, explicit migration contract | Baseline failures distinguished from regressions |
| 2. Canonical documents | One document store for knowledge and reviews, provenance, project links, optional purposes | Existing content survives; search requires no hand-maintained index |
| 3. Atomic clarification | Process a reference and save/link its page in one transaction | Failure rolls back both; retry creates no duplicate; capture reads retain outcome details |
| 4. Agent knowledge interface | Search/read/save/related over existing FTS5 and links; scoped, bounded responses | Agent can retrieve and update knowledge using revisions, without SQL or multi-write coordination |
| 5. Tasks and planning | Direct closure states; editable task metadata; daily/weekly reads; ordered priorities; explicit exceptions | Completion is reflected in plans; partial scope edits preserve hidden tasks |
| 6. Personal model | Replace profile graph with settings, simplify areas/goals, scoped reviews, independent checkpoints | One person and one planning view; client isolation preserved; no focus required |
| 7. Migration and supporting state | Versioned migration/restore, legacy preservation, simplified source state | Old schemas/exports round-trip; ambiguity reported; original data preserved |
| 8. Agent instructions and documentation | Short workflows using canonical APIs; legacy names only as adapters | No duplicated state, manual indexes or unavailable read commands |
| 9. Verification and PR | Regression, migration, CLI/MCP journeys, race/vet/build checks | Reviewable PR with actual results and explicit limitations |

## Decisions

- SQLite is canonical. Markdown is page content, not a second writable store.
- Captures and tasks remain distinct; one capture can create several tasks.
- Knowledge is a document purpose, not a new database or parallel entity.
- Revisions, transactions, history and idempotency remain.
- MCP cannot widen its host binding or promote knowledge beyond draft.
- References include source links; project is optional and must be in scope.
- Search uses FTS5; relations come from links. No embeddings, daemon or automatic
  LLM summarizer is required.
- Reviews are scoped documents; plans contain task references, not copies.
- Migration must not guess ownership or completion. Preserve unresolved originals
  and report them. Do not rewrite migrations already applied by users.
- Compatibility code must delegate to the canonical implementation; no dual writes.

## Verification scenarios

1. Capture -> multiple tasks -> select priorities -> checkpoint -> completion.
2. Capture -> knowledge page atomically -> search -> read -> revised save -> related.
3. Reference failure and lost-response retry; stale edits never overwrite content.
4. Personal binding cannot read/search/replay/write client knowledge or reviews.
5. A partial plan edit cannot delete or disclose a hidden client task.
6. Review writes are readable and use one canonical representation.
7. Migrate legacy data with colliding slugs, unknown closures, multiple scopes and
   source batches; preserve provenance and validate references.
8. Export/restore round trip, rebuilding FTS from canonical documents.
9. CLI and MCP expose equivalent use cases with transport-specific permissions.

Run targeted tests as phases land, then `scripts/check.sh`. Update this document
with observed results and any remaining work before opening the PR.

## Delivery report

Implemented phases 1–9 with the compatibility boundaries below.
Validation on 2026-11-24: `scripts/check.sh` passed (format, vet, full tests,
race detector, integration rerun, module verification and binary build).
Final migration/integrity changes also passed targeted normal and race tests.

- Canonical state: singleton settings; generated task closure compatibility
  columns; scoped documents; task-reference plans; independent checkpoints.
- Six forward migrations preserve originals, snapshot existing stores and
  validate foreign keys. Version 1 exports are upgraded in an isolated database;
  version 2 includes goals, document metadata, aliases and retained legacy data.
- Agent workflows now use bounded knowledge search/read/save/related, atomic
  reference processing, revision-checked task patches and readable plans/reviews.
- Targeted tests cover reference rollback/retry, scope/project isolation,
  create-only writes, partial-plan preservation, retries after later edits,
  legacy collision aliases, unknown closures and old-export restoration.
- A real stdio MCP + CLI integration test covers the knowledge-to-action journey.

Explicit implementation decisions:

- Atomic references require the capture and document to share a scope. A change
  of ownership is a separate deliberate reconciliation, not an incidental save.
- Migration preserves historical Markdown verbatim and provides old identity
  aliases. It does not rewrite ambiguous historical links; `doc lint` can identify
  links needing manual correction.
- Multiple profiles' plans and ambiguous reviews remain in restricted legacy
  storage. Conflicting active goals stay unassigned until reconciled. There is no
  automated reconciliation UI. Old databases with multiple simultaneously open
  focus sessions must resolve that conflict before upgrading; the snapshot is
  retained if migration stops.
- Existing source ingestion and coverage fields remain compatibility state. No
  connector, polling service, automatic summarizer or parallel knowledge store is
  introduced. Old command/payload adapters remain to avoid needless breakage.
