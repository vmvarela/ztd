---
name: Process with ZTD
description: Process the local inbox or the selected sources, making decisions without duplicating state.
---

# Process

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Do not read plans, journal or
knowledge cards except to classify the entry in progress; load `ztd-knowledge`
only in the "Information" branch.

## Scope and inbox queries

1. With no selection, process **only the local capture** with
   `ztd list --list inbox`; if it is empty, say so, mark the `inbox` routine
   done when its row exists (`ztd routine done inbox`) and stop.
   An ID limits processing to that entry with `show ID`. A scope filters the
   local inbox; an explicit source queries that source. "All" includes the
   local inbox and the registered sources of every scope, even when the local
   capture is empty. For external sources, discover their registration with
   `ztd source list --all` and read the linked knowledge cards
   (`ztd doc search`, `ztd doc get`); do not keep another
   integration list nor confuse historical background with current sources.
   Reviewing an external scope requires a review request; it is not inferred
   from a simple local filter.
2. Work one scope/client at a time: query its filtered local inbox and its
   external sources with the identity and tools authorized by its cards. Do not
   mix one scope's content with another's nor with other scopes' summaries. In
   a global summary list sources and coverage, without client details.
3. Query read-only external sources within their registered scope. This
   invocation is an on-request review, not a monitor nor an inventory of every
   clone. Respect pagination and intervals; report the scope actually queried.
   If access, repositories or scope decisions are missing, mark that source
   pending and continue with the others; ask only what is needed to unblock it.
4. Do not import whole inboxes nor duplicate existing tasks: cross-check links
   and IDs against the lists. Decide on the findings and capture with `ztd`
   only the agreed personal actions before processing them. Ticket and PR state
    stays in its service; reading does not authorize commenting, closing,
   approving or publishing.

## Daily review and coverage

Reviewing external sources is optional and configured: do it when the store
registers them and the request asks for a review (for example while preparing
the day with `ztd-plan`); never as an unconditional daily obligation. There is
no background monitor. An explicit scope filter limits the review and is
reported as such. Reuse same-day coverage only while source, identity, scope
and interval remain valid and there are no known changes; "update" forces a new
query. A failed access is pending, not an empty inbox, and does not stop the
other sources.

Keep a brief record per scope with `ztd doc put --kind review --slug
'<scope>/YYYY-MM-DD-inbox' --title T --body TEXT`
(`<scope>` is `<context>` or `<context>/<client>`). Note source, date/time with zone, non-secret identity,
scope/interval, coverage complete/partial/unavailable/pending, links to
evidence and next IDs/decisions. Keep previous results when updating
(`--expected` guards the revision); do not
copy full tickets or histories. A plan or global summary links records and
shows only coverage, without client content. Coverage age never substitutes for
verifying a task's state before operating on it.

## Decide and move entries

Query `list --list inbox` and, to cross-check duplicates,
`list --context CONTEXT` (a known client is its own scope, `--scope
client:NAME`) and `--project ID` when it applies. Do not dump complete lists from
other scopes. A local capture without context is not skipped when processing
the whole local inbox. Resolve what is unambiguous directly and group only
ambiguous questions; apply each move transactionally, preserving order.

When a classification or action is repo-related and nothing scopes it, a valid
`data.binding` from `ztd status --json` may default the scope (`context`,
non-null client kept, `project`). A malformed binding means stop and ask
first; the binding is a routing hint, not authorization, and never changes the
store root. It never filters the inbox: local and global inbox processing
stays as defined above, and captures stay scope-free.

1. Clarify the outcome and whether it requires action; ask only when ambiguous.
2. Decide from the request and the available data:
   - No use: discard it with a reason (`ztd process --outcome discard --reason
     ...`).
   - Information: load `ztd-knowledge` and interpret the lesson to choose a
     destination scope from the session binding. The document's meaning, not
     automatically the capture's source scope, determines the destination.
     With MCP, pass that scope to `doc_put`; over the CLI, pass it as
     `--scope DEST` (`ztd doc put --kind knowledge --slug SLUG --scope DEST
     --title TITLE --file BODY_FILE --expected REV`). Before a CLI write, use
     `ztd doc get --kind knowledge --slug SLUG --scope DEST` to check whether
     the card exists and pass its current revision to `--expected` when
     updating; MCP treats `expected_revision=0` as create-only, but CLI
     `--expected 0` is not create-only and can overwrite an existing card.
     The MCP server rejects scopes outside the binding. When updating, use
     `doc_get` with the same scope to read the current revision. Store the
     card first as a draft, and only after that write succeeds keep the
     capture as a reference, putting the written document's ID in the reason
     as audit context (`ztd process --scope CAPTURE_SCOPE --outcome reference
     --reason DOC_ID CAPTURE_ID`; the MCP `reason` argument likewise carries
     it). Normal reads retain only the
     outcome kind, not the reason, so retain the document ID, scope, kind and
     slug from the successful write. If the card write fails, leave the
     capture pending; if the reference step fails, keep the draft and retry the
     identical MCP request with the same idempotency key and payload when its
     response was lost. The two steps are not atomic.
   - Future possibility: the `someday` list — or a dated
     `ztd process --outcome defer --review-after YYYY-MM-DD`.
   - Short action (about two minutes): do it if it is within the request and
     the available tools; before any external write (push, publication,
     comment, send or remote close) or destructive action (deletion, e.g. of
     backups, reset, mass overwrite) ask for concrete authorization: processing
     or selecting the entry does not authorize those effects. Record it done
     only after a real result (`ztd process --outcome immediate --evidence
     ...`).
   - Delegated or blocked: the `waiting` list, with dependency and follow-up.
   - Executable action: the `next` list, phrased with a verb and an outcome.
3. For anything multi-step, register a project with `ztd project add <id>
   --scope S [--desired-outcome TEXT] [--repo-url URL] [--clone-path PATH]`
   and define the next action. Do not invent
   repo URLs or clones without having them.
4. Fill in `context` (`ztd process --context ctx:...`) and `project`
   (`ztd process --project ID`) when the capture is processed; a known client
   is its own scope (`--scope client:NAME`), and no command changes them on an
   existing item. Register firm dates with `ztd doc put --kind calendar
   --slug calendar` with the ID, without duplicating task state.
5. Keep the ID: resolve an inbox capture with `ztd process --outcome
   work_items|reference|immediate|discard|defer` on the declared database
   (`--db`/`ZTD_DB`), and move an existing work item with `ztd move ID DEST`
   (DEST is `next`, `waiting`, `someday` or `archive`). `--field 'key: value'`
   sets `waiting_on`, `resolution` or a custom key; `context`, `client` and
   `project` are set at processing time and have no later setter, and there is
   no `--unset`. Use
   `--text` only to rephrase the outcome. `ztd` validates, recovers interrupted
   moves and verifies that only one canonical location remains.
    Do not edit the lists directly. Run `check` when closing a batch of moves
    or reference changes, not after a query with no changes.
   If a decision is still missing, ask for it in this pass. If the answer does
   not arrive, defer the capture (`ztd process --outcome defer --review-after
   YYYY-MM-DD`) or move the item to `someday`, or to `waiting` when it
   depends on a third party, adding `waiting_on` with an `@YYYY-MM-DD` follow-up
   date when known. Do not leave it in the inbox.

## Give a place

When what is out of place is not an action, decide its location: knowledge to
its context/client/project cards (`ztd-knowledge`), code to registered clones
(`ztd-repo`). When moving documents, update the links of the indexes and cards
that reference them (`ztd doc lint` re-checks them); consolidate duplicates only after comparing contents and
keeping what is necessary. For physical materials, agree on a place and a
concrete action; do not declare a physical organization done from the agent.
Check that what was reorganized is findable through its indexes
(`ztd doc search`) and summarize
the paths.

Summarize decisions, pending entries and the next step. For each source state
whether it was reviewed complete (within its scope), partial, unavailable or
left pending, with the interval/repositories consulted where applicable.
Reviewing a source does not mean emptying its backlog. Do not declare every
inbox processed if some were not consulted or keep pending decisions; an empty
local list is not enough.

When the pass covered the whole local inbox and it is empty afterwards, mark
the `inbox` routine done with `ztd routine done inbox` when its row exists
(`ztd routines due` lists the rows); if the row is absent, say so and continue.
A pass limited to an
ID, a scope or only external sources does not mark it.
