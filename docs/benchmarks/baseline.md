# Baseline (Stage 0.1)

Reproducible numbers for the Go v2 binary and the Zig v3 candidate, measured on
the same machine with `scripts/benchmark.sh`. Re-run it before and after any
optimization pass; the script prints this same table.

```sh
./scripts/benchmark.sh
```

## Environment

| item | value |
|---|---|
| machine | Apple Silicon (arm64), macOS |
| Go | /opt/homebrew/bin/go (go 1.27.4) |
| Zig | /Users/victor/bin/zig (0.17.0) |
| SQLite | 3.50.4 amalgamation (Zig build) |

## Results

| métrica | Go v2 | Zig v3 |
|---|---|---|
| binario (bytes) | 12,853,666 | 1,753,664 |
| arranque medio (ms) | 3.42 | 1.64 |
| RSS máximo (bytes) | 14,057,472 | 1,982,464 |
| tools/list (bytes) | 31,306 | 196 |
| DB tras journey (bytes) | 376,832 | — |

Notes:

- Go is built from the same tree with `-trimpath -ldflags='-s -w'`, so the size
  comparison is stripped-vs-stripped. The Homebrew 0.3.0 install (12.2 MB) is the
  same order.
- Zig is `zig build --release=fast`, which strips. Startup and RSS are measured
  with `version`, the cheapest real command.
- `tools/list` measures the serialized JSON-RPC response line for the whole
  tool list. Go's 31,306 bytes with 17 tools confirms the second-review finding:
  a 12 KiB budget is unreachable and the v3 target is "no growth over baseline",
  not a smaller payload. Zig's 196 bytes is the spike's single `ping` tool, not a
  comparison; it becomes one once the 19 tools exist.
- The Zig DB column is empty until write paths land (Stage 1). The journey is
  fixed in the script: init, 3 captures, 2 processed work items, 1 waiting, one
  knowledge doc, a project, a goal, a routine, a daily review, and a focus
  session. The same journey must produce a DB within 5% of the Go size.

## Thresholds

From the spec §10, applied at Stage 5 unless noted:

| metric | target |
|---|---|
| binary | ≤ 3 MB |
| RSS | ≤ 12 MB |
| startup | ≤ 8 ms |
| DB after the journey | within 5% of Go |
| `tools/list` | no growth over the measured baseline |
| production LOC | store+app ≤ 9k, total ≤ 12k with waiver |
| tokens | ≥ 30% fewer per working day (goal with waiver) |

Binary, RSS and startup are already inside target at Stage 0; they are not a
license to skip the optimization pass, because the 19 tools and the full store
will grow them.

## Stage 5 results (Zig v3, after the port)

Measured with `scripts/benchmark.sh` on `defd5dd` + the usage/README commits:

| metric | Go v2 | Zig v3 | target | verdict |
|---|---|---|---|---|
| binary | 12,853,666 B | 2,936,192 B | ≤ 3 MB | inside (4.4× smaller) |
| startup (mean) | 4.21 ms | 1.07 ms | ≤ 8 ms | inside |
| RSS max | 13,910,016 B | 2,080,768 B | ≤ 12 MB | inside (6.7× smaller) |
| `tools/list` | 31,306 B | 32,035 B | no growth | **+729 B (2.3%) waiver** |
| production LOC | 14,026 | 11,389 (all Zig, tests included) | store+app ≤ 9k, total ≤ 12k | inside total |

The `tools/list` growth is the schema of `trace`, the single tool the spec
allows the rewrite to add; everything else is folded into existing tools. The
19 registered tools (18 with `delete_source`, 17 by default) otherwise carry v2's
payload unchanged, so hosts see one new tool and no reshaped schemas.

LOC is counted with `wc -l src/*.zig src/store/*.zig`, which includes the
in-file unit tests; the production share is lower.
