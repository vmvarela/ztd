---
name: Process with ZTD
description: Process the local inbox or the selected sources, making decisions without duplicating state.
---

# Process

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Do not read plans, journal or
knowledge cards except to classify the entry in progress; load `ztd-knowledge`
only in the "Information" branch.

## Scope and inbox queries

1. With no selection, `/inbox` processes **only the local capture** with
   `ztd list --list inbox`; if it is empty, say so and stop.
   An ID limits processing to that entry with `show ID`. A scope filters the
   local inbox; an explicit source queries that source. "All" includes the
   local inbox and the registered sources of every scope, even when the local
   capture is empty. For external sources, discover their registration in the
   context/client indexes and read the linked cards; do not keep another
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

Keep a brief record per scope in `reviews/<scope>/YYYY-MM-DD-inbox.md`
(`<scope>` is `<context>` or `<context>/<client>`), or at the location its
card already registers. Note source, date/time with zone, non-secret identity,
scope/interval, coverage complete/partial/unavailable/pending, links to
evidence and next IDs/decisions. Keep previous results when updating; do not
copy full tickets or histories. A plan or global summary links records and
shows only coverage, without client content. Coverage age never substitutes for
verifying a task's state before operating on it.

## Decide and move entries

Query `list --list inbox` and, to cross-check duplicates,
`list --context CONTEXT` with `--client CLIENT` when a client is known and
the context accepts it, and `--project ID` when it applies. Do not dump complete lists from
other scopes. A local capture without context is not skipped when processing
the whole local inbox. Resolve what is unambiguous directly and group only
ambiguous questions; apply each move transactionally, preserving order.

1. Clarify the outcome and whether it requires action; ask only when ambiguous.
2. Decide from the request and the available data:
   - No use: archive with `resolution: discarded` and a reason.
   - Information: load `ztd-knowledge`, store the card and archive the capture
     with a link.
   - Future possibility: `lists/someday.md`.
   - Short action (about two minutes): do it if it is within the request and
     the available tools; before any external write (push, publication,
     comment, send or remote close) or destructive action (deletion, e.g. of
     backups, reset, mass overwrite) ask for concrete authorization: processing
     or selecting the entry does not authorize those effects. Archive it as
     done only after a real result.
   - Delegated or blocked: `lists/waiting.md`, with dependency and follow-up.
   - Executable action: `lists/next.md`, phrased with a verb and an outcome.
3. For anything multi-step, create a card with `templates/project.md`, link it
   from `lists/projects/index.md` and define the next action. Do not invent
   repo URLs or clones without having them.
4. Fill in `context` and, when a client is known, `client`; the store
   configuration only decides whether a missing client blocks, and never drops
   a known optional client. `project` when it applies. Register firm dates in
   `calendar.md` with the ID, without duplicating task state.
5. Keep the ID when moving the entry with `ztd move ID DEST` using the
   declared root, adding `--field 'key: value'` for `context`, `client`,
   `project`, `waiting_on` or `resolution`, or `--unset key` to drop a field. Use
   `--text` only to rephrase the outcome. `ztd` validates, recovers interrupted
   moves and verifies that only one canonical location remains.
    Do not edit the lists directly. Run `check` when closing a batch of moves
    or reference changes, not after a query with no changes.
   If a decision is still missing, leave it in the inbox with the question pending.

## Give a place

When what is out of place is not an action, decide its location: knowledge to
its context/client/project card (`ztd-knowledge`), code to registered clones
(`ztd-repo`). When moving documents, update the links of the indexes and cards
that reference them; consolidate duplicates only after comparing contents and
keeping what is necessary. For physical materials, agree on a place and a
concrete action; do not declare a physical organization done from the agent.
Check that what was reorganized is findable through its indexes and summarize
the paths.

Summarize decisions, pending entries and the next step. For each source state
whether it was reviewed complete (within its scope), partial, unavailable or
left pending, with the interval/repositories consulted where applicable.
Reviewing a source does not mean emptying its backlog. Do not declare every
inbox processed if some were not consulted or keep pending decisions; an empty
local list is not enough.
