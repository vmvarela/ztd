---
name: Simplify with ZTD
description: Review commitments and tasks to keep the essentials and reduce overload.
---

# Simplify

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Read the goal and relevant
projects; query the lists with `list` filtered by context, client and project
of the requested scope. With no scope anywhere, default those filters from a
valid `data.binding` (`ztd status --json`); a malformed binding means stop and
ask first — a routing hint only, never a root source.

1. Look for stale, duplicated, dispensable, delegable or uncommitted tasks.
2. Contrast with the goal and existing obligations; do not drop a client
   obligation just because it does not contribute to the personal goal.
3. Apply the user's explicit decisions; for unknown priorities propose a few
   concrete decisions and ask to resolve them before dropping commitments.
4. Move to archive, waitings or someday keeping IDs, reason and useful
   information.
5. Batch small tasks in plans without duplicating their canonical state.
6. Summarize what was reduced and the remaining focus. Do not set per-context
   quotas, project limits or arbitrary deletion targets.

Capture stays free: simplify after noting things down, not before.
