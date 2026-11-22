# Legacy inventory

Source of truth for the v1 format is `repos/opensource/ztd/docs/spec.md` and its
Zig parser. This file records what the importer must accept. It is not a
second specification: where they differ, the Zig behavior wins because real
stores were written by it.

## Store

```text
config.json          {"format":2,"policy":{"requireClientFor":[],"clientOnlyIn":[]}}
contexts.md          Markdown table; first cell of each data row is a context
inbox.md
lists/{next,waiting,someday,archive}.md
lists/projects/<context>[/<client>]/<project>.md
plans/daily/YYYY-MM-DD.md
plans/weekly/*.md
routines/state.md
goals/ journal/ knowledge/ reviews/ reading/ calendar.md  # copied, never parsed
templates/ .state/                                       # never imported
```

Missing `config.json`, a non-2 `format`, a missing canonical file, or a pending
`.state/pending.json` refuses the import. `last-transaction.json` is history.

## Task line

```text
- [ ] T-YYYYMMDD-NNN | Title | key: value | key: value
- [x] T-YYYYMMDD-NNN | Title | ... | closed_at: YYYY-MM-DD | resolution: text
```

- Status char: `' '`, `x` or `X`. Archive requires `x`; active lists require space.
- Separator is exactly ` | ` and must not be escaped. `\|` is the only escape.
- The first segment is the title. A later segment without `": "` is folded back
  into the title by the legacy parser. The importer quarantines such lines
  instead of reproducing the fold.
- Duplicate field keys and duplicate IDs across all five lists are errors.
- Reserved keys: `context`, `client`, `project`, `captured_at`, `closed_at`,
  `waiting_on`, `resolution`. Any other key is custom and preserved verbatim.
- `captured_at` differs from the ID date only as a warning.
- Archive requires `resolution` and `closed_at`; active lists forbid them.
- `waiting_on` is free text; a trailing `@YYYY-MM-DD` is a convention only.

## Contexts, projects, routines

- `contexts.md`: rows starting `|`; skip empty, exactly `Context`, or all `-`.
  Context names are opaque trimmed strings. Leftover `Contexto` is a v1 signal.
- A project is registered by file existence. Its ID is the relative POSIX path
  below `lists/projects/` without `.md`; its first segment equals the context.
  `index.md` is itself registrable. A bare suffix may resolve only when exactly
  one file matches; zero or several is `unknown_project`.
- `routines/state.md`: exactly three cells, leading and trailing `|`.
  ID `[a-z][A-Za-z0-9_-]*`; cadence `daily` or `weekly:(mon|tue|wed|thu|fri|sat|sun)`;
  last `YYYY-MM-DD`. Zero data rows, bad cells, duplicate IDs are errors.

## References

Any `T-\d{8}-\d{3,}` token in any `.md` outside `templates/` and `.state/` is a
reference. Unknown references are check errors in v1. Imports preserve them and
report dangling ones; they are never repaired silently.

## Agent export v2

```json
{"format":"ztd-agent-export","version":2,
 "scopes":[{"id":"..."}],
 "assignments":[{"id","scope_id","request","objective","constraints","project",
                 "status","rev","created_at","updated_at"}],
 "checkpoints":[{"id","assignment_id","kind","result","evidence","next_action",
                 "rev","created_at"}],
 "operations":[{"key","request_sha256","result_json","created_at"}],
 "knowledge":[{"id","scope","kind","text","source","rev","created_at"}]}
```

- Nullable columns are JSON `null`, never `""`.
- `request_sha256` is 64 lowercase hex digits of the 32-byte digest.
- Assignment status `open|done|cancelled`; checkpoint kind `progress|done`;
  knowledge kind `fact|decision|constraint|procedure` and `rev` always 1.
- Assignment `rev = 1 + checkpoint count`; checkpoint `rev` is in
  `[2, assignment.rev]` and unique within an assignment.
- Version 1 has no `knowledge` array.
- `result_json` is opaque. The importer copies it; it does not verify legacy
  idempotency digests.

## Quarantine, never guess

Pending journal; legacy reserved keys inside a current store; ambiguous field segments;
duplicate fields or IDs; checkbox/list mismatch; missing canonical files;
malformed contexts rows; ambiguous project suffix; unparseable dates; invalid
routine rows; dangling references. Each gets a disposition with the original
text and a reason in the migration report.

## Draft scope mapping

Synthetic imports use the fixture mapping below. A real import requires the
operator to confirm it first.

| Legacy context | Scope | Area |
| --- | --- | --- |
| familia | personal | familia |
| salud | personal | salud |
| propiedades | personal | propiedades |
| opensource | opensource | opensource |
| work + client acme | client:acme | work |
| work + no client | work | work |

Legacy agent scopes are mapped separately: `work` → `client:acme` only if the
operator confirms that assignment belongs to that client; otherwise `work`.
