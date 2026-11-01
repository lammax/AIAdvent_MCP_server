---
name: remote-mode
description: Control Remote from the user's short handoff phrases. Always trigger when the complete user message is "Я ушёл" to enable Remote or "Я здесь" to disable Remote, ignoring capitalization and terminal punctuation. Also trigger for explicit longer commands about leaving or returning to the office or enabling or disabling Remote. Do not infer a mode change from those words inside unrelated longer messages.
allowed-tools:
  - Bash(/Users/lammax/.local/bin/remote-control start --agent claude)
  - Bash(/Users/lammax/.local/bin/remote-control stop --agent claude)
---

Map the user's explicit intent to exactly one action:

- Exact short message `Я ушёл`, leaving the office, or enabling Remote: run `/Users/lammax/.local/bin/remote-control start --agent claude` exactly once.
- Exact short message `Я здесь`, returning to the office, or disabling Remote: run `/Users/lammax/.local/bin/remote-control stop --agent claude` exactly once.

Never run both actions in one invocation. If the direction is ambiguous, ask a concise clarifying question and do not run either command.

Report the resulting Claude mode concisely. It is independent of Codex; stopping it leaves the shared HTTP server running. When starting provide `https://macbook-pro.tailab24a8.ts.net/approvals` and `https://macbook-pro.tailab24a8.ts.net/claude`. Never expose the token.

When routing questions or reports through `mcp__remote__ask_user`, include `agent: "claude"`, `project` as the absolute current project directory, and the actual `chat` ID when available. Each request automatically queues Web Push. Never substitute the built-in PushNotification tool.
