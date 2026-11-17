---
name: Knowledge with ZTD
description: Store sourced topic knowledge and consult the cards that apply to a task's context, client and project.
---

# Knowledge

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Use the store indexes; re-read them
only when context is missing or they changed.

## Consult before executing

1. Resolve the task scope: context, client when one is known, and project if
   any. The store configuration only decides whether a missing client blocks
   (`requireClientFor`); a known client is always used, even when optional.
   When neither the request nor the task gives a scope, default from a valid
   `data.binding` (`ztd status --json`): its context, its non-null client (a
   known optional client is kept) and its project. A malformed binding means
   stop and ask before scope-based work; binding is a routing hint, not
   authorization and never a root source.
2. Read the context, client and project indexes in that order. Follow their
   links to relevant cards and read their operational parts in full, including
   state, scope and limits; titles are not enough. Read separate/linked history
   only when it affects the decision; without an explicit split, read the whole
   card. Do not preload other branches. Knowledge from one scope is not read,
   cited or reused in another, including examples and delegations.
3. Contrast currency, scope and sources. Prefer current evidence and rules
   specific to the scope; explain unresolved conflicts.
4. Apply what is relevant and cite the cards used in the result. If there are
   no cards, say so briefly and work with the project's documentation and the
   available sources.

## learn <scope> <topic> <content or source>

1. Determine the most specific scope. Ask when client/project is ambiguous.
2. Look for existing cards on the topic to update instead of duplicating.
3. Read the available material. Use `templates/knowledge.md` to write a
   summary, when to apply it, steps/criteria, limits, source, date and status.
   Keep the operational guide short; link extensive evidence inside the same
   scope instead of copying chronologies. Do not cut exceptions or delete the
   existing history. If the source is inaccessible, record only what was
   provided and mark the rest unverified.
4. Store in the context, client or `projects/<project>/` per the global index.
   Create the needed indexes and link them from their parent; link the project
   index from its card. Use valid relative links from each file.
5. Keep the justification when replacing information; mark obsolete what should
   be. Do not turn one client's data into instructions for everyone.
6. If actions arise, capture each with `ztd capture` and keep their IDs in the
   card; knowledge is not another list. Do not write actions as free text in a note.
7. Summarize what was stored and which future tasks will use it. Knowledge
   lives in the cards of its scope; do not duplicate it into a shared auxiliary
   memory or turn it into instructions for other scopes.
