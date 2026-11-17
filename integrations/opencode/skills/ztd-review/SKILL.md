---
name: Review with ZTD
description: Run the weekly or monthly review, adjust routines, explore interests and record the journal with real results and learning.
---

# Review

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Get the local date and the
requested period. Limit journal, calendar and reviews to the requested period.

## Weekly review (default)

1. Run `ztd check` and record inconsistencies. Read the goal and sub-goal;
   gather observable progress.
2. Review the inbox, notes and the week's journal. Load `ztd-process` for
   entries that need a decision; note those still pending.
3. Review the previous and upcoming calendar; if the user relies on an
   inaccessible external source, ask for its relevant commitments and record
   that limitation.
4. Review next actions, waitings, someday and projects with filtered queries.
   With no requested or selected scope, a valid `data.binding`
   (`ztd status --json`) may default those filters; a malformed binding means
   stop and ask first — a routing hint only, never a root source.
   Reuse the week's external coverage records; update only pending or
   invalidated sources, or all if requested. Use `ztd-trusted-system` for
   inconsistencies and `ztd-simplify` to reduce load.
5. Review the habit in practice in `adoption.md`; adjust from real experience.
6. Save `reviews/YYYY-MM-DD-weekly.md` with the review template and load
   `ztd-plan` for the next sub-goal/week. About 30 minutes as a guide.

## Monthly review

Widen the period, examine the goal's direction, commitments and adoption;
record `reviews/YYYY-MM-DD-monthly.md`. It does not automatically start other
habits.

## Routines

Read `routines/daily.md`, `routines/weekly.md`, adoption and recent reviews.

1. Identify real repeated activities and available moments.
2. Adjust start, close or weekly batching for the requested scope.
3. Define a cue, few steps and a viable minimum; keep the middle of the day
   free for MITs. Do not impose the book's schedules or unrequested personal
   practices.
4. Save the routine as a pattern, not as duplicated tasks for each date.
5. Agree when to review the experience. Record real practice in the
   journal/adoption only when known; move to one habit at a time when possible.

## Interests and experiments

Read `passion.md` and the relevant reflections.

1. Ask which activities spark curiosity, energy or willingness to practice.
2. Pick a hypothesis and a small test with an observable outcome and a review.
3. Keep observations and the experiment in `passion.md`, distinguishing
   interest from commitment. If an action is agreed, capture it with
   `ztd capture` and reference its ID; do not record it only in this document.
4. After the test, gather real experience and decide to continue, adjust or
   explore.

This is an optional habit. Do not assume career changes or a single passion.

## Journal

With `/ztd/journal`, add the user's text or reflections to
`journal/YYYY-MM-DD.md` using its template. When content is missing, ask
briefly for the day's outcome and learning. Do not attribute emotions or
achievements that were not shared. It does not require checking every list nor
walking external sources. Write facts, learning and brief links, without
rebuilding the day's chronology. Capture new actions with `ztd-collect` and
link their IDs in the journal.
