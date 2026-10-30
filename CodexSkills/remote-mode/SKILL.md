---
name: remote-mode
description: Control Remote from the user's short handoff phrases. Always trigger when the complete user message is "Я ушёл" to enable Remote or "Я здесь" to disable Remote, ignoring capitalization and terminal punctuation. Also trigger for explicit longer commands about leaving or returning to the office or enabling or disabling Remote. Do not infer a mode change from those words inside unrelated longer messages.
---

Map the user's explicit intent to exactly one action:

- Exact short message `Я ушёл`, leaving the office, or enabling Remote: run `/Users/lammax/.local/bin/remote-control start` exactly once.
- Exact short message `Я здесь`, returning to the office, or disabling Remote: run `/Users/lammax/.local/bin/remote-control stop` exactly once.

Never run both actions in one invocation. If the direction is ambiguous, ask one concise clarifying question and do not run either command.

Report the resulting mode concisely. When starting, provide both `http://100.123.251.91:3010/approvals` for approval requests and `http://100.123.251.91:3010/claude` for submitting full Claude Code tasks. State that the login token was copied to the Mac clipboard, but never read, print, quote, summarize, or expose the token itself. Do not change Tailscale, ZeroTier, DNS, routes, the LaunchAgent, the database, or MCP registration.
