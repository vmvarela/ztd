# ZTD

ZTD is a local task system for one person working with an AI agent. It keeps
commitments, plans and continuity in one SQLite database so an agent can resume
work without replaying a conversation, and it keeps the Zen To Done method
visible instead of turning into a generic issue tracker.

This repository is the Go implementation: a clean rewrite of the earlier Zig
tool. The Markdown store remains supported only as a read-only import source.

## Simple model

One owner, one timezone and explicit scopes. Captures become tasks or references.
Tasks have direct states (`next`, `waiting`, `someday`, `completed`, `cancelled`),
with optional project, context and due date. Daily and weekly plans contain ordered
task IDs. Checkpoints work without a focus session. Knowledge and reviews are
scoped documents in the same database; agents use search, read, save and related.

Start with [the current model and agent workflow](docs/current-model.md).
The [implementation plan](docs/implementation-plan.md) records the migration and
verification work. Older commands remain compatibility adapters.

## Attribution

ZTD is an independent implementation inspired by [Zen To Done](https://zenhabits.net/zen-to-done/)
by Leo Babauta. It is not affiliated with, endorsed by, or an official product
of Zen Habits or Leo Babauta.

## Status

Working today: capture, process, list and move work items, prepare, daily
plans, focus sessions, reviews, routines, source registration with reported
batch ingestion, legacy import, export/restore, snapshots, integrity checks,
knowledge search, lint and archive over the document layer, a local stdio MCP
server and a `status` report of the environment.

Not built yet: provider connectors, external calendars, external focus blocks and
automatic LLM ingestion. The local knowledge wiki uses Markdown pages, FTS5 search,
source references and links. Nothing contacts a network service; those are separate stages, not
implicit features of the CLI.

## Backup

The approved backup path is `ztd snapshot` to an iCloud-synced directory
(approved 2026-11-22). Restic is optional, and remote backup automation is
not built.

## Install

Release binaries ship on the
[releases page](https://github.com/vmvarela/ztd/releases) with a
`sha256sums.txt` manifest:

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/vmvarela/ztd/master/install.sh | sh
```

```powershell
# Windows PowerShell
irm https://raw.githubusercontent.com/vmvarela/ztd/master/install.ps1 | iex
```

Each release also ships the `ztd.1.gz` man page, `.deb`/`.rpm`/`.apk`
packages, the `@vmvarela/ztd` npm package (the first publish is manual;
later releases publish from CI), a Homebrew formula, Scoop, WinGet, AUR,
Nix and the APT/RPM/APK channels — see
[packaging/README.md](packaging/README.md).

Or build from source (requires Go 1.27.4):

```sh
go build -o ztd ./cmd/ztd
./ztd version
```

Then publish the embedded assets — the OpenCode skills to
`~/.config/opencode/skills` and the method templates to
`<store-root>/templates/`:

```sh
./ztd install opencode
./ztd install templates
```

Both preflight the complete bundle before writing and refuse to overwrite a
file you edited; `--dry-run` reports what would happen without writing.

## Quick start

```sh
./ztd --db ~/.ztd/ztd.db init --actor victor \
  --scope id=personal,kind=personal \
  --scope id=opensource,kind=opensource
./ztd --db ~/.ztd/ztd.db capture "call the plumber on Monday"
./ztd --db ~/.ztd/ztd.db inbox next
./ztd --db ~/.ztd/ztd.db process \
  --outcome work_items --title "call the plumber" C-20261119-001
./ztd --db ~/.ztd/ztd.db prepare
```

On a terminal, drop the `--scope` flags: `init` asks for the actor and the
scopes and shows a summary before it writes. Without a terminal and without
flags it fails instead of inventing defaults.

Every command accepts `--json` and returns an envelope:

```json
{"ok": true, "command": "capture", "data": {"id": "C-20261119-001", "processing_state": "pending"}}
```

Errors use stable families such as `invalid_input`, `stale_revision` and
`scope_denied`.

An agent can use the same core over stdio:

```sh
./ztd mcp
```

See [MCP](docs/mcp.md) for registration, tools and approval rules.

## Data

The database is the only authority. Default path: `ZTD_DB` or
`~/.ztd/ztd.db`. Pass `--db` to choose another file. Nothing reads
`~/.ztd` unless you explicitly import a copy.

Scopes separate personal, open-source and client work inside one file. They
are user configuration: `init` and `scope add` declare them, nothing is seeded
behind your back, and a `ScopeBinding` is fixed before a command runs — queries
and mutations cannot widen it from model-controlled arguments. There is one
planning view over every declared scope; its default binding excludes
`client:*` and `work` scopes, and a client scope is selected explicitly with
`--scope`, `ZTD_SCOPES` or a `.ztd.json` hint. `--scope` narrows a command to
one of them and is rejected when it is outside that view.

## Commands

| Command | Purpose |
| --- | --- |
| `init` | Declare the database's scopes (interactive on a terminal, flags in scripts) |
| `install opencode\|templates` | Publish the embedded OpenCode skills and the method templates, without clobbering files you edited |
| `scope add\|list` | Declare and list scopes |
| `capture` | Store text in the inbox |
| `inbox next` | Return the oldest pending capture |
| `process` | Turn a capture into work items, a reference, an immediate result, a defer or a discard |
| `goal set\|show\|complete\|cancel` | Record or read the active primary goal; close it with `complete` or `cancel` |
| `prepare` | Read-only daily brief: active goal, committed MITs, candidates, checkpoints |
| `plan commit` | Commit a daily or weekly plan |
| `focus start\|checkpoint\|finish` | Run one open focus session |
| `task list\|show\|update\|done\|cancel` | Read and patch tasks with direct statuses and revision checks |
| `knowledge search\|read\|save\|related` | Find and maintain sourced knowledge pages |
| `plan show\|set` | Read or replace daily/weekly ordered priorities |
| `review show\|save` | Read and record a review in one scope |
| `settings` | Read owner/timezone or set the timezone |
| `source add\|apply\|list\|review` | Register sources in an explicit scope, sync user configuration over the file's scopes, list coverage with `--all`/`--scope`, feed a reported batch |
| `routines due\|done\|add` | Track recurring routines; `add` registers one |
| `context add\|list` | Declare and read GTD context names inside a scope |
| `doc put\|get\|list\|log\|lint\|archive\|search\|related` | Create, read and list documents (knowledge cards, plans, reviews, …) by kind and slug, with a history log, a link lint, full-text search, link relations and an `answers/` Q&A archive |
| `project add\|list\|show` | Declare and read projects, including repository URL and clone path |
| `find`, `show` | Query work items |
| `list` | Show one list: `--list inbox\|next\|waiting\|someday\|archive`, `--context`, `--project` |
| `move` | Move a work item between `next`, `waiting`, `someday` and `archive`, with `--field` custom fields |
| `status` | Report database, profile, actor, scopes and the `.ztd.json` binding hint |
| `due`, `routine done`, `routine add` | Aliases of `routines due`, `routines done` and `routines add` |
| `migrate import\|verify` | Import a verified copy of the legacy store |
| `migrate documents` | Populate the document layer and project repositories from a verified legacy copy |
| `mcp` | Run the local stdio MCP server for an agent |
| `export`, `restore`, `snapshot` | Move and preserve the database |
| `check` | Verify database invariants, or validate the `.ztd.json` routing hint with `--bindings` |

Run `./ztd <command> -h` for flags.

## Documentation

- [Architecture](docs/architecture.md)
- [Using ZTD](docs/ztd.md)
- [MCP](docs/mcp.md)
- [Sources](docs/sources.md)
- [Migrating the Markdown store](docs/migration.md)
- [Dependency spikes](docs/specs/spikes.md)
- [Legacy format inventory](docs/specs/legacy-inventory.md)

## Checks

```sh
gofmt -l .
go vet ./...
go test ./...
go test -race ./...
go test ./test/integration -count=1
go mod verify
go build -o ./ztd ./cmd/ztd
```

`scripts/check.sh` runs the same list.

## License

MIT. See [LICENSE](LICENSE).
