# Zen To Done: a practical summary

Source: *Zen To Done: The Ultimate Simple Productivity System*, Leo Babauta.
This is a summary of the method.

## Core idea

ZTD combines capture and organization with attention to what matters, execution
and gradual habit formation. The tool can be a notebook: what counts is using
it with confidence and acting. Simplifying the system should free up time.

Instead of emphasizing organizing every entry, ZTD adds explicit focus on goals,
few priorities, routines and doing one thing at a time. The ten habits are an
adaptable repertoire, not ten changes that must all start at once.

## The ten habits

1. **Capture.** Write down tasks, ideas and commitments in an accessible place as
   soon as they appear. Empty your head before judging whether anything needs doing.
2. **Process.** Regularly empty your inboxes by deciding on each item:
   discard, do it if it takes about two minutes, delegate, file the information,
   or note an action for later. Processing does not mean finishing everything.
3. **Plan.** Choose the big weekly priorities (*Big Rocks*) and a few important
   daily tasks (*Most Important Tasks*, MITs). Reserve space for them before
   filling the day with small tasks.
4. **Do.** Work on a single task, remove distractions, shrink the first step
   if starting is hard and keep focus. Capture interruptions without chasing
   them. Rest between blocks when needed.
5. **Simple, trusted system.** Keep lists easy to scan, by context when that
   helps. Use plain, stable tools instead of spending energy on constant system
   changes.
6. **Organize.** Give everything a place and put it back there. Apply it to
   paper, the desk, files and materials: find what you need without searching again.
7. **Review.** Reconnect every week with the goal, notes, calendar and lists.
   Close what is done, pick up loose ends and prepare the next week.
8. **Simplify.** Cut commitments, tasks and entries down to what adds value.
   Say no, delegate and batch the small stuff. Simplify after capturing.
9. **Establish routines.** Give structure to the start and end of the day and to
   weekly activities. Batch similar tasks and leave space for what matters.
10. **Find the passion.** Explore activities that spark interest, try them,
    learn and build capabilities. It is optional for using the rest of the
    system; you advance through experiments and practice, not an instant decision.

## Minimal ZTD and adoption

Minimal ZTD rests on the first four habits: capture, process,
plan and do. It can be enough on its own.

The book recommends focusing on one habit at a time, or a few if you already
have experience, practicing each for about a month. A clear cue, a small
action, tracking and commitment help. Timelines are practice guides, not
guarantees. If you miss a day, resume without rebuilding the whole system.

## Goals and priorities

- **One active goal at a time.** It does not mean a single goal for the whole
  year. It can be reached in weeks or months and make way for another.
- Break it into a near sub-goal, roughly one or two weeks, and concrete
  actions. A short mantra can help remember it.
- **4–6 Big Rocks per week** as a starting point, adjusted to real capacity.
  The forms include five slots; focus matters, not filling boxes.
- **1–3 MITs per day in total**, making sure at least one moves the goal forward.
  Obligations and appointments still exist even when they are not the chosen goal.
- Do the important work early when possible and batch small tasks so they do
  not consume every gap of attention.

## Simplified weekly review

1. Review the goal and sub-goal: progress and obstacles.
2. Review notes and captures to recover open items.
3. Look at the previous and upcoming calendar.
4. Update actions, waitings, someday and projects.
5. Choose the next sub-goal and Big Rocks, and reserve space for them.

The book suggests about 30 focused minutes, up to 45 if needed.
The review exists to trust the system again, not to decorate it.

## A possible day

When starting, review commitments and pick MITs. Prepare the environment and
work on a single task. Jot down new entries without dropping focus. In another
block, process captures and small tasks. At the end, record results and prepare
the next day. The book example's times are not mandatory.

## Store conventions

The book's forms inspire the goal, week, day and review templates that live in
[`templates/`](templates/); `ztd install templates` publishes them into
`templates/` at the store root (an edited template is never overwritten).

The task store is a SQLite database: it resolves as `--db` > `ZTD_DB` >
`~/.ztd/ztd.db`, never from the current directory. `ztd status [--json]`
reports `database`, `profile`, `actor`, `scopes`, `effective_scopes`,
`binding` and `warning`; it never creates files. `ztd init` creates the
database and declares the scopes that make up the planning view. Routine rows
(`inbox`, `plan`, `review`) arrive with a migrated store
(`ztd migrate import`) and are scheduling defaults, not obligations:
`ztd routine done ID` marks one only while its row exists.

The Markdown layout below is the legacy store: under the store root it is a
read-only backup that `ztd migrate import` copies into the database, not the
task store itself. The method still adds those files as you adopt each habit
(paths relative to the store root):

| File | Contents |
| --- | --- |
| `adoption.md` | Habit in practice, phase and progress criteria |
| `calendar.md` | Appointments and firm dates, referenced by ID |
| `goals/active.md` | The active goal and its sub-goal |
| `goals/archive.md` | Previous goals |
| `journal/YYYY-MM-DD.md` | Results and learning of the day |
| `knowledge/` | Knowledge indexes and cards per scope |
| `passion.md` | Interests and experiments (optional) |
| `reviews/` | Reviews and coverage records |
| `routines/daily.md`, `routines/weekly.md` | Routine patterns (legacy; in the Go store, due state lives in the database — `ztd routines due` — and only a migrated store carries rows) |

Format notes (format 2): `contexts.md` is a Markdown table with `Context` and
`Use` columns (plus optional `Clients` and `Knowledge` columns);
`routines/state.md` is a table `routine | cadence | last`, where cadence is
`daily` or `weekly:` plus a day token (`mon`…`sun`, Monday-first).
`waiting_on` is free text; a trailing `@YYYY-MM-DD` records the follow-up date
the weekly review checks, and the CLI does not parse it.

Tasks are mutated only through the `ztd` CLI; IDs are the canonical reference
and plans, reviews and cards reference them without duplicating state. Every
path in this method is relative to the store root (the read-only Markdown
backup).

A repository's `.ztd.json` binding declares exactly its `context`, `client` and
`project`; it is not the store and holds no tasks, clone paths, or repository
URLs. The CLI discovers the nearest binding from the current directory up to
the current Git repository boundary. `ztd status --json` reports it as
`binding` (the raw object or `null`, with `warning` for a missing or malformed
file), and `ztd check --bindings` validates it against the resolved store. A
binding is a
routing hint, not authorization: explicit user scope remains authoritative.
Each clone's local path lives in its project card, outside the binding and
store.

The OpenCode adapter —skills, commands and agent— lives in
[`../integrations/opencode/`](../integrations/opencode/README.md). It is
optional: the method works the same with a notebook, an editor or any tool.
