---
name: Capture with ZTD
description: Quickly store ideas, tasks or commitments in the store inbox without filtering them.
---

# Capture

Paths relative to the store root; the root resolves as `--root` > `ZTD_ROOT` > `~/.ztd` — never derive it from the current directory. Do not read the inbox, lists,
knowledge or adoption for a normal capture: `ztd` reserves the ID and verifies
the write.

1. If there is no text or attached content to capture, ask what to note down.
2. Run `ztd capture` with the declared root (`--root`/`ZTD_ROOT`) and the text
   as a quoted argument (never write the list by hand). The binary takes the
   local date, reserves IDs under lock and verifies the file before replying.
3. Keep the details given; do not require context, client, priority or project
   at this stage. For several independent ideas, pass each one as an argument to
   `ztd`; `--stdin` reads one per line.
4. Confirm each ID and the returned path briefly. Classify and simplify later.

Do not execute the task or turn it into a commitment just because it was
captured. If `ztd` rejects the text or cannot verify it, report the error
without claiming the capture was saved; keep the text in the conversation to
retry.
