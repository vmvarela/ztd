---
name: Capture with ZTD
description: Quickly store ideas, tasks or commitments in the store inbox without filtering them.
---

# Capture

Paths relative to the store root; the task store is the SQLite database, resolved as `--db` > `ZTD_DB` > `~/.ztd/ztd.db` — never derive it from the current directory. The Markdown files under `~/.ztd` are a read-only legacy backup, not the task store. Do not read the inbox, lists,
knowledge or adoption for a normal capture: `ztd` reserves the ID and verifies
the write.

1. If there is no text or attached content to capture, ask what to note down.
   A note kept on paper or on a phone is a valid capture; transcribe it in the
   next session and process it then, without keeping a parallel list.
2. Run `ztd capture` with the database (`--db`/`ZTD_DB`) and the text
   as a quoted argument (never write the list by hand). The binary takes the
   local date, reserves IDs under lock and verifies the write before replying.
3. Keep the details given; do not require context, client, priority or project
   at this stage. For several independent ideas, pass each one as an argument to
   `ztd`; `--stdin` reads one per line.
4. Confirm each ID and the returned path briefly. Classify and simplify later.

Do not execute the task or turn it into a commitment just because it was
captured. If `ztd` rejects the text or cannot verify it, report the error
without claiming the capture was saved; keep the text in the conversation to
retry.
