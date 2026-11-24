# Migrating the Markdown store

> The [current model](current-model.md) supersedes the profile graph, separate
> knowledge/review stores and manual-index workflows described in this historical
> reference. Existing APIs remain compatibility adapters.

The legacy store is Markdown plus an agent SQLite database. ZTD imports a
**copy** of it into a new SQLite database. It never writes to the source and
never runs a dual-write period.

## Before you start

1. Quiesce the legacy store: no agent or editor is writing to it.
2. Run the legacy tool's own check on the store. A clean result is required.
3. If a legacy journal is pending, run the legacy `recover` according to its
   rules. The importer refuses a pending journal instead of repairing it.
4. Copy the whole store to a new directory. Treat that copy as the source of
   truth for this import and do not edit it.
5. Export the legacy agent-continuity store as JSON v2 if you want assignments,
   checkpoints, operations and knowledge.

The new database lives at `~/.ztd/ztd.db` by default. The legacy Markdown
files in that root are never read by the new binary; the import source is the
verified copy you made above.

## Mapping

Scopes and contexts are not inferred from free text. Provide a mapping file:

```json
{
  "default_scope": "personal",
  "actor": "victor",
  "contexts": {
    "familia": {"scope": "personal"},
    "opensource": {"scope": "opensource"},
    "work": {"scope": "work", "area": "work"},
    "work:acme": {"scope": "client:acme"}
  },
  "agent_scopes": {"work": "work"}
}
```

Defaults exist, but confirm them before importing real data. Each legacy
context maps to exactly one scope; the mapping never merges personal and
client contexts into the same scope.

## Import

```sh
./ztd migrate import \
  --source /path/to/legacy-copy \
  --agent-export /path/to/agent-export.json \
  --target ~/.ztd/ztd.db \
  --report /path/to/report.json \
  --mapping /path/to/mapping.json \
  --legacy-check ok \
  --legacy-version 2
```

The importer:

- hashes the copy and the agent export before writing;
- refuses a target with unrelated data;
- imports inbox lines as pending captures, active and archived tasks as work
  items with their original IDs, projects, plans, routines and knowledge;
- preserves custom fields, original text, resolutions and source references in
  `legacy_records` and history;
- records one disposition per entity: `imported` or `quarantined`, with a
  reason and the original payload;
- writes the report and records the run in the database.

A repeated import of the same hash returns the stored report instead of
duplicating rows.

## Quarantine

Ambiguity is reported, not guessed. Typical quarantines:

- a task line with a duplicate field, a field-less segment or a legacy v1 key;
- a missing or duplicate ID;
- `waiting` without `waiting_on`, or an archived task without a resolution;
- an unparseable date, or a checkbox that contradicts its list;
- a malformed routine row;
- a project suffix that resolves to zero or several projects.

The original line is retained in the report. Fix the source copy only if you
intend to re-import a new hash; do not silently rewrite the old store.

## Verify

```sh
./ztd migrate verify \
  --source /path/to/legacy-copy \
  --agent-export /path/to/agent-export.json \
  --target ~/.ztd/ztd.db
```

`verify` recalculates the source hash and compares the completed run with the
stored dispositions. It does not modify data.

## Documents

Once `migrate import` has populated the staging database, populate the
document layer from the same copy:

```sh
./ztd migrate documents \
  --source /path/to/legacy-copy \
  --mapping /path/to/mapping.json \
  --workspace /path/to/workspace \
  --dry-run
```

- `--source` is the same verified, quiescent copy as `migrate import`: a
  pending legacy journal (`.state/pending.json`) stops the command before any
  document file is read. The live `~/.ztd` store is never read directly.
- `--mapping` is optional JSON in the same shape as the import mapping:
  `{"default_scope":"personal","contexts":{"familia":{"scope":"personal"},…}}`.
  A context entry overrides the built-in scope rules; `default_scope` is the
  fallback for everything else (`personal` unless the mapping says otherwise).
- `--workspace` defaults to the current directory and is used only to resolve
  the relative clone paths found on project cards.
- `--dry-run` prints the planned counts and every warning without writing.

### Path → kind

| Legacy path | Kind | Slug |
| --- | --- | --- |
| `knowledge/**.md` | `knowledge` | path relative to `knowledge/` without `.md` |
| `knowledge/**/index.md` (root `knowledge/index.md` → `index`) | `knowledge_index` | same as above |
| `reading/**.md` | `knowledge` | `reading/<path relative to reading/>` |
| `goals/active.md`, `goals/archive.md` | `knowledge` | `goals/active`, `goals/archive` |
| `lists/projects/**.md` | `project_note` | path relative to `lists/projects/` (the project id, e.g. `opensource/ztd`) |
| `plans/daily/YYYY-MM-DD.md` | `plan_daily` | `YYYY-MM-DD` |
| `plans/weekly/*.md` | `plan_weekly` | basename without `.md` |
| `reviews/**.md` | `review` | path relative to `reviews/` |
| `journal/YYYY-MM-DD.md` | `journal` | `YYYY-MM-DD` |
| `calendar.md` | `calendar` | `calendar` |
| `adoption.md` | `adoption` | `adoption` |
| `passion.md` | `passion` | `passion` |
| `routines/daily.md`, `routines/weekly.md` | `routine` | `daily`, `weekly` |

Any other `.md` file is a warning and a skip: no kind is invented. The same
applies to invalid UTF-8, an empty body and a slug the document grammar
refuses. Store bookkeeping (`config.json`, `contexts.md`, `inbox.md`,
`lists/{next,waiting,someday,archive}.md`, `routines/state.md`, `ztd.db*`,
`.ztd-assets.json`, the root `README.md`, `.git/`, `.state/`, `templates/`)
is skipped silently and not counted.

Every imported document gets the title of its first `# ` heading (the slug
when there is none), status `verified` and revision 1, with the exact file
bytes as body and one history event per insert or update.

### Scope rules

Resolution, in order:

1. the `--mapping` `contexts` entry, when it matches the context key;
2. the built-in rules: `opensource` → `opensource`, `trabajo` →
   `client:prisamedia`, `familia`/`propiedades` → `personal`, `salud` →
   `salud`;
3. otherwise `default_scope` (`personal` by default).

The context key is the first path segment under `knowledge/` and under
`reviews/` (a file directly in those directories has none) and the project id
prefix for `project_note`; `reading/…` and every other kind carry no key.
Scopes that do not exist yet are declared by the import, so `ztd check` stays
green.

### Idempotency

Each file is compared against the existing `(scope, kind, slug)` document:
an identical body, title and status counts as `unchanged` and writes nothing,
a changed body updates the document at its current revision, and a new file
inserts at revision 1. Re-running the same copy reports every file as
unchanged and creates no duplicates.

### Project repositories

Each imported project note is parsed for its `## Repositories` (or legacy
`## Repositorios`) Markdown table — columns name, remote URL, local path,
status — and the first data row fills the matching project:

- only empty fields are filled; a different non-empty value is kept and
  reported as a warning;
- a relative local path resolves against `--workspace`, an absolute path is
  kept, and a `..` segment or a non-absolute result is refused with a
  warning;
- an unknown project or an unusable URL is a warning, never a failed import.

The run returns `{inserted, updated, unchanged, skipped, warnings}`;
`ztd check` must pass afterwards.

## Cutover

Do not switch your routines to the new database until:

- every source entity has exactly one disposition;
- quarantines are understood and accepted;
- two imports into fresh staging databases produce equivalent reports;
- an interrupted import resumes without duplicates;
- `ztd check` passes;
- `export` followed by `restore` into an empty database reproduces counts, IDs
  and original texts.

The legacy Markdown store stays read-only. There is no bidirectional sync and
no second canonical copy.
