---
name: Plan with ZTD
description: Pick daily MITs, weekly Big Rocks or an active goal from real capacity and commitments.
---

# Plan

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Read the active goal with `ztd goal show` and today's brief with `ztd prepare`, actions/waitings through `list` with filters, and only the relevant project cards. Do not walk knowledge indexes or cards without candidate
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
2. Read the day plan if it exists and yesterday's plan with
   `ztd prepare --date YYYY-MM-DD` (`data.plan`); the weekly plan has no read
   command yet, so ask the user for last week's Big Rocks. Consult the
   journal (`ztd doc list --kind journal`) only when it affects capacity or
   priorities. Preserve results and decisions already recorded. If
   yesterday's plan exists, list its MITs still in `next` as capacity input
   and those in `waiting` as blocked; do not move them.
3. Consider commitments and known availability; ask only what is missing to choose.
4. Pick 1–3 MITs in total, not per context. Connect one to the goal when one
   exists. For each MIT, note in one line which outcome would make it enough today.
5. Commit the day plan with `ztd plan commit --kind daily --period
   YYYY-MM-DD --item ID:mit ...` (repeat `--item`; roles `mit`, `big_rock`,
   `batch`). Reference canonical IDs and propose blocks with slack and batched
   small tasks. Omit items that have nothing to record.
6. When the plan already exists, re-commit over it with `--expected
   <revision>` (from `ztd prepare`'s `data.plan`), preserving results; do not
   drag open items along automatically nor create new tasks to fill gaps.
7. After committing the plan, mark the `plan` routine done with
   `ztd routine done plan` when its row exists (`ztd routines due` lists the
   rows); if the row is absent, create it first with `ztd routines add --id
   plan --cadence daily` (agree the cadence when it differs) and mark it done.

## Week

1. Compute the Monday of the requested week (current by default).
2. Read the previous review (`ztd doc list --kind review`; structured
   `ztd review` records have no read command yet), the calendar
   (`ztd doc get --kind calendar --slug calendar`) and the goal
   (`ztd goal show`). Choose few Big Rocks: 4–6 as a guide.
3. Commit the week plan with `ztd plan commit --kind weekly --period
   YYYY-Www --item ID:big_rock ...` (roles `big_rock` and `batch` only), with
   IDs and proposed blocks according to capacity. Honor real dates from every
   client. Omit items that have nothing to record.

## Goal

Review or define with the user the outcome, reason, achievement criterion,
horizon, mantra and near sub-goal of the active goal (`ztd goal show`; create
one with `ztd goal set --statement S`). When an existing goal changes,
clarify whether it was completed, paused or abandoned, then close the active
goal with `ztd goal complete` or `ztd goal cancel` — a new primary is refused
while one is active — and record the next statement with `ztd goal set
--statement S` if there is one. One active goal does not mean a single goal for
the whole year. Agreed actions are stored canonically in the lists and
referenced by ID. If a new action appears, capture it with `ztd capture` and
process its context before moving it; do not write it only in the plan. Run
`check` after structural changes.

If there is no task or goal, say so and help define the first one; do not
invent priorities.
