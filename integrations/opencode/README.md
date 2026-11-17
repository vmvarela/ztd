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

## Manual installation

There is no installer in this version. The blocks below run from the root of
this repository (where `method/` and `integrations/` live); edit the paths to
your case. OpenCode discovers assets per project and globally.

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

### 2. OpenCode assets

Choose a per-project or global install; both blocks create the directories
before copying:

```bash
# a) per project: run from the root of this repository
SRC="$PWD/integrations/opencode"
PROJ="$HOME/src/my-project"   # project root (edit it)
mkdir -p "$PROJ/.opencode/skills" "$PROJ/.opencode/commands" "$PROJ/.opencode/agents"
cp -R "$SRC/skills/"*   "$PROJ/.opencode/skills/"
cp -R "$SRC/commands/"* "$PROJ/.opencode/commands/"
cp "$SRC/agents/ztd.md" "$PROJ/.opencode/agents/ztd.md"

# b) or global (every session): same SRC, run from the repo root
mkdir -p "$HOME/.config/opencode/skills" "$HOME/.config/opencode/commands" "$HOME/.config/opencode/agents"
cp -R "$SRC/skills/"*   "$HOME/.config/opencode/skills/"
cp -R "$SRC/commands/"* "$HOME/.config/opencode/commands/"
cp "$SRC/agents/ztd.md" "$HOME/.config/opencode/agents/ztd.md"
```

The commands are OpenCode prompts: they run as `/name` from any session that
discovers `commands/`; the agent is selected by the `ztd` ID. Never copy assets
into a task-data directory: only the store lives there. The data paths cited by
skills and commands (`lists/…`, `goals/…`, `templates/…`) are relative to the
store root; pass it with `--root "$STORE"` or `ZTD_ROOT` (precedence
`--root` > `ZTD_ROOT` > `~/.ztd`).

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
- A repository's `.ztd.json` is a `{context, client, project}` binding (a
  convention; the CLI does not read it yet): it is
  not the store and holds no tasks or clone paths. Each clone's local path
  lives in its project card and, if the store defines a configurable repos
  root, is validated against it when it exists.
- The paths cited by skills and commands are store paths, not this
  repository's.

## State contract

`ztd status [--json]` is implemented. It applies root precedence and reports
`root`, `source` (`flag` for `--root`, `env` for `ZTD_ROOT`, `home` for
`$HOME/.ztd`), `exists` and `format` (the `config.json` format when readable,
else `null`); human output prints the same values as `root:`, `source:` and
`store:` lines. It never creates files, so it works when the store is absent.
Use it to resolve and verify the root; task state still comes from `list`,
`show` and `plan`, never from inferred local roots.

## Adapter rules

- One list writer: task mutations go through the `ztd` CLI (`capture`,
  `move`); list entries are never edited by hand.
- The `ztd` agent does not replace the host's native roles (`build`, `plan`
  and the rest keep their configuration and permissions) and does not authorize
  external writes (push, publications, sends to services) nor destructive ones.
- These assets carry no local policy and no user or client data: contexts are
  defined in `contexts.md`, at the store root.
