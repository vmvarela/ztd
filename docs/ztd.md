# Using ZTD

ZTD is the method, not a generic to-do list. This walkthrough follows one day.
Every command writes to one database; substitute your path for `DB`.

The implementation is independent and inspired by [Zen To Done](https://zenhabits.net/zen-to-done/)
by Leo Babauta. It is not affiliated with, endorsed by, or an official product
of Zen Habits or Leo Babauta.

Set it once:

```sh
DB=$HOME/.ztd/ztd.db
```

## Setup: scopes and contexts

A **scope** is the data and authorization boundary: every capture, work item,
source and project belongs to exactly one scope. Scopes are your
configuration, not product constants, so declare the ones you actually use —
`personal`, `opensource`, `client:prisamedia`.

A **context** is the GTD tag that says where or how you do something —
`familia`, `propiedades`, `salud`, `@calls`. Contexts do not separate data.

There is one planning view over every declared scope. `init` declares the
scopes and creates that view; you do not choose a profile. On a terminal it
asks for the actor and the scopes; in a script it takes flags:

```sh
# Interactive: actor id, one scope per line, then a confirmation.
./ztd --db "$DB" init

# Non-interactive: at least one --scope, or it fails.
./ztd --db "$DB" init --actor victor \
  --scope id=personal,kind=personal \
  --scope id=opensource,kind=opensource \
  --scope id=salud,kind=personal,name=Salud \
  --scope id=client:prisamedia,kind=client
```

Ids may contain `:` but never `,`, `|` or `=`; fields are comma-separated.
`init` never drops anything an existing database already holds: an identical
declaration changes nothing, a new scope extends the planning view, one
conflicting entry rolls the whole batch back, and with no terminal and no
flags it fails with `invalid_input` instead of inventing defaults.

Add a scope later with `scope add` and re-run `init` with the full declaration
to extend the planning view:

```sh
./ztd --db "$DB" scope add --id trabajo --kind work --name Work
./ztd --db "$DB" scope list
./ztd --db "$DB" init --actor victor \
  --scope id=personal,kind=personal \
  --scope id=opensource,kind=opensource \
  --scope id=trabajo,kind=work
```

Nothing deletes or renames scopes yet, so a typo stays visible instead of
silently rewriting what exists.

Every command reads one shared store: the binding decides which scopes a
command can see. It narrows the view — it never splits or duplicates tasks,
and there is one set of tasks for the whole store. An explicit `--scope`
narrows a command to one declared scope; a scope outside the planning view is
`scope_denied`. The first scope of the binding is the primary one, and that
is where a capture lands when no `--scope` is given.

The binding of a command is resolved in this order:

1. **`--scope S`** — exactly those scopes. Each must belong to the planning
   profile, otherwise `scope_denied`.
2. **`ZTD_SCOPES`** — a comma-separated list of scope ids set by the host
   (operator configuration), for example `ZTD_SCOPES=client:prisamedia`.
   Spaces around an id are ignored; an empty token is `invalid_input`, and a
   scope outside the profile is `scope_denied`.
3. **`.ztd.json` in the current directory** — narrows to a single scope:
   `context` when it names a declared scope, else `client:<client>` when that
   names one, else `personal` when the hint names no scope at all. A missing,
   malformed or unknown hint is ignored and the default applies; it never
   fails a command. `check --bindings` stays the strict validator.
4. **The default** — the planning profile's scopes without `client:*` and
   `work` scopes, so a personal view never returns client work. A profile
   that only covers client or work scopes keeps all of them, so the binding
   is never empty.

`--scope` beats `ZTD_SCOPES`, `ZTD_SCOPES` beats `.ztd.json`, and `.ztd.json`
beats the default. No model argument can widen any of them.

## 1. Capture

Capture first, decide later. Capture is cheap and never asks for a category.

```sh
./ztd --db "$DB" capture "renew the passport before the trip"
./ztd --db "$DB" capture "the printer keeps losing its queue"
```

The result is a pending `Capture` with an immutable original text, a stable ID,
a source and a content hash. Repeating the same external item with the same
identity does not duplicate it.

## 2. Process to zero

`inbox next` returns the oldest pending capture, or one deferred capture whose
review date has arrived.

```sh
./ztd --db "$DB" inbox next
```

Then make exactly one decision:

```sh
# One or more real next actions
./ztd --db "$DB" process --outcome work_items \
  --title "find the passport renewal office" C-20261119-001

# Not actionable, but worth keeping
./ztd --db "$DB" process --outcome reference \
  --reason "printer queue notes" C-20261119-002

# Under two minutes: do it now
./ztd --db "$DB" process --outcome immediate \
  --evidence "restarted the print spooler" C-20261119-003

# Bring it back on a date
./ztd --db "$DB" process --outcome defer \
  --review-after 2026-12-01 --reason "waiting for the trip date" C-20261119-004

# It does not deserve to exist
./ztd --db "$DB" process --outcome discard C-20261119-005
```

A process call is atomic: several work items are created together or not at
all. `waiting` requires `--waiting-on`; `immediate` without evidence is only a
declaration, not proof.

## 3. Prepare the day

Record the one active primary goal for the Profile first:

```sh
./ztd --db "$DB" goal set --statement "Ship ZTD 0.1"
./ztd --db "$DB" goal show
```

A Profile may have one active primary goal and any number of subgoals.
`goal set` is idempotent per key and refuses a second active primary.

```sh
./ztd --db "$DB" prepare
```

`prepare` is read-only. It returns the Profile's active primary goal, the
committed daily plan for the date with its MITs and latest checkpoints, plus
candidate next and waiting items. When sources are registered it also surfaces
their coverage: an unverified or partially read source is shown as such, never
as an empty, fully reviewed one. It never selects MITs: the agent proposes them, the human decides, and
`plan commit` records that decision. It does not reserve work or start a timer.

`plan` without a subcommand is the same read-only brief, kept for legacy
callers. `--context NAME` filters the three item lists by context name;
`--client` is accepted and ignored because scopes replaced the legacy client
axis.

Commit the plan:

```sh
./ztd --db "$DB" plan commit --period 2026-11-19 \
  --item T-20261119-001:mit \
  --item T-20261119-004:big_rock
```

A fourth MIT is rejected unless a `DailyLimitOverride` exists. An item outside
the declared scopes is rejected.

## 4. Do one thing

```sh
./ztd --db "$DB" focus start --key focus-morning T-20261119-001
./ztd --db "$DB" focus checkpoint --key cp-1 \
  --result "document renewed" --next "collect the receipt" T-20261119-001
./ztd --db "$DB" focus finish --outcome done F-20261119-001
```

There is one open focus per actor across all scopes. A checkpoint records
progress without changing the work item's revision. Starting a second focus
fails with `focus_conflict`; it never closes the first one silently.

## 5. Review

```sh
./ztd --db "$DB" review daily --period 2026-11-19 \
  --outcomes "passport office found; printer fixed" \
  --coverage "inbox empty; calendar not checked"
```

A partial review is a valid review. Record what was not checked instead of
pretending the day was complete.

Weekly:

```sh
./ztd --db "$DB" review weekly --period 2026-W47 \
  --outcomes "goal advanced; two commitments dropped" \
  --coverage "calendar checked through Friday"
```

## 6. Routines

Routines are recurring maintenance, not deadlines.

```sh
./ztd --db "$DB" routines due
./ztd --db "$DB" routines done --date 2026-11-19 inbox
```

`due` returns active routines whose cadence has elapsed. The operating system
scheduler, not ZTD, is responsible for waking anyone up.

## 7. Find and inspect

```sh
./ztd --db "$DB" find passport
./ztd --db "$DB" show T-20261119-001
```

`find` is scoped and bounded. `show` returns one entity with its revision and
history references.

## 8. Lists, moves and status

`list` reads one list, `move` moves one work item between lists, and `status`
reports the local environment.

```sh
./ztd --db "$DB" list --list next
./ztd --db "$DB" list --list waiting --context familia
./ztd --db "$DB" list --list inbox

./ztd --db "$DB" move T-20261119-001 waiting --waiting-on "the builder"
./ztd --db "$DB" move T-20261119-001 next
./ztd --db "$DB" move T-20261119-001 archive --resolution "renewed at the counter"

./ztd --db "$DB" status
```

- `--list` takes `inbox` (the pending and due deferred captures), `next`
  (default), `waiting`, `someday` or `archive`. `--context` matches a context
  name and `--project` a project id, both restricted to the bound scopes.
- `move ID LIST` takes `next`, `waiting`, `someday` or `archive`; `inbox` is not
  a move target. `waiting` requires `--waiting-on`, `archive` requires
  `--resolution`, and `--closure completed|cancelled|unspecified` defaults to
  `completed`. Like every mutation it is revision-checked with `--expected N`
  and idempotent by `--key K`.
- **Custom fields**: extra data travels as repeatable `--field key:value`.
  `waiting_on` and `resolution` are accepted there for legacy callers and map to
  their columns; `context`, `client`, `project`, `captured_at` and `closed_at`
  are structural and rejected. Every other legacy field survives the import
  inside `custom_fields` instead of being dropped, and `check` verifies the
  stored value is a JSON object.
- `status` reports the database path, the profile (`personal`), the actor, the
  declared scopes, `effective_scopes` (the binding a command gets with no
  explicit `--scope`, after `ZTD_SCOPES` and the `.ztd.json` hint) and the
  contents of a `.ztd.json` in the current directory.
  That file is a routing hint, never authorization: absent or malformed it comes
  back as `null` with a `warning`, never as a failure, and `status` never
  creates the database.

`due` and `routine done ID` are aliases of `routines due` and
`routines done ID`. `recover` is a compatibility no-op: SQLite has no Markdown
journal to replay, so it reports `recovered: false` and writes nothing.

## 9. Preserve the store

```sh
./ztd --db "$DB" check
./ztd --db "$DB" export --out e.json
./ztd --db "$DB" snapshot --out /tmp/ztd-snapshot.db
```

Restore only into an empty database:

```sh
./ztd --db /tmp/restored.db restore --from e.json
./ztd --db /tmp/restored.db check
```

Remote encrypted backup is deliberately not part of this binary yet. Choose
and approve a destination before sending personal or client data anywhere.

## 10. Sources

A source is a registered origin of captures. Registration is operator
configuration, not part of the daily loop:

```sh
./ztd --db "$DB" source add --id notes-dir --name "Notes directory" \
  --scope personal --kind capture --connector directory --cadence daily
./ztd --db "$DB" source apply   # defaults to ~/.ztd/sources.json
./ztd --db "$DB" source list --all
```

`source apply` synchronizes a user-owned JSON configuration (generic fields
only; no provider is compiled into ZTD). It is an operator command: it binds
to the union of the scopes the file declares, and a scope that does not exist
fails before anything is written. `source add` takes an explicit `--scope`,
and `source list` selects with exactly one of `--all` (the default) or a
repeatable `--scope`. It shows each source's coverage (`unknown`, `unverified`,
`partial`, `complete`, `failed`) and cursor for the selected scopes. It shows
registry state only — no provider is contacted and no connector runs.

Feed a reported batch from a JSON file:

```sh
./ztd --db "$DB" source review --source notes-dir \
  --batch batch-1 --key review-2026-11-20 --file batch.json
```

Each item becomes a pending capture in the source's scope and reappears in
`inbox next` like a manual capture. The batch is idempotent by key: a retry
replays the stored review instead of duplicating captures. `observed` result
kind is refused — only a trusted host adapter may attest an observed
provider exchange, and no such adapter exists yet. See
[Sources](sources.md) for the file shape, the coverage rules and the cursor
contract.

## 11. Contexts, documents and projects

These commands store the records the Markdown skills used to keep as files.
The skills themselves are not ported yet; this is the storage layer they will
read.

```sh
./ztd --db "$DB" context add familia --scope personal
./ztd --db "$DB" context list

./ztd --db "$DB" doc put --kind knowledge --slug komorebi/setup \
  --title "Komorebi setup" --body "Clone lives under repos/ ..."
./ztd --db "$DB" doc get --kind knowledge --slug komorebi/setup
./ztd --db "$DB" doc list --kind knowledge
./ztd --db "$DB" doc log --kind knowledge --limit 20
./ztd --db "$DB" doc lint
./ztd --db "$DB" doc archive --slug komorebi-tips \
  --question "Where does the clone live?" --body "Under repos/."
./ztd --db "$DB" doc search --query "komorebi setup" --kind knowledge
./ztd --db "$DB" doc related --kind knowledge --slug komorebi/setup

./ztd --db "$DB" project add opensource/ztd --scope opensource \
  --desired-outcome "Ship the Go rewrite" \
  --repo-url https://example.com/ztd.git \
  --clone-path "$HOME/workspaces/ztd"
./ztd --db "$DB" project list
./ztd --db "$DB" project show opensource/ztd
```

- A **context** is a GTD tag inside one scope. `context add NAME` uses the
  scope's primary scope unless `--scope` narrows it; adding the same name
  again returns the existing row without writing anything. `context list`
  is binding-filtered and ordered by name.
- A **document** is identified by `(scope, kind, slug)`. `doc put` creates it
  at revision 1 or updates it with `--expected N`; a wrong expectation is
  `stale_revision` and writes nothing, and repeating the identical command
  replays the stored result. Kinds are `knowledge`, `knowledge_index`,
  `project_note`, `plan_daily`, `plan_weekly`, `review`, `journal`,
  `calendar`, `adoption`, `passion` and `routine`. Status is `draft` (the
  default), `verified` or `superseded`. `--file PATH` supplies the body
  instead of `--body TEXT`. `doc list` filters with `--kind`.
- `doc log [--scope X] [--kind K] [--slug S] [--limit N]` reads the append-only
  history of the bound documents joined through the document's own scope, not
  the event's (which may be null): newest first in JSON, oldest first as
  Markdown `## [YYYY-MM-DD] event | kind/slug` lines. The limit defaults to 50
  and caps at 500; it writes nothing.
- `doc lint [--scope X] [--strict]` checks every `knowledge` and
  `knowledge_index` document without touching the network: empty titles and
  bodies and unresolved `[[wikilink]]`s are errors, unresolved Markdown links,
  knowledge cards no index references and scopes without an index are
  warnings. Targets match slugs (and unique titles for wikilinks) inside the
  bound scopes only, so a cross-scope target is simply unresolved and its
  message never names the other scope. Errors fail the command;
  `--strict` fails on warnings too.
- `doc archive --slug S [--title T] [--question Q] [--body TEXT | --file PATH]
  [--scope X] [--expected N]` stores one Q&A answer as a `knowledge` draft
  under `answers/<S>` (an existing `answers/` prefix is not doubled), with the
  title defaulting to the slug. With `--question`, the body gains a short
  header — `# <title>`, the question and today's date — above the answer. It
  reuses `doc put`'s idempotency and `--expected` revision guard.
- `doc search --query Q [--kind K] [--scope X] [--limit N]` is a read-only
  full-text search over the bound scopes' documents (FTS5). `--query` is
  required; every word must appear, FTS operators in the query are treated as
  literal text, and hits come back best match first with the document, its
  rank and a highlighted body snippet. The limit defaults to 10 and caps at
  50. It never writes and never sees a document outside the binding.
- `doc related --kind K --slug S [--scope X]` is the read-only link
  neighbourhood of one document: `outlinks` are the documents it links to
  (`[[target]]`, `[[target|label]]`, `[[target#anchor]]` and
  `[label](target)`, with code samples and external URLs ignored) and
  `backlinks` are the same-scope documents that link back to its slug or its
  unique title. Resolution stops at the source's own scope, so a cross-scope
  target stays unresolved and is never named; both lists are deduplicated and
  ordered by kind and slug, and the source is never its own backlink.
- Over MCP the same three reads are `doc_search`, `doc_get` and
  `doc_related`. The binding is fixed when the server starts, so none of them
  accepts a scope.
- A **project** keeps its caller-chosen id, including legacy path-style ids
  like `opensource/ztd`. Re-adding the same id with the same configuration is
  a no-op; a different configuration is `conflict`. `--repo-url` must be an
  absolute URL without credentials, and `--clone-path`, when set, must be an
  absolute path with no `..` segment.
- `migrate documents --source COPY [--mapping FILE] [--workspace DIR]
  [--dry-run]` fills this layer from a verified copy of the legacy Markdown
  store before the skills are ported: each file becomes one `verified`
  document named by its first `# ` heading, ambiguous or invalid files are
  reported and skipped, a re-run over the same copy is a no-op, and the
  `## Repositories` table of each project note fills only the empty
  repository fields of the matching project. See
  [Migrating the Markdown store](migration.md).
- `check --bindings` reads `.ztd.json` from the current directory — exactly
  `{context, client, project}` with non-empty strings (`client` may be empty
  or omitted) — resolves the scope (`context` if it exists, else
  `client:<client>`, else `personal`) and verifies the project exists there.
  It reports `{ok, binding, scope, project}` and writes nothing: a missing or
  malformed file is `invalid_input`.

## Rules the CLI enforces

- One to three MITs and one open focus per actor per day, across scopes.
- One primary goal for the planning view.
- `waiting` needs `waiting_on`; `archived` needs a closure and resolution.
- Every mutation is revision-checked and idempotent by key.
- A scope binding is fixed before the command; it cannot be widened by a flag
  supplied by a model.
- A failed call writes nothing.
- A source batch is `reported` only; `observed` coverage needs a trusted host
  adapter and is refused on every model-facing path.

## Deliberate omissions

- Meetings and calendar events are not imported into the inbox.
- ZTD does not create or edit calendar events yet.
- Sources are registered and batches are fed by hand: no connector contacts a
  provider, and nothing runs in the background.
- There are no background reminders, no daemon and no web UI.
- The legacy Markdown store is read-only and only through `migrate import`
  and `migrate documents`.
