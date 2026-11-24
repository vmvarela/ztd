---
name: Process with ZTD
description: Clarify captures into tasks, references or explicit decisions atomically.
---

The SQLite database is canonical (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`). Never infer a database from the working directory. Use `ztd status --json` to resolve the binding. A repository binding is a routing hint; the host binding limits MCP access. Keep client content in its own scope.

# Process

1. Read the selected local inbox (`ztd inbox next`, `ztd list --list inbox`). An explicit source review may also query registered sources with the authorized connector. A local inbox pass does not imply external coverage.
2. Clarify each capture: actionable work (`work_items`), useful information (`reference`), completed short action (`immediate` with evidence), discard with reason, or defer with a review date. A capture can create several tasks. Keep its scope and source provenance.
3. For information, use the knowledge workflow. Save the page and resolve the capture together through `process_capture.document`; do not coordinate two separate writes. The document belongs to the capture's scope. Existing pages can be linked with `document_id`.
4. For work, choose `next`, `waiting` with a dependency, or `someday`; attach an optional project, context and due date. Use actual source IDs to avoid importing the same work twice. External ticket status stays in its service.
5. Retry a lost response with the same key and identical payload. Read the stored outcome to resume. Leave unresolved captures pending or explicitly deferred; never invent a decision to empty the inbox.
6. Existing tasks use `task_update`, or `ztd task update --id ID --expected REV ...`. Read the current revision first. Empty project/context/due date clears that field. Do not edit SQLite or maintain a second task list.

Report decisions and unresolved entries. For external sources, distinguish complete, partial and unavailable coverage. Perform external writes only within the user's authorization. Mark the inbox routine done only after the requested full local pass actually finishes.
