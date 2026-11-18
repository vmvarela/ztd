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

Publish the OpenCode integration (skills and commands) with:

```bash
ztd install opencode
```

Upgrade the six method templates in the store root with:

```bash
ztd install templates
```

## Quick start

```bash
ztd init                 # global store at ~/.ztd (--local for ./ztd)

ztd capture "Review the week's plan" "Prepare demo"
ztd list
ztd move T-20261111-001 next --field context:personal
ztd show T-20261111-001
ztd check
```

`ztd init` creates the store layout. The global store at `~/.ztd` is the
default; `ztd init PATH` uses *PATH* as the exact root and `ztd init --local`
creates `./ztd`:

```text
<store>/
  contexts.md
  config.json
  inbox.md
  lists/{next,waiting,someday,archive}.md
  lists/projects/index.md
  plans/daily/
  plans/weekly/
  routines/state.md   # recurring routines; created by init
  templates/
  .state/            # lock, journal; ignored by Git
  .gitignore
  .gitattributes
  README.md
```

The binary only edits files. Commit them with your own Git workflow.

## Task format

```text
- [ ] T-20261111-001 | Title | context: work | client: acme | project: work/acme/demo | captured_at: 2026-11-11
```

- ID: `T-YYYYMMDD-NNN`, at least three digits.
- `context` is required outside `inbox` and must exist in `contexts.md`.
- `client` and `project` are optional, subject to `config.json` policy.
- Projects are registered by path: `lists/projects/<context>[/<client>]/<project>.md`.
- `archive` entries use `[x]`, require `resolution`, and get `closed_at`.
- `waiting` entries require `waiting_on`.
- `captured_at` and `closed_at` hold dates.

`config.json` controls client rules:

```json
{"format":2,"policy":{"requireClientFor":["work"],"clientOnlyIn":["work"]}}
```

## Commands

```text
ztd init [path] [--local]
ztd status [--json]
ztd capture <text>... | --stdin
ztd list [--context C] [--client X] [--project P] [--list L]
ztd show <id>
ztd move <id> <list> [--text T] [--field k:v] [--unset k] [--expect-line N]
ztd plan --context C [--client X] [--date YYYY-MM-DD]
ztd check [--strict] [--bindings]
ztd migrate --from SOURCE --to DEST [--dry-run]
ztd recover
ztd due
ztd routine done <id>
ztd tui
ztd agent-capture --scope S --request TEXT [--project P] [--objective T] [--constraints T] [--idempotency-key K] [--db PATH]
ztd agent-checkpoint ID --scope S --expect-rev N --result TEXT [--kind progress|done] [--evidence T] [--next T] [--idempotency-key K] [--db PATH]
ztd agent-prepare ID --scope S [--history N] [--db PATH]
ztd agent-remember --scope S --kind K --text T [--source SRC] [--idempotency-key K] [--db PATH]
ztd agent-recall --scope S --query Q [--limit N] [--db PATH]
ztd agent-backup --out FILE [--db PATH]
ztd agent-export --out FILE [--db PATH]
ztd agent-restore --from FILE [--db PATH]
ztd version
```

Global flags: `--root PATH`, `--json`, `--today YYYY-MM-DD`, `--dry-run`.
Root precedence: `--root` > `ZTD_ROOT` > `~/.ztd`; the root is never
discovered from the current directory.

`ztd status [--json]` reports the resolved store root, its source (`flag`,
`env` or `home`), whether the store exists, its `config.json` format, and the
current repository binding. The JSON envelope carries `root`, `source`,
`exists`, `format` (`null` when unreadable), then `binding`. `binding` is `null`
when none is found; otherwise it contains `path`, `value` and `error`. A valid
`value` has exactly `context`, `client` and `project`; malformed bindings appear
with a null value and an error. Status still reports the root and exits 0 if a
binding is missing or malformed. It never creates files, so it works when the
store is absent.

`list` without `--list` returns `inbox`, `next`, `waiting` and `someday`.
`--client` and `--project` require `--context`.

`ztd tui` opens a read-only terminal browser for the whole store: every list
group, project, plan, review, knowledge card, journal entry and routine, with
the selected document on the right. It starts on Hoy — the active goal from
`goals/active.md` plus today's MITs from the daily plan — and a missing goal
or plan simply omits those rows. Keys: arrows or `j`/`k`, `enter` to expand a
group, `tab` to switch panes, `/` to filter, `t` to cycle theme, `z` for zen
reading mode, `?` for help, `q` to quit. Three themes — `paper`, `tea`,
`amber` — default from `config.json` with `"tui": { "theme": "tea" }`; absent
or invalid falls back to `paper`. Selection, navigation and the once-a-second
live refresh are unchanged, the mouse still scrolls and drags the divider,
and it never writes or holds the store lock.

### Repository binding

Each repository can contain a `.ztd.json` with exactly three keys: `context`
and `project` are nonblank strings; `client` is a nonblank string or `null`.
The CLI discovers the nearest binding from the current directory up to the
current Git repository boundary. A nested repository does not inherit its
parent's binding. The binding is a routing hint, not authorization, and never
changes store-root resolution.

`ztd check --bindings` validates the current repository's binding against the
store's contexts, client policy and registered project. It fails when the
binding is missing or invalid. It does not inspect remotes or clone paths.

### Format-1 conversion

`ztd migrate --from SOURCE --to DEST` makes a copy-only conversion into a new
format-2 store. Both paths are explicit exact directories; `DEST` must not
exist. The source is never modified, and `.git` administration and `.state/`
are not copied. `--dry-run` performs validation and previews any inferred
format/config or new routine baseline without writing. The converter preserves
task titles, values, custom fields, unknown configuration properties and
unrelated files; it rejects ambiguous formats, malformed data, field
collisions and unsafe paths rather than guessing. If a historical source has
no `config.json`, conversion requires format-1 structural evidence and uses
empty client-policy arrays. If routine state is genuinely absent, the
converter starts the current default routines at the conversion date as a new
scheduling baseline; it does not claim past work.

`move --expect-line N` is optimistic concurrency: if the task is not on line
`N` of its source file, `ztd` returns `stale_task` and writes nothing.

### Agent store

The `agent-*` commands record assignments and checkpoints in a local
SQLite store (`--db` > `ZTD_AGENT_DB` > per-OS default). They need no Markdown
store, reject `--root`, `--today` and `--dry-run`, accept `--json`, and
print the JSON envelope by default. The store is independent of the Markdown
lists; it does not replace them. Details and error codes: [docs/spec.md](docs/spec.md).

Durability: `agent-export --out FILE` writes every scope, assignment,
checkpoint, idempotency and knowledge row as a versioned JSON export
(`format` `ztd-agent-export`, `version` 2; version-1 documents still
restore); `agent-restore --from FILE`
imports it into an empty store, refusing a non-empty target or a malformed
file with `invalid_argument` and verifying counts and revisions before the
commit, so a failed restore writes nothing; `agent-backup --out FILE` makes a
consistent single-file copy (`VACUUM INTO`) that never overwrites an existing
file and opens through the schema gate. `agent-prepare ID --scope S
--history N` returns up to `N` checkpoints newest-first alongside the latest
one. These are operator actions and are CLI only.

`agent-remember --scope S --kind K --text T` stores one knowledge record
(`fact`, `decision`, `constraint` or `procedure`) and `agent-recall --scope S
--query Q` finds the records of that one scope by full text, best match
first.

## JSON

All commands support `--json`:

```json
{"ok":true,"command":"list","data":{"tasks":[]}}
{"ok":false,"command":"move","error":{"code":"stale_task","message":"StaleTask"}}
```

Exit codes: `0` success, `1` domain error, `2` usage.

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

The test suite uses synthetic stores only. It never reads user data.

See [docs/spec.md](docs/spec.md) for the data model, transition rules and the
methodical specifications behind the engine.

## License

MIT
