---
name: Repositories with ZTD
description: Register projects, clone and sync repositories by context and client and locate the code to run tasks.
---

# Repositories

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Read the projects with `ztd project list` and
`ztd project show ID`; for registering or changing structure consult `ztd --help`.
Validate slugs (lowercase, numbers and hyphens), a registered scope and an
explicit registered URL; ask when missing. Each clone's path lives in its
project record (`ztd project show ID`): never anchor it inside the store root and never escape `..`
or leave that path through symlinks.
For any repo operation with no explicit scope, a valid `data.binding` from
`ztd status --json` (exactly `{context, client, project}`, discovered within
the current Git repository, with a malformed nearest binding reported and
never falling through) may supply the default scope; a malformed binding means
stop and ask before scope-based work. The binding is a routing hint, not
authorization, and it never changes the store root.
Pass arguments as properly shell-quoted data.

## add <scope> <project> [URL]

Without a URL, ask; do not invent remotes or per-scope defaults.

1. The scope is `<context>` or `<context>/<client>`; if the scope requires a
   client and it is missing, or the URL is missing, ask. Register a new context
   with `ztd context add NAME --scope S` or a client with `ztd scope add --id
   client:NAME --kind client`, and create its knowledge index (`ztd doc put
   --kind knowledge_index`) linked from its context's index.
2. Create the project record with `ztd project add <id> --scope S
   [--desired-outcome TEXT] [--repo-url URL] [--clone-path PATH]`; a project
   note, when needed, is `ztd doc put --kind project_note`. Ask for the
   outcome when unknown; do not invent it.
3. Each clone's path is recorded in the project record (`ztd project show ID`),
   separate from the store
   root; if the store defines a configurable repos root, validate against it
   when it exists. For several repos agreed from the start use distinct paths;
   if a clone already exists at the project's path, choose differentiated
   sibling paths; never clone inside it.
4. If the destination exists, inspect its Git and remote: reuse only if they
   match; do not overwrite content or a clone from another source.
5. Create the parent and run `git clone` with the quoted URL and destination.
   Do not put credentials in the card. On failure, keep the record pending with
   the reason.
6. After success, check the Git root and remote against the project record
   (`ztd project show ID`); there is no project-update command, so the agreed
   `--clone-path` is registered before cloning and a different configuration
   on re-add is `conflict`. Create the project knowledge index (`ztd doc put
   --kind knowledge_index`) and link it from the
   parent and the note.
7. Read the clone's instructions and development guide before running code.

## bind — explicit repo binding/setup only

Create or update `.ztd.json` only when the user explicitly requests a repo
binding/setup, and only after the repository identity and the scope
(`context`, `client` when it applies, `project`) are confirmed with them. The
file holds exactly the three keys `context`, `client` and `project` — no path,
no URL. If the existing binding is identical, do nothing. If it differs, stop
and ask for a decision; never overwrite it. Validate with `ztd check --bindings`,
which checks the selected repo binding against the resolved store and fails
when it is missing or invalid.

## list

Use `ztd project list` (and `ztd project show ID` for one) to show ID, state,
remote, path and clone presence. It does
not depend on clones being visible to searches that honor `.gitignore`.

## sync <project-ID>

Resolve its repos. Check that each path matches the expected repository,
remote and Git state. With local changes, a detached HEAD or a missing
upstream, explain the blocker without altering that state. With a clean tree
and a known upstream, run `git pull --ff-only`; if it diverges, report the
blocker. Never stash, reset, rebase or push as part of a sync.

## Resolve for focus

Return the project record (`ztd project show ID`) and the verified path; if the clone is missing use add with
the registered URL. Run tools with that path as the working directory. Data
changes stay in the store and code changes in the clone. Do not add gitlinks
or submodules to the store.
