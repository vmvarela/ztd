# MCP

ZTD exposes a local stdio MCP server over the same application layer as the
CLI. It is one process per host session, started by the client, and it closes
when the client disconnects. There is no daemon and no network listener.

The server is the smallest typed surface that supports the ZTD habits. It is
not a generic database API: there is no raw SQL, no arbitrary update, no
scope override and no provider tool.

## Start it

```sh
go build -o ./ztd ./cmd/ztd
./ztd mcp
```

The server reads the same database as the CLI: `--db`, `ZTD_DB` or
`~/.ztd/ztd.db`. It writes JSON-RPC to stdout and diagnostics to stderr.

Register it with OpenCode using an absolute binary path. There is one server
and one planning view:

```sh
opencode mcp add ztd -- /absolute/path/to/ztd mcp
```

The server starts with the default binding of the CLI: the planning profile
without `client:*` and `work` scopes, so a personal session never returns
client work. A client session selects its scope when the server starts — a
tool argument cannot:

```sh
ztd mcp --scope client:prisamedia
# or, as host configuration:
ZTD_SCOPES=client:prisamedia ztd mcp
```

The binding is fixed when the process starts; a tool argument cannot widen it.
Every row still carries its own scope, so captures and work items remain
labelled. There is no second `ztd_work` server and no `ztd_work_*` permission
key.

## Tools

| Tool | Purpose |
| --- | --- |
| `capture` | Store text in the inbox |
| `inbox_next` | Return the oldest pending capture plus remaining counts |
| `process_capture` | Turn a capture into work items, a reference, an immediate result, a defer or a discard |
| `prepare` | Read-only daily brief: active goal, committed MITs, candidates, latest checkpoints, and source coverage when sources exist |
| `commit_plan` | Commit a daily or weekly plan |
| `focus_start` | Open the actor's single focus session |
| `checkpoint` | Record progress without changing the work item revision |
| `focus_finish` | Close the focus session |
| `record_review` | Record a daily, weekly, monthly or yearly review |
| `find` | Search visible work items; default 8, maximum 20 |
| `read` | Expand up to 5 work items or captures by ID |
| `sources` | List configured sources: identity, kind, connector, coverage and cursor; never provider contents |
| `record_source_review` | Ingest one reported batch for a source as pending captures |
| `doc_search` | Full-text search over the bound scopes' documents: document, rank and snippet, best match first |
| `doc_get` | Read one document by kind and slug, body included; a foreign-scope document is `not_found` |
| `doc_related` | Return a document's outlinks and backlinks, resolved inside its own scope |

`process_capture` accepts `expected_revision`; omitting it (or passing 0)
skips the optimistic revision check, while the pending/deferred state guard
still prevents double processing. `read` fails the whole batch if any ID is
missing; ask for fewer IDs when partial results are preferable.

Every mutation requires `idempotency_key`. The server hashes the canonical
payload, so the same key and payload replay the stored result and the same key
with different content fails with `idempotency_conflict`.

### Sources and the reported boundary

`sources` is read-only registry state for the fixed binding: what sources
exist, their coverage (`unknown`, `unverified`, `partial`, `complete`,
`failed`) and cursor. It returns no provider rows and starts no retrieval.

`record_source_review` accepts `source_id`, `batch_id`,
`idempotency_key`, an optional `retrieval`, `items[]`, and an optional
`result_kind` that defaults to `reported`. Honesty rules:

- **`observed` is rejected with `invalid_input`**, at the tool and again in
  the service. Only a trusted host adapter — configured by the operator
  outside model-controlled arguments and not exposed as a tool — may record
  observed coverage. A model cannot upgrade its own batch by naming it
  observed or by adding evidence-like fields.
- A reported batch is stored as `unverified` (or `partial` when the retrieval
  had failures or was truncated, `failed` when it had no items and failures),
  never `complete`. It never advances the source cursor.
- Each item becomes one pending capture in the source's scope; the batch
  replays by idempotency key, so a retry does not duplicate captures.
- Limits: 64 KiB per item text, 500 items per batch. Omitting `retrieval`
  means the window is unknown. A reported batch updates `last_attempt_at`, not
  `last_success_at`.
- When sources exist, `prepare` surfaces unverified or partial coverage —
  an unread or partially read source is never presented as an empty, fully
  reviewed one.

Source registration stays an operator command (`ztd source add`); no tool
creates sources, and no tool contacts a provider. See
[Sources](sources.md) for the batch file shape and the cursor rule.

## Prompts

`Collect`, `Process`, `Plan`, `Do`, `Review`, `Simplify`, `Routines` and
`Passion` are short procedural prompts. They name the habit, point at the
relevant tools and leave scheduling to the host and the user. A disconnected
stdio server cannot remind anyone.

`Review` states that connected-source review is unavailable until source
connectors are configured. An empty inbox is not evidence that every source was
reviewed, and a reported batch never becomes observed coverage by being
narrated confidently.

## Approval and scope

- `commit_plan` is a human decision. The tool has no `human_approved`
  argument because a model-supplied boolean proves nothing. The host must gate
  the call with a real permission prompt. If your host auto-approves MCP tools,
  do not register this server in a context where plan commitments can run
  unattended.
- `focus_start` and `commit_plan` are otherwise safe to call; the
  service enforces the global one-focus and 1–3 MIT rules.
- Every read and write is filtered by the fixed `ScopeBinding`. `scope_denied`
  is returned to the model as `not_found`, and the detail is scrubbed, so a
  foreign entity's existence is not disclosed.
- `commit_plan` still requires an override when a day exceeds three MITs;
  that path returns `rules_acknowledgement_required`.

OpenCode permission keys use the `server_tool` form, for example
`ztd_commit_plan`. The deny/allow check was verified on OpenCode 2.3.2 with
the pre-rename keys; after the 2026-11-20 rename re-run it with
`ztd_capture` — `deny` must remove the tool from the catalog and fail the
call with `Unknown tool`, `allow` must execute it. The current keys are:

```json
"permission": {
  "ztd_capture": "allow",
  "ztd_inbox_next": "allow",
  "ztd_prepare": "allow",
  "ztd_find": "allow",
  "ztd_read": "allow",
  "ztd_sources": "allow",
  "ztd_checkpoint": "allow",
  "ztd_focus_start": "allow",
  "ztd_focus_finish": "allow",
  "ztd_process_capture": "ask",
  "ztd_commit_plan": "ask",
  "ztd_record_review": "ask",
  "ztd_record_source_review": "ask"
}
```

There is one server, `ztd`, and one permission block. The planning view is
the binding fixed at startup — the personal scopes by default — and the
permission split above still applies to every tool call.

`ask` is only a real gate in an interactive session. `opencode run --auto`
approves it; do not use that flag for plan or review writes.

## Deferred

Provider and calendar connectors are not exposed: no tool calls GitHub, Jira,
email or a calendar, and `observed` coverage stays reserved for a trusted host
adapter that does not exist yet. The current tool list is dynamic; adding the
connector tools later does not change the contract above.

## Verify

```sh
go test ./internal/mcpserver
go test ./test/integration -run MCP -count=1
```

The integration test starts the real binary over stdio, runs the capture to
review journey, checks a lost-response replay with the same idempotency key,
and covers the source flow: register through the CLI, list with `sources`,
record a reported batch, replay it without duplicating the capture, and prove
`observed` is refused.
