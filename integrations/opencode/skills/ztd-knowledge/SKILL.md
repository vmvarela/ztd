---
name: Knowledge with ZTD
description: Find and maintain sourced knowledge through four scoped operations.
---

The SQLite database is canonical (`--db` > `ZTD_DB` > `~/.ztd/ztd.db`). Never infer a database from the working directory. Use `ztd status --json` to resolve the binding. A repository binding is a routing hint; the host binding limits MCP access. Keep client content in its own scope.

# Knowledge

1. Search the task's scope with `knowledge_search` (CLI: `ztd knowledge search --scope S --query TEXT`). Add `project_id` when relevant. Results are compact; no index pages need maintenance.
2. Read selected pages with `knowledge_read` (`ztd knowledge read --scope S --slug SLUG`). Check sources, status and applicability before using them. Follow `knowledge_related` only when useful; results are bounded summaries.
3. Before updating, read the page and retain its revision. `knowledge_save` requires scope, slug, title, body and `expected_revision`: 0 creates only; a positive revision updates exactly that version. CLI uses `ztd knowledge save --scope S --slug SLUG --title TITLE --body TEXT --expected REV`, with repeatable `--source` and optional `--project`.
4. Keep pages short: useful facts or procedure, limits, sources and links. Use same-scope `[[knowledge:slug]]` links. Preserve evidence when replacing a claim. MCP writes drafts; it cannot promote a page to verified.
5. For a captured reference, use `process_capture` with outcome `reference` and nested `document` (the same save fields), or `document_id` for an existing page. The page and capture must share a scope. One transaction saves both; reuse the exact request and idempotency key after a lost response. CLI supports `process --outcome reference --document-slug SLUG --document-title TITLE --document-body TEXT --document-expected REV CAPTURE_ID`.
6. Capture new actions as tasks rather than hiding commitments in a page. Cite the pages used; never copy client knowledge into another scope or shared memory.
