---
name: Plan with ZTD
description: Pick daily MITs, weekly Big Rocks or an active goal from real capacity and commitments.
---

# Plan

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Read `goals/active.md`,
`calendar.md`, actions/waitings through `list` with filters, and only the
relevant project cards. Do not walk knowledge indexes or cards without candidate
actions. Get the current local date; interpret an explicit date when provided.
With no scope in the request or from a selected task, default those `list`
filters from a valid `data.binding` (`ztd status --json`); a malformed binding
means stop and ask before scope-based work — a routing hint only, never a root
source.

## Day

1. For today, load `ztd-process`. Follow its "Daily review and coverage"
   section only when the store registers external sources and the request asks
   for a review — it is optional and configured, never an unconditional daily
   obligation. Apply only clear decisions authorized by the request and report
   pending accesses without blocking the plan. Do not process or automatically
   import every capture or finding. For future/past dates do not simulate that
   day's coverage.
2. Read the day plan if it exists and the week plan; consult the journal only
   when it affects capacity or priorities. Preserve results and decisions
   already recorded.
3. Consider commitments and known availability; ask only what is missing to choose.
4. Pick 1–3 MITs in total, not per context. Connect one to the goal when one
   exists. For each MIT, note in one line which outcome would make it enough today.
5. Use `templates/day.md` for `plans/daily/YYYY-MM-DD.md`.
   Reference canonical IDs and propose blocks with slack and batched small tasks.
6. Reuse the file when it exists, preserving results; do not drag open items
   along automatically nor create new tasks to fill gaps.

## Week

1. Compute the Monday of the requested week (current by default).
2. Read the previous review, calendar and goals. Choose few Big Rocks: 4–6 as
   a guide.
3. Save `plans/weekly/YYYY-MM-DD.md` from `templates/week.md`, with IDs and
   proposed blocks according to capacity. Honor real dates from every client.

## Goal

Review or define with the user the outcome, reason, achievement criterion,
horizon, mantra and near sub-goal in `goals/active.md`. When an existing goal
changes, clarify whether it was completed, paused or abandoned and keep the
record in `goals/archive.md`. One active goal does not mean a single goal for
the whole year. Agreed actions are stored canonically in the lists and
referenced by ID. If a new action appears, capture it with `ztd capture` and
process its context before moving it; do not write it only in the plan. Run
`check` after structural changes.

If there is no task or goal, say so and help define the first one; do not
invent priorities.
