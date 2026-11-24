---
name: Review with ZTD
description: Review one scope and save the outcome as a readable document.
---

The SQLite database is canonical (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`). Never infer a database from the working directory. Use `ztd status --json` to resolve the binding. A repository binding is a routing hint; the host binding limits MCP access. Keep client content in its own scope.

# Review

1. Select one scope and period. Read its tasks, daily/weekly plans and previous review. Update external coverage only when requested or needed; unavailable access is not an empty inbox.
2. Review completed results, waiting dependencies and unfinished priorities. Decide whether to continue, change or cancel commitments. Do not roll tasks forward automatically or infer achievements.
3. Save `ztd review save --scope S --kind weekly --period YYYY-Www --outcomes TEXT --coverage TEXT`, or `record_review` with scope. The review is a document, not a parallel state table.
4. Read it with `review_show` or `ztd review show --scope S --kind weekly --period YYYY-Www`. Global summaries may report coverage without copying client details. Legacy reviews without a clear scope remain restricted until explicitly reconciled.
5. Mark a review routine done only after the review occurred. Routines are optional recurring reminders; do not generate duplicate task trees. Journal, routine guidance and reflections can use ordinary `doc` pages with their purpose and revision.
6. Capture agreed actions, link their IDs, and plan the next period only when useful. Keep the review brief: outcome, learning, decisions and coverage.
