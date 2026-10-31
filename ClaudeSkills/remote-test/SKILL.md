---
name: remote-test
description: Verify the local Remote service and all iPhone response modes end to end.
disable-model-invocation: true
allowed-tools:
  - Bash(/Users/lammax/.local/bin/remote-control test)
  - mcp__remote__ask_user
---

Run `/Users/lammax/.local/bin/remote-control test` exactly once. If it fails, report the failure and stop.

Then call `mcp__remote__ask_user` exactly once with a `questions` array containing all three entries:

1. ID `single`, type `single_select`, question `Remote single-select test: выбери «Работает».`, options `Работает` and `Отмена`.
2. ID `multiple`, type `multi_select`, question `Remote multi-select test: выбери оба рабочих режима.`, options `Выбор`, `Текст`, and `Отмена`.
3. ID `comment`, type `text`, question `Remote text test: введи короткий ответ.`, with no options. This field is optional because it is part of a multi-question request, but enter a value during this test to verify text transport.

Report every returned answer by ID, preserving the complete array and order for multi-select. Never invent, normalize, or summarize the user's answers.
