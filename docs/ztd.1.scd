ztd(1)

# NAME

ztd - Markdown task manager for humans and agents

# SYNOPSIS

*ztd* [global options] <command> [command options]

# DESCRIPTION

*ztd* reads and edits plain Markdown task lists inside a *ztd/* directory.
Tasks are stored in *inbox.md*, *lists/next.md*, *lists/waiting.md*,
*lists/someday.md* and *lists/archive.md*. The binary never runs Git.

# GLOBAL OPTIONS

*--root* PATH
	Workspace root or the *ztd/* directory. Defaults to *ZTD_ROOT* or
	discovery from the current directory.

*--json*
	Machine-readable output. Errors are JSON too.

*--today* YYYY-MM-DD
	Inject the local date. Intended for tests.

*--dry-run*
	Do not write or create a journal.

# COMMANDS

*init* [PATH]
	Create missing workspace files. Never overwrites.

*capture* TEXT...
*--stdin*
	Append one task per argument or non-empty line.

*list* [*--context* C] [*--client* X] [*--project* P] [*--list* L]
	List active tasks. Without *--list*, archive is excluded.

*show* ID
	Show one task.

*move* ID LIST [*--text* T] [*--field* K:V] [*--unset* K] [*--expect-line* N]
	Move and transform a task. Moving out of archive is rejected.

*plan* *--context* C [*--client* X] [*--date* D]
	Read the daily plan and return the tasks of that context.

*check* [*--strict*]
	Validate the workspace. Exit 1 on errors.

*recover*
	Finish or reject an interrupted transaction.

*agent-capture* *--scope* S *--request* TEXT [*--project* P] [*--objective* T] [*--constraints* T] [*--idempotency-key* K] [*--db* PATH]
	Create an assignment in the agent store. Needs no Markdown workspace,
	rejects the global options and prints the JSON envelope by default.

*agent-checkpoint* ID *--scope* S *--expect-rev* N *--result* TEXT [*--kind* progress|done] [*--evidence* T] [*--next* T] [*--idempotency-key* K] [*--db* PATH]
	Record a checkpoint. A stale *--expect-rev* is *revision_conflict*; the
	same idempotency key with a different payload is *idempotency_conflict*.

*agent-prepare* ID *--scope* S [*--db* PATH]
	Read an assignment and its latest checkpoint; another scope is
	*scope_denied*.

*mcp* [*--read-only*] [*--scope* C] [*--agent-scope* S] [*--agent-db* PATH]
	Run the stdio MCP server. With *--agent-scope* only the three
	*ztd_agent_* tools are exposed and there are no resources; the scope is
	enforced server-side and is never a tool argument.

*version*
	Print version.

# EXIT STATUS

0 success, 1 domain error, 2 usage.

# SEE ALSO

*docs/spec.md* in the source distribution.
