---
name: Review with ZTD
description: Run the weekly or monthly review, adjust routines, explore interests and record the journal with real results and learning.
---

# Review

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Get the local date and the
requested period. Limit journal, calendar and reviews to the requested period.

## Weekly review (default)

1. Run `ztd check` and record inconsistencies. Read the goal and sub-goal;
   gather observable progress.
2. Review the inbox (`ztd list --list inbox`), notes and the week's journal
   (`ztd doc list --kind journal`). Load `ztd-process` for
   entries that need a decision; note those still pending.
3. Review the previous and upcoming calendar (`ztd doc get --kind calendar
   --slug calendar`); if the user relies on an
   inaccessible external source, ask for its relevant commitments and record
   that limitation.
4. Review next actions, waitings, someday and projects with filtered queries.
   Flag waitings whose `waiting_on` ends with an `@YYYY-MM-DD` date earlier
   than today; list them with the date and the dependency.
   With no requested or selected scope, a valid `data.binding`
   (`ztd status --json`) may default those filters; a malformed binding means
   stop and ask first — a routing hint only, never a root source.
   Reuse the week's external coverage (`ztd source list --all`); update only pending or
   invalidated sources, or all if requested. Use `ztd-trusted-system` for
   inconsistencies and `ztd-simplify` to reduce load.
5. Review the habit in practice with `ztd doc get --kind adoption --slug
   adoption`; adjust from real experience.
6. Record the review with `ztd review weekly --period YYYY-Www --outcomes ...
   --coverage ...` and load
   `ztd-plan` for the next sub-goal/week. About 30 minutes as a guide.
7. After recording the review, mark the `review` routine done with
   `ztd routine done review` when its row exists (`ztd routines due` lists the
   rows); if the row is absent, say so and continue — there is no command to
   add a routine row yet. The monthly review does not mark it.

## Monthly review

Widen the period, examine the goal's direction, commitments and adoption;
record it with `ztd review monthly --period YYYY-MM --outcomes ... --coverage
...`. It does not automatically start other
habits.

## Routines

Read the due rows (`ztd routines due`), the routine patterns
(`ztd doc get --kind routine --slug daily|weekly`), adoption
(`ztd doc get --kind adoption --slug adoption`) and recent reviews
(`ztd doc list --kind review`).

1. Identify real repeated activities and available moments.
2. Adjust start, close or weekly batching for the requested scope.
3. Define a cue, few steps and a viable minimum; keep the middle of the day
   free for MITs. Do not impose the book's schedules or unrequested personal
   practices.
4. Save the routine as a pattern (`ztd doc put --kind routine --slug
   daily|weekly`), not as duplicated tasks for each date; no command adds a
   routine row yet, so it will not appear in `ztd routines due` until one
   exists.
5. Agree when to review the experience. Record real practice in the journal
   (`ztd doc put --kind journal --slug YYYY-MM-DD`) or adoption
   (`ztd doc put --kind adoption --slug adoption`) only when known; move to
   one habit at a time when possible.

## Interests and experiments

Read the passion record (`ztd doc get --kind passion --slug passion`) and the
relevant reflections (`ztd doc list --kind journal`).

1. Ask which activities spark curiosity, energy or willingness to practice.
2. Pick a hypothesis and a small test with an observable outcome and a review.
3. Keep observations and the experiment in the passion record (`ztd doc put
   --kind passion --slug passion`), distinguishing
   interest from commitment. If an action is agreed, capture it with
   `ztd capture` and reference its ID; do not record it only in this document.
4. After the test, gather real experience and decide to continue, adjust or
   explore.

This is an optional habit. Do not assume career changes or a single passion.

## Journal

With `/ztd/journal`, record the user's text or reflections with `ztd doc put
--kind journal --slug YYYY-MM-DD --title T --body TEXT`. When content is missing, ask
briefly for the day's outcome and learning. Do not attribute emotions or
achievements that were not shared. It does not require checking every list nor
walking external sources. Write facts, learning and brief links, without
rebuilding the day's chronology. Capture new actions with `ztd-collect` and
link their IDs in the journal.
