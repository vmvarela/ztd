# Sources

A source is a registered origin of captures: a manual entry point, a
directory, or a host-side MCP connector. Sources live in one scope, carry no
secrets, and record how far retrieval has reliably reached. They are operator
configuration — the model can read them, but it cannot register one.

## The registry

```sh
ztd source add --id notes-dir --name "Notes directory" \
  --scope personal --kind capture --connector directory --cadence daily
ztd source list --all
```

`source add` is operator-facing: `--scope` is explicit and must name a scope
that exists. `source list` selects with exactly one of `--all` (also the
default) or a repeatable `--scope`; combining selectors is `invalid_input`,
and a listing never shows a scope outside the requested set.

A source has:

- `id` matching `[a-z][a-z0-9_-]{1,63}`, unique across the database.
- `scope` — exactly one scope, checked against the command's binding. A
  source outside the binding is `scope_denied` on write and invisible on read.
- `kind` — `capture` (feeds the inbox) or `calendar` (bounded observations for
  planning). Calendar behavior beyond the registry is not built yet.
- `connector` — `manual`, `directory` or `host_mcp`. This records *how* items
  arrive; it does not start any process.
- `provider`, `connection_ref`, `non_secret_query`, `cadence` — non-secret
  configuration. A `connection_ref` names provider configuration held by the
  OS or an authenticated host. Secrets are never stored in the source table,
  in exports, or in anything the model reads.

Re-adding the same `id` with an identical configuration returns the existing
source without writing; the same `id` with a different configuration fails
with `conflict`.

For a manual capture, omit `--source` (or MCP `source_id`); it uses the
unregistered entry point, stored with the provenance `MANUAL`. Imported legacy
records use `LEGACY`. Both are upper case, which no source ID can have, so a
source named `manual` or `legacy` never collides with them. An explicit source
ID must name a registered source in the capture's primary scope; a missing one
is `not_found`.

## Deleting a source

```sh
ztd source delete --id notes-dir
```

Deletion removes the registry row and records a `deleted` history event with
the source's last state; earlier `created` and `updated` history stays. A
source is deleted only while nothing refers to it: if a capture of its scope or
any source review still names it, the command fails with `conflict` and writes
nothing.
Process or leave those captures alone rather than deleting around them.
An unknown id is `not_found`.

The operator command selects across every declared scope, like `source list
--all`. The MCP tool `delete_source` is bound to the server's fixed scopes,
requires an `idempotency_key`, and exists only when the server starts with
`--allow-delete-source`; a source outside those scopes and a missing source
both answer `not_found`. See [MCP](mcp.md). Deleting a source is never implied
by `source apply`: a file that omits an id leaves that source in place.

A deleted id is retired. `source add` and `source apply` refuse it with
`conflict`, so its deleted history stays unambiguous.

Captures written before this split stored the implicit entry point and legacy
imports as the lower-case `manual` and `legacy`. Those rows are not rewritten
automatically. A lower-case `manual` row remains ambiguous with a capture of a
registered source, so it blocks deleting that source. An old `legacy` row is
excluded from the delete guard only when its `capture/imported` history event
proves the import in the same scope; an unproven row still blocks deletion.
This change does not migrate ambiguous historical rows.

## User configuration

Sources are user configuration, not product code. ZTD knows only the generic
fields above; it has no provider list, no provider-specific branches, and it
never performs retrieval. The host or MCP server the user configured owns the
actual connector.

Apply a JSON file to synchronize the registry:

```json
{"sources": [
  {"id": "github", "name": "GitHub notifications", "scope": "personal",
   "kind": "capture", "connector": "host_mcp", "provider": "github",
   "connection_ref": "github-main", "cadence": "daily"},
  {"id": "notes", "name": "Notes directory", "scope": "personal",
   "kind": "capture", "connector": "directory", "non_secret_query": "~/notes"}
]}
```

```sh
ztd source apply                  # reads ~/.ztd/sources.json
ztd source apply --file other.json
```

The default path is `~/.ztd/sources.json`; set `ZTD_SOURCES` to override it.
`apply` re-reads the file on every run, so edit it and run the command again to
synchronize changes. It is a bounded, transactional sync (at most 200 entries). Missing ids
are inserted; existing ids in the same scope update their configuration and
keep coverage, cursor, and auth state; identical entries are untouched. An id
owned by another scope is `conflict`. The whole file is rejected if any entry
is invalid.

`apply` is an operator command: the source configuration does not belong to a
planning view. The command binds to the union of the scopes the file declares
and validates that every one of them exists before it writes anything, so a
typo in a scope id rejects the whole file with `invalid_input` and leaves the
registry untouched.

## Reported vs observed: the trust boundary

Every recorded batch has a `result_kind`:

- **`reported`** — someone or something *says* this is what a source
  contained. The CLI `source review` command and the model-facing
  `record_source_review` tool can only produce `reported`. Coverage is
  stored as `unverified` (or `partial`/`failed`, see below) and **never** as
  `complete`.
- **`observed`** — a trusted host adapter, configured by the operator outside
  model-controlled arguments, records the result of an actual provider
  exchange. No such adapter exists yet, so `observed` is rejected on every
  model-facing path: the service refuses it with `invalid_input`, and the MCP
  tool refuses it before reaching the service. Only a direct `Repo` caller
  acting as the trusted adapter can record it.

A model cannot upgrade its own trust level. A `provider_execution_ref`, an
identifier, or any other evidence-like field it supplies stays `reported`.
Plain prose claiming retrieval success establishes nothing.

## Coverage states

| State | Meaning |
| --- | --- |
| `unknown` | Registered, no batch recorded yet. |
| `unverified` | A reported batch arrived; nobody has confirmed it against the provider. |
| `partial` | The retrieval had failures or was truncated — some of the window was not read. |
| `complete` | Reserved for an observed batch that provably read its whole window. |
| `failed` | A batch with no items and at least one failure. |

Empty with errors is not the same as empty and complete. A failed or partial
retrieval keeps its gap visible: `prepare` and the source views surface
unverified, partial, and failed coverage whenever sources exist, so an
unreviewed source never looks like an empty one.

## The cursor rule

The source owns one `cursor`, the last position that was *reliably* read.

- A cursor advances only for an `observed` batch whose window is complete,
  untruncated, and failure-free. A `reported` batch never moves it.
- After a partial page, the captures already committed stay durable, the
  incomplete region stays pending, and the cursor does not skip it.
- A retry reuses the same external identity (`source_id`, `external_id`,
  `external_revision`), so it cannot duplicate captures. A changed
  `external_revision` creates a new capture and leaves the old one intact.

## No provider or network connector yet

This release registers sources and ingests batches you feed it. It does not
call GitHub, Jira, email, calendars, or any network service; there is no
background scanner and no directory watcher. `directory` and `host_mcp` name
how a batch will arrive once a trusted host adapter exists, not a process
running now. Nothing here implies that a configured source has been read.

## How to feed a batch

Write the batch to a JSON file, then review it against a registered source:

```sh
ztd source review --source notes-dir --batch batch-1 --key review-2026-11-20 \
  --file batch.json
```

`--source`, `--batch` and `--key` are required; each overrides the matching
field in the file. The file shape is:

```json
{
  "source_id": "notes-dir",
  "batch_id": "batch-1",
  "idempotency_key": "review-2026-11-20",
  "result_kind": "reported",
  "retrieval": {
    "window": "2026-11-20",
    "cursor": "",
    "requested_limit": 50,
    "provider_returned_limit": 1,
    "complete_window": true,
    "truncated": false,
    "failures": []
  },
  "items": [
    {
      "external_id": "note-001",
      "external_revision": "1",
      "original_text": "renew the parking permit before the trip",
      "source_uri": "file:///notes/note-001.md",
      "provider_metadata_summary": "file note, title only"
    }
  ]
}
```

- `result_kind` defaults to `reported`; `observed` is rejected.
- Each item becomes one pending capture in the source's scope, carrying its
  external identity and `source_uri`. You process it from the inbox exactly
  like a manual capture.
- Bounds are fixed: each `original_text` is at most 64 KiB and a batch at most
  500 items. Larger input fails with `invalid_input` and writes nothing.
- `retrieval` is optional, but omitting it means the window is unknown; send
  it whenever the producer knows the window, cursor, limits and failures.
- `last_success_at` is only set by an `observed`, failure-free batch. A
  reported batch updates `last_attempt_at` only, because it proves a message
  arrived, not that the provider was read.
- The batch is idempotent by `--key`: the same key and payload replay the
  stored review and captures; the same key with a different payload fails with
  `idempotency_conflict` and writes nothing.
- `retrieval` records what the window claimed, not what was verified. With
  `failures` present or `truncated` true, coverage is `partial`; with no items
  and failures, `failed`; otherwise `unverified`.

Over MCP the same batch goes through `record_source_review` with the same
rules; see [MCP](mcp.md).
