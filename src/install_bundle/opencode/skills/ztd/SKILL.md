---
name: ZTD
description: Orient the Zen To Done system of the task store, consult its state and pick the next habit or procedure.
---

# ZTD

Every path in the ZTD skills is relative to the store root, but the task
store is the SQLite database: it resolves as `--db` > `ZTD_DB` > `~/.ztd/ztd.db`;
never derive it from the current directory or look for a `ztd/` from the
working directory. The Markdown files under `~/.ztd` are a read-only legacy
backup, not the task store. `ztd status --json` reports `database`, `profile`,
`actor`, `scopes`, `effective_scopes`, `binding` and `warning` — without
creating files (step 2). Do not use this skill's directory as the store.

1. For initial orientation, run `ztd status` and `ztd --help`; for the
   adoption habit read `ztd doc get --kind adoption --slug adoption`. Neither
   is a prerequisite for each operation.
2. Resolve the environment with `ztd status --json`: it never creates files
   (it works when the database is absent). It reports `database` (the
   resolved SQLite path), `profile`, `actor`, `scopes` (declared),
   `effective_scopes` (what a command sees with no explicit `--scope`, after
   `ZTD_SCOPES` and the `.ztd.json` hint), `binding` and `warning`.
   `data.binding` is the raw `.ztd.json` object or `null`, read from the
   current Git repository only; `data.warning` explains a missing or
   malformed file, so a malformed nearest binding is reported and never falls
   through to another file. The binding is a routing hint, not authorization,
   and it never changes the store database (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`
   stays independent of the cwd and of the binding). An explicit request scope
   or the selected task's scope always wins; only when no scope exists
   anywhere and the binding is valid, default the filters to its context, its
   non-null client (a known optional client is kept) and its project, where
   the CLI supports them. If the binding is malformed, stop and ask before any
   scope-based work. `ztd check --bindings` validates the selected repo
   binding against the resolved store and fails when it is missing or invalid.
   Then use `ztd list`, `ztd show` and `ztd plan` for task state, filtered to
   the resolved scope, the goal and today's plan if any.
   `ztd source list --all` summarizes coverage globally, without client
   details. Do not open every card or
   create empty plans.
3. When the intent is already clear, load the specific skill directly with no
   preliminary tour:

| Need | Skill |
| --- | --- |
| Capture | `ztd-collect` |
| Decide on entries or give them a place | `ztd-process` |
| Daily, weekly or goal plan | `ztd-plan` |
| Execute | `ztd-do` |
| Keep lists trustworthy | `ztd-trusted-system` |
| Review, journal, routines or interests | `ztd-review` |
| Reduce commitments | `ztd-simplify` |
| Projects and clones | `ztd-repo` |
| Store and apply knowledge | `ztd-knowledge` |

4. When executing, apply the request and summarize files/results. In Plan mode,
   discuss the changes while respecting its restrictions. Do not switch the agent.
5. Keep one canonical source per task, references by ID and gradual adoption.
   Do not impose filling in every section or a split across clients.

If data is missing to act, ask only what is needed for the next step.
