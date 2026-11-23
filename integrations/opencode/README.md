# OpenCode adapter for ZTD

This folder is only an adapter: the neutral method lives in
[`../../method/README.md`](../../method/README.md). Here are the generic
OpenCode assets — the skills — that apply
the method on the task store (store root `~/.ztd`).

## What is included

| Path | Contents |
| --- | --- |
| `skills/` | The 10 ZTD skills: `ztd` and its nine helpers (`ztd-collect`, `ztd-process`, `ztd-plan`, `ztd-do`, `ztd-review`, `ztd-trusted-system`, `ztd-simplify`, `ztd-knowledge`, `ztd-repo`) |

The bundle no longer ships Markdown commands: the skills carry the whole
circuit and the host's native roles cover its permissions. `/ztd:*` prompts
keep coming from the MCP server. An older install may leave `agents/ztd.md`
and the ZTD-specific command files (`commands/ztd.md` and
`commands/ztd/*.md`) in place. This installer does not remove them. If
cleaning up manually, remove only files that still match the old ZTD defaults;
preserve edited or user-added files and unrelated commands.

## Install globally

With the binary on your `PATH`, publish the embedded assets to
`$HOME/.config/opencode/skills`:

```bash
ztd install opencode
```

It preflights the complete bundle before writing, and any differing file,
symlink or unexpected file type aborts the whole run without overwriting
anything. A hidden `.ztd-assets.json` manifest records every path it wrote, so
later runs upgrade those files and refuse one you edited. There is no
per-project mode: copy `skills/` into that project's
`.opencode/` tree by hand. It never initializes the store or modifies OpenCode
configuration.

### 1. Store and templates (prerequisite)

Prerequisite: an initialized store. `ztd init` creates the global store at
`~/.ztd` by default; `--db PATH` chooses another root. It does not seed the
templates: publish the six method templates with `ztd install templates`,
which writes them into `<store>/templates/` — the directory of `--db`. This
block uses an explicit root:

```bash
# from the root of this repository
STORE="$HOME/.ztd"             # explicit store root (edit it if you use another)
ztd --db "$STORE/ztd.db" init  # creates the store (asks for actor and scopes)
ztd --db "$STORE/ztd.db" install templates
```

After upgrading the binary, `ztd install templates` refreshes the six templates
in an existing store root; it never creates the store and refuses a template
you edited.

Slash commands are not part of this bundle: `ztd install opencode` installs
the skills globally, and for project-only discovery copy the same `skills/`
directory into that project's `.opencode/` tree. Never copy assets into a
task-data directory: only the store lives there. Any legacy path that
remains in the prose (`lists/…`, `goals/…`) refers to the read-only Markdown
backup; the task store is the SQLite
database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db`.

Requirements: the `ztd` binary on the `PATH`, the database resolved
(`--db` > `ZTD_DB` > `~/.ztd/ztd.db`) and initialized (step 1).

## Store root and binding

- The task store is a SQLite database. It resolves as `--db` > `ZTD_DB` >
  `~/.ztd/ztd.db`, never from the current directory; the Markdown files under
  the store root are a read-only legacy backup, not the task store.
- A repository's `.ztd.json` contains exactly `{context, client, project}`.
  The CLI discovers the nearest file up to the current Git repository
  boundary, reports it in `status` as `binding` (the raw object or `null`,
  with `warning` for a missing or malformed file), and validates it strictly
  with `check --bindings`.
  The binding is a routing hint, not authorization; explicit user scope is
  authoritative. It contains no task, clone-path, or repository-URL data.
  Each clone's local path lives in its project card.
- The paths cited by the skills are store-root paths (the legacy
  backup), not this repository's.

## State contract

`ztd status [--json]` reports `database` (the resolved SQLite path),
`profile`, `actor`, `scopes` (declared), `effective_scopes` (the default
binding after `ZTD_SCOPES` and the `.ztd.json` hint), `binding` and `warning`.
`binding` is the raw `.ztd.json` object or `null`; `warning` explains a
missing or malformed file, and a malformed nearest binding never falls
through to another file. `ztd check --bindings` is the strict validator:
exactly `{context, client, project}`, discovered within the current Git
repository boundary. Status never creates files and works when the database
is absent. Use a valid binding as a default task scope only when the request
supplies none; explicit user scope remains authoritative. Task state still
comes from `list`, `show` and `plan`.

## Adapter rules

- One list writer: task mutations go through the `ztd` CLI (`capture`,
  `move`); list entries are never edited by hand.
- The skills do not authorize external writes (push, publications, sends to
  services) nor destructive ones, and they do not replace the host's native
  roles (`build`, `plan` and the rest keep their configuration and
  permissions).
- These assets carry no local policy and no user or client data: contexts are
  declared with `ztd context add` in the store database.
