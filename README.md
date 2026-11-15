# ztd

A small task manager for humans and agents. Tasks are plain Markdown in a Git
repository; `ztd` reads and edits them with atomic writes, file locking and a
recoverable journal.

One static binary, no runtime.

## Install

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/vmvarela/ztd/master/install.sh | sh

# Windows PowerShell
irm https://raw.githubusercontent.com/vmvarela/ztd/master/install.ps1 | iex
```

Or build from source with Zig 0.17:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ztd version
```

Packages are published through Homebrew, WinGet, Scoop, npm, APT, RPM, APK,
AUR and Nix. See [docs/install.md](docs/install.md).

## Quick start

```bash
mkdir my-tasks && cd my-tasks
ztd init

ztd capture "Revisar el plan de la semana" "Preparar demo"
ztd list
ztd move T-20261111-001 next --field contexto:personal
ztd show T-20261111-001
ztd check
```

`ztd init` creates `ztd/` in the current directory:

```text
ztd/
  contexts.md
  config.json
  inbox.md
  lists/{next,waiting,someday,archive}.md
  lists/projects/index.md
  plans/daily/
  plans/weekly/
  templates/
  .state/            # lock, journal; ignored by Git
  .gitignore
  .gitattributes
  README.md
```

The binary only edits files. Commit them with your own Git workflow.

## Task format

```text
- [ ] T-20261111-001 | Título | contexto: trabajo | cliente: acme | proyecto: trabajo/acme/demo | capturada: 2026-11-11
```

- ID: `T-YYYYMMDD-NNN`, at least three digits.
- `contexto` is required outside `inbox` and must exist in `contexts.md`.
- `cliente` and `proyecto` are optional, subject to `config.json` policy.
- Projects are registered by path: `ztd/lists/projects/<contexto>[/<cliente>]/<proyecto>.md`.
- `archive` entries use `[x]`, require `resolución`, and get `cerrada`.
- `waiting` entries require `espera`.

`config.json` controls client rules:

```json
{"format":1,"policy":{"requireClientFor":["trabajo"],"clientOnlyIn":["trabajo"]}}
```

## Commands

```text
ztd init [path]
ztd capture <text>... | --stdin
ztd list [--context C] [--client X] [--project P] [--list L]
ztd show <id>
ztd move <id> <list> [--text T] [--field k:v] [--unset k] [--expect-line N]
ztd plan --context C [--client X] [--date YYYY-MM-DD]
ztd check [--strict]
ztd recover
ztd due
ztd routine done <id>
ztd agent-capture --scope S --request TEXT [--project P] [--objective T] [--constraints T] [--idempotency-key K] [--db PATH]
ztd agent-checkpoint ID --scope S --expect-rev N --result TEXT [--kind progress|done] [--evidence T] [--next T] [--idempotency-key K] [--db PATH]
ztd agent-prepare ID --scope S [--history N] [--db PATH]
ztd agent-backup --out FILE [--db PATH]
ztd agent-export --out FILE [--db PATH]
ztd agent-restore --from FILE [--db PATH]
ztd mcp [--read-only] [--scope C] [--agent-scope S] [--agent-db PATH]
ztd version
```

Global flags: `--root PATH`, `--json`, `--today YYYY-MM-DD`, `--dry-run`.
`ZTD_ROOT` is used when `--root` is absent.

`list` without `--list` returns `inbox`, `next`, `waiting` and `someday`.
`--client` and `--project` require `--context`.

`move --expect-line N` is optimistic concurrency: if the task is not on line
`N` of its source file, `ztd` returns `stale_task` and writes nothing.

### Agent store

The `agent-*` commands record assignments and checkpoints in a local
SQLite store (`--db` > `ZTD_AGENT_DB` > per-OS default). They need no Markdown
workspace, reject `--root`, `--today` and `--dry-run`, accept `--json`, and
print the JSON envelope by default. The store is independent of the Markdown
lists; it does not replace them. Details and error codes: [docs/spec.md](docs/spec.md).

Durability: `agent-export --out FILE` writes every scope, assignment,
checkpoint and idempotency row as a versioned JSON export
(`format` `ztd-agent-export`, `version` 1); `agent-restore --from FILE`
imports it into an empty store, refusing a non-empty target or a malformed
file with `invalid_argument` and verifying counts and revisions before the
commit, so a failed restore writes nothing; `agent-backup --out FILE` makes a
consistent single-file copy (`VACUUM INTO`) that never overwrites an existing
file and opens through the schema gate. `agent-prepare ID --scope S
--history N` returns up to `N` checkpoints newest-first alongside the latest
one. These are operator actions and have no MCP tools.

## JSON

All commands support `--json`:

```json
{"ok":true,"command":"list","data":{"tasks":[]}}
{"ok":false,"command":"move","error":{"code":"stale_task","message":"StaleTask"}}
```

Exit codes: `0` success, `1` domain error, `2` usage.

## MCP

`ztd mcp` is a stdio MCP server (JSON-RPC 2.0, one object per line):

- Tools: `ztd_capture`, `ztd_list`, `ztd_show`, `ztd_move`, `ztd_plan`, `ztd_check`.
- Resources: `ztd://contexts`, `ztd://config`, `ztd://plan/YYYY-MM-DD`.
- `--read-only` rejects `ztd_capture` and `ztd_move`.
- `--scope C` limits context-scoped operations to `C`.

`ztd mcp --agent-scope S [--agent-db PATH]` runs the agent-mode server instead:
only `ztd_agent_capture`, `ztd_agent_checkpoint` and `ztd_agent_prepare`, and no
resources, because the legacy handlers resolve a Markdown workspace that the
agent scope does not constrain. The scope comes from server configuration and
is never a tool argument; `--read-only` rejects capture and checkpoint and
allows prepare.

OpenCode:

```jsonc
"mcp": {
  "servers": {
    "ztd": {
      "type": "local",
      "command": ["ztd", "mcp"],
      "enabled": true
    }
  }
}
```

The server starts even without a workspace; tools return `invalid_workspace`.

With `--agent-scope`, the server exposes only the three `ztd_agent_*` tools and
no resources; the Markdown tools are not listed in that mode.

## Guarantees

These apply to the Markdown task lists, not to the agent store.

- Mutations take an exclusive lock; reads take a shared lock.
- Every write is atomic: readers see the old or the new file, never a partial one.
- A mutation writes `.state/pending.json` before touching task files. If the
  process dies, `ztd recover` finishes the transaction or reports
  `recover_conflict` if the file changed outside `ztd`.
- `check` reports duplicate IDs, malformed entries, invalid states and
  references to unknown IDs.

## Development

```bash
zig build test
zig fmt --check build.zig src
```

The test suite uses synthetic workspaces only. It never reads user data.

See [docs/spec.md](docs/spec.md) for the data model, transition rules and the
methodical specifications behind the engine.

## License

MIT
