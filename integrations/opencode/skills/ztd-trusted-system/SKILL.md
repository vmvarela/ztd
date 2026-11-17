---
name: Trusted system with ZTD
description: Repair duplicates, broken references and missing next actions in the ZTD lists.
---

# Trusted system

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Query the lists and projects of
the affected scope; read `README.md` for recovery or structural changes.
Run `ztd check` before repairing: it detects duplicates, invalid states and
orphan references without modifying data. Use `show ID` to locate them.

1. A pending transaction cannot be recovered from queries: when executing use
   `ztd recover` and repeat the check. In Plan mode only report.
   If you find duplicates or a transaction with external edits, stop
   automatic mutations and keep the files/journal. Compare the content and ask
   for a decision before reconciling; do not confuse plan references with
   duplicates. Never resolve a discrepancy by deleting an entry to make the
   error disappear.
2. Check plan/project references and the destination of closed IDs.
3. Verify that every active project has an executable action or an explained
   waiting.
4. Review waitings with overdue follow-up and possibilities without current
   commitment.
5. Fix unambiguous inconsistencies; ask about contradictory states.
6. Summarize repairs and pending decisions. Keep the lists simple, without a
   parallel master list or new tools for the same state.
