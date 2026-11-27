---
name: Do with ZTD
description: Execute a task in focus, personal or code, applying the knowledge of the context and the project.
---

# Do

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. A day plan is not a requirement.
With a known scope, query `ztd plan --context CONTEXT`, not the full plan. The view is partial and does not identify priorities; do not infer that a
reference is a MIT.

When the request and the selected task give no scope, `ztd status --json` may
supply default filters from `data.binding` (valid `{context, client, project}`
only, discovered in the current Git repository); a malformed binding means
stop and ask before any scope-based work. The binding is a routing hint, not
authorization, and it never changes the store root.

1. Resolve `ztd show ID` or query `list --list next` with the known context
   and project filters (a known client is its own `--scope`)
   — or the defaults from a valid `data.binding`
   when no scope exists anywhere. Without a selection, if today's plan exists
   (`ztd prepare` reports it in `data.plan`), propose one of those IDs; otherwise pick an
   executable MIT whose priority you know, or propose a clear next action. Do
   not infer MITs from the `ztd plan` ID dump. In a global selection do not dump
   client details; ask only when there is no clear candidate. Do not execute
   closed or blocked tasks.
   "What should I do now?" proposes an action and offers to start; it does not
   start work without execution intent nor trigger a global external review.
2. Define an observable outcome and a small first step; keep a single task.
3. Before executing, walk this task's knowledge index for its scope
   (`ztd doc get --kind knowledge_index`, links resolved with
   `ztd doc related`) and read only the relevant cards.
   Load `ztd-knowledge` only when knowledge must be stored or procedure doubts
   resolved.
4. For code, resolve the path from its project record (`ztd project show ID`,
   field `clone_path`): clone and work inside that path, with no `..` escapes or
   symlinks out of it; check the Git root and expected remote.
   Load `ztd-repo` only to register, clone or sync, not to locate an existing clone.
   Read its instructions, Git state and development guides; point the tools at
   the clone and run the checks that fit its changes.
   On continuations, reuse readings and checks while they stay valid for the
   same code, entries, environment and scope; repeat only what was invalidated
   or the project requires. Revalidate changing remote states and identity
   before operating; reusing evidence does not replace authorizations or
   security controls.
5. Execute until done or a concrete blocker. Before any external write (push,
   publication, comment, send or remote close) or destructive action (delete,
   reset, mass overwrite) ask the user for concrete authorization: this skill is
   safe on its own and does not rely on the `ztd` agent being selected. Capture
   interruptions in the inbox without changing focus. For physical actions,
   guide the user and wait for evidence of completion before marking them done.
6. Record the real outcome with
   `ztd move ID archive --field 'resolution: completed — <evidence>'`
   (and the needed context fields), or `ztd move ID waiting --field 'waiting_on: ...'`.
   Do not archive when the result has no observable evidence; keep the task in
   `next` and say what is missing. For partials, keep the ID and update the
   next step with `ztd move ID next --text '...'`; never duplicate the task or
   edit the list by hand. `ztd` verifies the move; run `check` when you changed
   references or structure, not to repeat a validation already in force.
7. There is no command to annotate a committed plan: keep a short wrap-up
   (outcome, checks and limits) in the reply and link the detailed scope
   record if any, without repeating its chronology.
   Keep task state only in its canonical list and avoid copying the same detail
   across plan, record and memory. Store reusable learning via `ztd-knowledge`
   when there is any, respecting scope isolation.

Report what was done, what knowledge was applied and what is missing. Commits
in a clone belong to its Git; do not imply they are published because code was
edited.
