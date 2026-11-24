---
name: Do with ZTD
description: Execute one task and preserve enough context to resume.
---

The SQLite database is canonical (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`). Never infer a database from the working directory. Use `ztd status --json` to resolve the binding. A repository binding is a routing hint; the host binding limits MCP access. Keep client content in its own scope.

# Do

1. Read the selected task and latest checkpoint (`ztd task show --id ID`). Otherwise read the plan and scoped next tasks, then select an executable action within the user's request. Do not execute blocked or closed tasks.
2. Search relevant knowledge in the task's scope and project; read the useful pages. There is no mandatory index traversal.
3. Work toward an observable result. For code, resolve the registered project clone and follow its repository instructions. External writes require authorization from the request, not merely a task's presence in the list.
4. Save a checkpoint with current state, evidence and next step using `checkpoint` / `ztd checkpoint`. A focus session is optional; neither focus nor a plan is required for a checkpoint.
5. Read the current task revision before patching. Use `task_update` with status `completed` or `cancelled` and a resolution; CLI: `ztd task done --id ID --expected REV --resolution TEXT`. Use `waiting` with `waiting_on` for a dependency, or `someday` for a possibility.
6. Report the actual result and next step. Keep task state canonical; do not maintain completion flags in knowledge or plan prose.
