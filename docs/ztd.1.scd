ztd(1)

NAME
	ztd - local task system for one person working with an AI agent

SYNOPSIS
	*ztd* [_global options_] _command_ [_flags_]

	*ztd* _init_ [--actor A] [--non-interactive] [--scope DECL]...
	*ztd* _install_ _opencode|templates_ [--dry-run]
	*ztd* _capture_ _TEXT_... [--scope S] [--source ID] [--key K] [--stdin]
	*ztd* _process_ --outcome K [--title T] [--expected N] _ID_
	*ztd* _list_ [--list inbox|next|waiting|someday|archive] [--context C] [--project P] [--scope S]
	*ztd* _move_ [--text T] [--field k:v]... [--waiting-on W] [--resolution R] [--closure completed|cancelled|unspecified] [--expected N] [--key K] _ID_ _LIST_
	*ztd* _goal_ _set --statement S_ | _show_ | _complete|cancel_ [--scope S]
	*ztd* _plan commit_ --period P --item ID:role
	*ztd* _review_ _daily|weekly|monthly|yearly_
	*ztd* _routines_ _due|done_ _ID_ | _add_ --id ID --cadence daily|weekly:<day> [--last YYYY-MM-DD]
	*ztd* _status_ [--json]
	*ztd* _check_ [--scope S] [--bindings]
	*ztd* _mcp_ [--scope S] [--allow-delete-source]

DESCRIPTION
	*ztd* stores commitments, plans and continuity in one SQLite database
	so an agent can resume work without replaying a conversation. Every
	command reads and writes the same database; nothing contacts a network
	service. Scopes separate personal, open-source and client work inside
	one file, and a binding narrows which scopes a command can see.

GLOBAL OPTIONS
	Recognized anywhere on the command line, before or after the command.

	*--db* _PATH_
		Database file. Defaults to *ZTD_DB*, else ~/.ztd/ztd.db.
	*--json*
		Print the result as a JSON envelope with *ok*, *command* and
		*data* or *error*; errors carry a stable family such as
		*invalid_input*, *conflict* or *not_found*.
	*--actor* _NAME_
		Owner actor for mutations. Defaults to *USER*, else "operator".
	*--help*, *-h*
		Print the usage summary and exit.

COMMANDS
	SETUP AND ASSETS

	*init* [--actor A] [--non-interactive] [--scope DECL]...
		Declare the database's scopes; interactive on a terminal,
		flags in scripts. DECL is id=salud,kind=personal,name=Salud.
	*install opencode* [--dry-run]
		Publish the embedded skills to
		~/.config/opencode/skills.
	*install templates* [--dry-run]
		Publish the method templates to <store>/templates/, where
		<store> is the directory of --db. The store must exist.
		Both installs preflight the whole bundle and refuse to
		overwrite a file you edited.
	*scope add --id ID --kind KIND* [--name NAME] | *scope list*
	*context add NAME* [--scope S] | *context list* [--scope S]

	CAPTURE AND PROCESS

	*capture TEXT...* [--scope S] [--source ID] [--key K] [--stdin]
		Store text in the inbox without filtering it.
	*inbox next* [--scope S]
		Return the oldest pending capture.
	*process --outcome K* [--title T] [--expected N] _ID_
		Turn a capture into work items, a reference, an immediate
		result, a defer or a discard.
	*show ID* | *find QUERY*
	*list* [--list inbox|next|waiting|someday|archive] [--context C] [--project P] [--scope S]
	*move* [--text T] [--field k:v]... [--waiting-on W] [--resolution R] [--closure completed|cancelled|unspecified] [--expected N] [--key K] _ID_ _LIST_
		Move a work item; LIST is next, waiting, someday or archive.

	PLANNING AND FOCUS

	*prepare* [--scope S] [--date YYYY-MM-DD]
	*plan* [--context C] [--date D] [--scope S]
		Read-only brief: active goal, committed MITs, candidates.
	*plan commit* --period P --item ID:role
		Commit a daily or weekly plan; repeat --item for each item.
	*goal set --statement S* | *goal show*
	*goal complete* | *goal cancel* [--scope S]
		Close the active primary goal as completed or cancelled, so
		a new primary can be set. Repeating the same close is
		idempotent; the other status is invalid_transition.
	*focus start ID* | *focus checkpoint ID* | *focus finish FOCUS*
	*review daily|weekly|monthly|yearly*
	*due* [--date YYYY-MM-DD]
		Alias of routines due.
	*routines due|done ID* [--date YYYY-MM-DD]
	*routines add --id ID --cadence daily|weekly:<day>* [--last YYYY-MM-DD]
		Track recurring routines; add registers one in the binding's
		primary scope. *routine done* and *routine add* are aliases.

	SOURCES, DOCUMENTS AND PROJECTS

	*source add --id ID --name NAME --scope S --kind capture|calendar --connector manual|directory|host_mcp*
	*source apply* [--file PATH] | *source list* [--all | --scope S...]
	*source review --source ID --batch B --key K --file FILE*
	*source delete --id ID*
	*doc put --kind K --slug S* [--scope X] [--title T] [--body TEXT | --file PATH] [--status draft|verified|superseded] [--expected N]
	*doc get|list|search|related|log|lint|archive*
		Read and maintain the document layer (knowledge cards, plans,
		reviews, ...). See the usage output for each form.
	*project add ID* [--scope S] [--desired-outcome TEXT] [--status active|paused|completed|cancelled] [--repo-url URL] [--clone-path PATH]
	*project list* [--scope S] | *project show ID* [--scope S]

	STORE AND ENVIRONMENT

	*status* [--json]
		Report database, profile, actor, scopes, effective scopes
		and the .ztd.json binding; never creates the database.
	*check* [--scope S] [--bindings]
		Verify database invariants, or validate the .ztd.json hint.
	*export --out FILE* | *restore --from FILE* | *snapshot --out FILE*
		Export requires a new path and never replaces a file.
	*recover*
		Compatibility no-op; SQLite has no Markdown journal.
	*migrate*
		Not in this binary: the Markdown importer ships with the archived Go
		build, tagged v2-go-final.
	*version*
		Print the version.
	*mcp* [--scope S] [--allow-delete-source]
		Run the local stdio MCP server for an agent. delete_source is served only
		with --allow-delete-source, and only where the host gates it with a real
		approval prompt.

ENVIRONMENT
	*ZTD_DB*
		Database path; same as --db.
	*ZTD_SCOPES*
		Comma-separated scope ids narrowing the binding, tried
		after --scope and before the .ztd.json hint.
	*ZTD_SOURCES*
		Source configuration path; default ~/.ztd/sources.json.
	*USER*
		Default actor when --actor is absent.

FILES
	~/.ztd/ztd.db
		The database (default path).
	~/.ztd/
		Legacy Markdown store: a read-only backup, not the task
		store. install templates publishes into its templates/.
	.ztd.json
		Routing hint {context, client, project} in the working
		directory, discovered up to the Git repository boundary;
		never a source of authorization.
	~/.config/opencode/
		Target of install opencode (skills).
	~/.ztd/sources.json
		Default source configuration (see ZTD_SOURCES).

EXIT STATUS
	*0*
		Success.
	*1*
		Error; a stable family (*invalid_input*, *conflict*,
		*not_found*, ...) is printed or returned in the JSON
		envelope.
	*2*
		No command given; the usage summary is printed.

EXAMPLES
	Declare the initial scopes:

		ztd init --actor victor --scope id=personal,kind=personal

	Capture and inspect:

		ztd capture "call the plumber on Monday"
		ztd inbox next

	Publish the OpenCode assets and the method templates:

		ztd install opencode
		ztd install templates

	Close the active goal and register a routine:

		ztd goal complete
		ztd routines add --id inbox --cadence daily

AUTHORS
	Maintained by vmvarela <vmvarela@gmail.com>.

SEE ALSO
	Project repository: https://github.com/vmvarela/ztd
