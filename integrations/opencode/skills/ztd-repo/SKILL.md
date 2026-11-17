---
name: Repositories with ZTD
description: Register projects, clone and sync repositories by context and client and locate the code to run tasks.
---

# Repositories

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Read the project index and the
relevant card; for registering or changing structure consult `README.md`.
Validate slugs (lowercase, numbers and hyphens), a registered scope and an
explicit registered URL; ask when missing. Each clone's path lives in its
project card (if the store defines a configurable repos root, validate against
it when it exists): never anchor it inside the store root and never escape `..`
or leave that path through symlinks.
Pass arguments as properly shell-quoted data.

## add <scope> <project> [URL]

Without a URL, ask; do not invent remotes or per-scope defaults.

1. The scope is `<context>` or `<context>/<client>`; if the scope requires a
   client and it is missing, or the URL is missing, ask. Register a new context
   or client explicitly requested in `contexts.md` and create its knowledge
   index linked from its context's index.
2. Create/update `lists/projects/<context>[/<client>]/<project>.md` from the
   template and link it from the index. Ask for the outcome when unknown;
   do not invent it.
3. Each clone's path is recorded in the project card, separate from the store
   root; if the store defines a configurable repos root, validate against it
   when it exists. For several repos agreed from the start use distinct paths;
   if a clone already exists at the project's path, choose differentiated
   sibling paths; never clone inside it.
4. If the destination exists, inspect its Git and remote: reuse only if they
   match; do not overwrite content or a clone from another source.
5. Create the parent and run `git clone` with the quoted URL and destination.
   Do not put credentials in the card. On failure, keep the record pending with
   the reason.
6. After success, check the Git root and remote; record the clone's real path,
   URL and state. Create the project knowledge index and link it from the
   parent and the card.
7. Read the clone's instructions and development guide before running code.

## list

Walk the cards and show ID, state, remote, path and clone presence. It does
not depend on clones being visible to searches that honor `.gitignore`.

## sync <project-ID>

Resolve its repos. Check that each path matches the expected repository,
remote and Git state. With local changes, a detached HEAD or a missing
upstream, explain the blocker without altering that state. With a clean tree
and a known upstream, run `git pull --ff-only`; if it diverges, report the
blocker. Never stash, reset, rebase or push as part of a sync.

## Resolve for focus

Return the card and the verified path; if the clone is missing use add with
the registered URL. Run tools with that path as the working directory. Data
changes stay in the store and code changes in the clone. Do not add gitlinks
or submodules to the store.
