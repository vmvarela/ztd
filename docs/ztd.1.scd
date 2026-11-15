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

*due*
	List routines whose cadence has elapsed.

*routine* *done* ID
	Record a routine run for today.

*agent-capture* *--scope* S *--request* TEXT [*--project* P] [*--objective* T] [*--constraints* T] [*--idempotency-key* K] [*--db* PATH]
	Create an assignment in the agent store. Needs no Markdown workspace,
	rejects the global options and prints the JSON envelope by default.

*agent-checkpoint* ID *--scope* S *--expect-rev* N *--result* TEXT [*--kind* progress|done] [*--evidence* T] [*--next* T] [*--idempotency-key* K] [*--db* PATH]
	Record a checkpoint. A stale *--expect-rev* is *revision_conflict*; the
	same idempotency key with a different payload is *idempotency_conflict*.

*agent-prepare* ID *--scope* S [*--db* PATH] [*--history* N]
	Read an assignment and its latest checkpoint; another scope is
	*scope_denied*. With *--history* N also return up to N checkpoints
	newest-first by revision; N is a positive integer.

*agent-remember* *--scope* S *--kind* fact|decision|constraint|procedure *--text* TEXT [*--source* T] [*--idempotency-key* K] [*--db* PATH]
	Store one knowledge record in its scope at revision 1. An unknown
	*--kind* is *invalid_argument*; the idempotency key replays like
	*agent-capture*.

*agent-recall* *--scope* S *--query* TEXT [*--limit* N] [*--db* PATH]
	Full-text search over the knowledge of one scope, best match first
	(bm25), at most N records (default 20; N must be a positive integer,
	*--limit* 0 is a usage error). Another scope returns an empty list; a
	malformed query is *invalid_argument*.

*agent-export* *--out* FILE [*--db* PATH]
	Write every scope, assignment, checkpoint, idempotency log entry and
	knowledge record as a versioned JSON export (*format*
	*ztd-agent-export*, *version* 2).

*agent-restore* *--from* FILE [*--db* PATH]
	Import an export (version 1 or 2; version 1 carries no knowledge) into
	an empty store. A non-empty store, a different format, an unknown
	version, or a corrupted file is *invalid_argument*; counts and
	revisions are verified in one transaction, so a refusal writes
	nothing. Returns the inserted counts.

*agent-backup* *--out* FILE [*--db* PATH]
	Copy the store into a new single file (*VACUUM INTO*). An existing
	file is never overwritten; the copy opens and passes the schema gate.

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
