# Current model

SQLite owns operational state. Markdown is document content; files are not a
second writable store. One owner and timezone replace the profile graph. Scopes
remain explicit boundaries for personal, open-source and client work.

| Concept | Meaning |
| --- | --- |
| Capture | Unclarified input and its full processing outcome |
| Task | Action with a direct status, optional project/context/due date |
| Project | Multi-step desired outcome within one scope |
| Context | Optional task filter; old areas become contexts |
| Plan | Ordered references to tasks for a day or week |
| Checkpoint | Resume context, independent of focus sessions |
| Document | Scoped Markdown page, sources, revision and optional project |
| Routine / goal | Optional recurring reminder / one active direction |

Knowledge and reviews are document purposes. Page identity is `(scope, slug)`;
status is draft, verified or superseded. New knowledge defaults to draft. There
is no manual knowledge index requirement, embedding service or background agent.

## Agent workflow

1. Search `knowledge_search` with query and scope, optionally project_id.
2. Read selected pages with `knowledge_read`; inspect evidence and revision.
3. Save with `knowledge_save`: scope, slug, title, body, sources and
   expected_revision. Zero means create-only, positive means compare-and-update.
4. Follow `knowledge_related` when useful; it returns at most 20 summaries per
   direction and reports truncation. MCP only writes drafts.

To clarify information, `process_capture` accepts outcome `reference` and a
nested `document` save request, or `document_id` for an existing page. Capture and
page share one scope. Saving and clarification commit together. The outcome
retains the document ID. Lost responses can be retried with the identical key
and payload. Revisions reject stale edits.

Use `task_update` to patch task metadata or direct status. Empty project_id,
context_id or due_at clears that field. `task show` includes the latest checkpoint.
`plan_show` reads either daily or weekly priorities; `review_show` reads a scoped
review. Partial plan edits retain hidden tasks and cannot change a global
exception reason. More than three daily priorities needs an explicit reason.
An empty plan is valid. New plan items need only task IDs; roles are derived.

CLI equivalents are `knowledge search|read|save|related`, `task
list|show|update|done|cancel`, `plan show|set`, `review show|save`, `checkpoint` and
`settings`. Pass flags before positional IDs; `--id` avoids ambiguity. Run
`ztd --help` for legacy adapters and `ztd status --json` for the effective binding.

## Migration and compatibility

Schema 8–13 migrations preserve the old database via an automatic sibling
`*.before-v13-*.db` snapshot before upgrading an existing persistent store. Keep
that snapshot until the new version has been verified. Migration runs in
transactions with foreign-key validation. Export version 2 includes canonical
state and legacy originals. Restore accepts version 1 by migrating an isolated
staging database first; search indexes are rebuilt.

Knowledge records become pages with original metadata and IDs in provenance.
Single-scope reviews become pages. Ambiguous multi-scope reviews and secondary
profile plans are retained in `legacy_records`, not exposed to scoped agents.
Unassigned legacy goals stay hidden; `ztd check` reports reconciliation warnings.
Legacy profiles, subgoals, areas, assertions and overrides are retained as
historical material. Reconciliation is manual in this release; there is no
automatic guess of ownership or completion.

Old profile/area reads are compatibility views, and lifecycle/closure columns
are derived from task status. Old commands and payloads remain adapters. Existing
source registration, reported batches, cursors and coverage fields remain for
connector compatibility; this change does not implement connectors. Optional
legacy document purposes and task metadata remain readable. Unknown old closures
are `closed_unknown`, never assumed completed.

Colliding page slugs are renamed under `legacy/collision/`; old kind/slug reads
resolve via aliases. Existing page bodies are preserved verbatim. Ambiguous links
may require manual correction using `doc lint`; the migration does not rewrite
historical prose. Review these cases before retiring the snapshot.
