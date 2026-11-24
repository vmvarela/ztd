---
name: Plan with ZTD
description: Choose a small ordered daily or weekly plan from existing tasks.
---

The SQLite database is canonical (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`). Never infer a database from the working directory. Use `ztd status --json` to resolve the binding. A repository binding is a routing hint; the host binding limits MCP access. Keep client content in its own scope.

# Plan

1. Read `ztd prepare`, the active goal when present, and the relevant tasks. Dates default to the configured timezone (`ztd settings --timezone Europe/Madrid`). A plan and a goal are optional.
2. Read daily or weekly plans using `plan_show` or `ztd plan show --kind daily|weekly --period PERIOD`. Use YYYY-MM-DD for days and YYYY-Www for weeks. Read previous reviews using `review_show` or `ztd review show --scope S --kind weekly --period PERIOD`.
3. Choose a short ordered list of task IDs: normally up to three daily priorities, a few weekly priorities. An empty plan is valid. Do not duplicate task text or copy unfinished work automatically.
4. Save with `ztd plan set --kind daily --period YYYY-MM-DD --item ID --expected REV` (repeat --item), or `commit_plan`. The service assigns daily/weekly roles; new callers need not manage them. More than three daily priorities requires `exception_reason` (`--exception-reason`).
5. Scope-limited reads are partial. Preserve hidden tasks; the service retains them on partial updates and counts them toward the daily limit. Exception reasons can only be changed from the full plan binding.
6. Record real progress with task updates and checkpoints. Completion is read from the task, never from a second plan checkbox. Mark the plan routine done only after planning occurred.

Use one optional active goal. New subgoal hierarchies are unnecessary: projects express multi-step outcomes and tasks their next actions. Ask only for decisions or capacity information that is actually missing.
