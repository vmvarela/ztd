ztd(1)

# NAME

ztd - Markdown task manager for humans and agents

# SYNOPSIS

*ztd* [global options] <command> [command options]

# DESCRIPTION

*ztd* reads and edits plain Markdown task lists in the store, a directory of
task data. The store root resolves as *--root*, *ZTD_ROOT*, then *~/.ztd*; it
is never discovered from the current directory. Tasks are stored in
*inbox.md*, *lists/next.md*, *lists/waiting.md*, *lists/someday.md* and
*lists/archive.md*, relative to that root. The binary never runs Git.

# GLOBAL OPTIONS

*--root* PATH
	Store root (exact path). Defaults to *ZTD_ROOT*, then *~/.ztd*.

*--json*
	Machine-readable output. Errors are JSON too.

*--today* YYYY-MM-DD
	Inject the local date. Intended for tests.

*--dry-run*
	Do not write or create a journal.

# COMMANDS

*init* [PATH] [*--local*]
	Create missing store files at *~/.ztd* by default, at exactly *PATH*
	when given, or at *./ztd* with *--local*. Never overwrites.

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

*check* [*--strict*] [*--bindings*]
	Validate the store. With *--bindings*, also validate the current repository's
	*.ztd.json*. Exit 1 on errors.

*migrate* *--from* SOURCE *--to* DEST [*--dry-run*]
	Copy and convert a format-1 store into a new format-2 store. Both paths are
	explicit exact directories; the destination must not exist. The source is
	never modified. The converter refuses ambiguous formats, malformed data,
	collisions and unsafe paths.

*recover*
	Finish or reject an interrupted transaction.

*due*
	List routines whose cadence has elapsed.

*routine* *done* ID
	Record a routine run for today.

*tui*
	Open a read-only terminal browser for the store. It starts on Today: the
	active goal from *goals/active.md* plus today's MITs from the daily plan.
	The left tree lists
	every task group, project, plan, review, knowledge card, journal entry
	and routine; the right pane shows the selected document. Keys: arrows or
	*j*/*k*, *enter* to expand a group or open an item in a tab, *[* and *]*
	to cycle tabs, *x* to close one, *tab* to switch panes, */* to filter,
	*t* to cycle theme, *z* for zen reading mode, *?* for help, *q* to quit.
	Today is pinned and up to eight more documents stay open; the tab strip
	hides below 100 columns. Themes are *paper*, *tea* and *amber*, set with
	the *tui.theme* key of *config.json* (absent or invalid falls back to
	*paper*). The mouse scrolls, selects rows, clicks tabs and drags the
	divider between panes. The tree refreshes once a second when store files
	change, and the command never writes or holds the store lock. The
	interface is in English; documents keep their original language.

*status* [*--json*]
	Show the store root resolved by precedence, its source (*flag*,
	*env* or *home*), whether the store exists and its *config.json*
	format, plus the current repository binding. *--json* returns
	(*root*, *source*, *exists*, *format*, *binding*) in that order. A missing or
	malformed binding does not suppress root information. Never creates files;
	works when the store is absent.

*agent-capture* *--scope* S *--request* TEXT [*--project* P] [*--objective* T] [*--constraints* T] [*--idempotency-key* K] [*--db* PATH]
	Create an assignment in the agent store. Needs no Markdown store,
	rejects *--root*, *--today* and *--dry-run*, accepts *--json*, and
	prints the JSON envelope by default.

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

*version*
	Print version.

# EXIT STATUS

0 success, 1 domain error, 2 usage.

# SEE ALSO

*docs/spec.md* in the source distribution.
