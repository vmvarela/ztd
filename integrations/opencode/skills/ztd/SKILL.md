---
name: ZTD
description: Orient the Zen To Done system of the task store, consult its state and pick the next habit or procedure.
---

# ZTD

Every path in the ZTD skills is relative to the store root: the task-data
directory. The root resolves as `--root` > `ZTD_ROOT` > `~/.ztd`; never derive
it from the current directory or look for a `ztd/` from the working directory.
`ztd status [--json]` reports that root, its source (`flag`/`env`/`home`),
whether the store exists and its format, without creating files. Do not use
this skill's directory as the root.

1. For initial orientation, read `adoption.md`; for formats or structural
   changes, `README.md` (both at the store root). Neither is a prerequisite
   for each operation.
2. Resolve and verify the root with `ztd status --json`: it reports `root`,
   `source` (`flag`, `env` or `home`), `exists` and `format`, and never creates
   files (it works when the store is absent). Then use `ztd list`, `ztd show`
   and `ztd plan` for task state, filtered to the requested scope, the goal and
   today's plan if any. A global state summarizes coverage without client
   details. Do not open every card or create empty plans.
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
