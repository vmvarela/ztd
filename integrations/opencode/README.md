# OpenCode adapter for ZTD

> **Go rewrite caveat:** the Go rewrite does **not** implement
> `ztd install opencode` or `ztd install templates`. The commands described
> below belong to the previous Zig CLI. Until the install command is ported,
> copy `integrations/opencode/` into `~/.config/opencode/` manually
> (`skills/` → `~/.config/opencode/skills/`, `commands/` →
> `~/.config/opencode/commands/`).

This folder is only an adapter: the neutral method lives in
[`../../method/README.md`](../../method/README.md). Here are the generic
OpenCode assets —skills and commands— that apply
the method on the task store (store root `~/.ztd`).

## What is included

| Path | Contents |
| --- | --- |
| `skills/` | The 10 ZTD skills: `ztd` and its nine helpers (`ztd-collect`, `ztd-process`, `ztd-plan`, `ztd-do`, `ztd-review`, `ztd-trusted-system`, `ztd-simplify`, `ztd-knowledge`, `ztd-repo`) |
| `commands/` | `/ztd` plus the nested `/ztd/collect`, `/ztd/inbox`, `/ztd/plan`, `/ztd/focus`, `/ztd/week`, `/ztd/goal`, `/ztd/journal`, `/ztd/routine`, `/ztd/simplify`, `/ztd/learn`, `/ztd/repo`, `/ztd/review` |

The `ztd` agent is no longer part of the bundle: the skills carry the whole
circuit and the host's native roles cover its permissions. An
`agents/ztd.md` installed by an earlier checkout is left untouched and can be
removed by hand.

## Install globally

With the binary on your `PATH`, publish the embedded assets to
`$HOME/.config/opencode/{skills,commands}`:

```bash
ztd install opencode
```

It preflights the complete bundle before writing, and any differing file,
symlink or unexpected file type aborts the whole run without overwriting
anything. A hidden `.ztd-assets.json` manifest records every path it wrote, so
later runs upgrade those files and refuse one you edited. There is no
per-project mode: copy `skills/` and `commands/` into that project's
`.opencode/` tree by hand. It never initializes the store or modifies OpenCode
configuration.

### 1. Store and templates (prerequisite)

Prerequisite: an initialized store. `ztd init` creates the global store at
`~/.ztd` by default; `ztd init PATH` creates it at exactly that root and
`ztd init --local` at `./ztd`. It also seeds the six method templates into
`<store>/templates/` when they are absent. This block uses an explicit root:

```bash
# from the root of this repository
STORE="$HOME/.ztd"          # explicit store root (edit it if you use another)
ztd init "$STORE"           # creates the store structure and templates in $STORE
```

After upgrading the binary, `ztd install templates` refreshes the six templates
in an existing store root; it never creates the store and refuses a template
you edited.

The commands are OpenCode prompts: `/ztd` is the entry point and the rest are
nested as `/ztd/<name>` (for example `/ztd/plan`, `/ztd/review`), which OpenCode
derives from `commands/ztd/<name>.md`. They run in sessions that discover
`commands/`. `ztd install opencode` installs globally; for project-only
discovery, copy the same `skills/` and `commands/` directories into that
project's `.opencode/` tree. Never copy assets into a
task-data directory: only the store lives there. Paths cited by skills and
commands (`lists/…`, `goals/…`, `templates/…`) are relative to the store root;
pass it with `--root "$STORE"` or `ZTD_ROOT` (precedence `--root` > `ZTD_ROOT`
> `~/.ztd`).

Requirements: the `ztd` binary on the `PATH`, the store root resolved
(`--root` > `ZTD_ROOT` > `~/.ztd`) and the store initialized (step 1).

## Store root and binding

- The store root is the task-data directory. It resolves as `--root` >
  `ZTD_ROOT` > `~/.ztd`, never from the current directory (configuration can
  pin it).
- A repository's `.ztd.json` contains exactly `{context, client, project}`.
  The CLI discovers the nearest file up to the current Git repository
  boundary, reports it in `status`, and validates it with `check --bindings`.
  The binding is a routing hint, not authorization; explicit user scope is
  authoritative. It contains no task, clone-path, or repository-URL data.
  Each clone's local path lives in its project card.
- The paths cited by skills and commands are store paths, not this
  repository's.

## State contract

`ztd status [--json]` applies root precedence and reports `root`, `source`
(`flag` for `--root`, `env` for `ZTD_ROOT`, `home` for `$HOME/.ztd`), `exists`,
`format` and `binding`, in that order. The binding is `null` when absent, or an
object with `path`, `value` and `error`; a malformed binding has an error and
does not suppress root information. `value` contains only `context`, `client`
and `project`. Human output reports the same root and binding state. Status
never creates files and works when the store is absent. Use a valid binding as
a default task scope only when the request supplies none; explicit user scope
remains authoritative. Task state still comes from `list`, `show` and `plan`.

## Adapter rules

- One list writer: task mutations go through the `ztd` CLI (`capture`,
  `move`); list entries are never edited by hand.
- The skills do not authorize external writes (push, publications, sends to
  services) nor destructive ones, and they do not replace the host's native
  roles (`build`, `plan` and the rest keep their configuration and
  permissions).
- These assets carry no local policy and no user or client data: contexts are
  defined in `contexts.md`, at the store root.
