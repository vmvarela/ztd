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

*mcp* [*--read-only*] [*--scope* C]
	Run the stdio MCP server.

*version*
	Print version.

# EXIT STATUS

0 success, 1 domain error, 2 usage.

# SEE ALSO

*docs/spec.md* in the source distribution.
