# OpenCode adapter for ZTD

This folder is only an adapter: the neutral method lives in
[`../../method/README.md`](../../method/README.md). Here are the generic
OpenCode assets —skills, commands and a single orchestrating agent— that apply
the method on the task store (store root `~/.ztd`).

## What is included

| Path | Contents |
| --- | --- |
| `skills/` | The 10 ZTD skills: `ztd` and its nine helpers (`ztd-collect`, `ztd-process`, `ztd-plan`, `ztd-do`, `ztd-review`, `ztd-trusted-system`, `ztd-simplify`, `ztd-knowledge`, `ztd-repo`) |
| `commands/` | The commands `/ztd`, `/collect`, `/inbox`, `/plan`, `/focus`, `/week`, `/goal`, `/journal`, `/routine`, `/simplify`, `/learn`, `/repo`, `/ztd-review` |
| `agents/ztd.md` | The `ztd` agent: a thin role that orchestrates capture, process, plan, do and review |

## Install globally

The bundled installer publishes the global assets to
`$HOME/.config/opencode/{skills,commands,agents}`. It resolves its assets
relative to itself, so it can be run from any working directory:

```bash
./integrations/opencode/install.sh
```

The installer preflights the complete bundle before writing. Identical files
are left unchanged; differing files, symlinks and unexpected file types abort
without overwriting. If an I/O error occurs after publication starts, rerun it:
already installed files are safe no-ops. It does not initialize the store,
modify OpenCode configuration or configure MCP.

### 1. Store and templates (prerequisite)

Prerequisite: an initialized store. `ztd init` creates the global store at
`~/.ztd` by default; `ztd init PATH` creates it at exactly that root and
`ztd init --local` at `./ztd`. This block uses an explicit root:

```bash
# from the root of this repository
STORE="$HOME/.ztd"          # explicit store root (edit it if you use another)
ztd init "$STORE"           # creates the store structure in $STORE
cp method/templates/*.md "$STORE/templates/"
```

The commands are OpenCode prompts: they run as `/name` in sessions that discover
`commands/`; the agent has ID `ztd`. The script installs globally; for
project-only discovery, copy the same `skills/`, `commands/` and `agents/`
directories into that project's `.opencode/` tree. Never copy assets into a
task-data directory: only the store lives there. Paths cited by skills and
commands (`lists/…`, `goals/…`, `templates/…`) are relative to the store root;
pass it with `--root "$STORE"` or `ZTD_ROOT` (precedence `--root` > `ZTD_ROOT`
> `~/.ztd`).

### MCP

Register the server in `opencode.jsonc` (optional; the skills' queries use it)
with the store root made explicit:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "ztd": {
        "type": "local",
        "command": ["ztd", "--root", "{env:HOME}/.ztd", "mcp"]
      }
    }
  }
}
```

V2 connects servers automatically and does not use `enabled` (to keep one
configured without connecting there is `disabled: true`). Replace the path with
your store root: `command` does not go through a shell, so use an absolute path
or OpenCode's `{env:NAME}` substitution.

Requirements: the `ztd` binary on the `PATH`, the store root resolved
(`--root` > `ZTD_ROOT` > `~/.ztd`) and the store initialized (step 1).

## Store root and binding

- The store root is the task-data directory. It resolves as `--root` >
  `ZTD_ROOT` > `~/.ztd`, never from the current directory (configuration can
  pin it, e.g. the MCP above).
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
- The `ztd` agent does not replace the host's native roles (`build`, `plan`
  and the rest keep their configuration and permissions) and does not authorize
  external writes (push, publications, sends to services) nor destructive ones.
- These assets carry no local policy and no user or client data: contexts are
  defined in `contexts.md`, at the store root.
