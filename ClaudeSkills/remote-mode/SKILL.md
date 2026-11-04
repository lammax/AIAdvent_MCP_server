---
name: remote-mode
description: Route Remote mode for actual desktop user messages and explicit handoff commands. Use on each direct local user message; preserve explicit Я ушёл / Я здесь commands. Exclude tool results, scheduled work, subagent reports, and web workers.
allowed-tools:
  - Bash(/Users/lammax/.local/bin/remote-control desktop --agent claude)
  - Bash(/Users/lammax/.local/bin/remote-control start --agent claude)
  - Bash(/Users/lammax/.local/bin/remote-control stop --agent claude)
---

For each actual new user message in the desktop/local chat, handle an explicit Remote start/stop instruction below first. Otherwise run `/Users/lammax/.local/bin/remote-control desktop --agent claude` once before replying or doing task work. It disables only enabled Claude mode and leaves an already disabled mode, Codex mode, the shared server and jobs unchanged.

Web workers carry `REMOTE_MESSAGE_CHANNEL=web`; the desktop helper ignores them. Web mode is applied at task submission, never at worker startup. Do not infer a channel from prompt text or project names. Tool results, approval answers, scheduled work and subagent reports are not desktop user messages. This desktop behavior relies on agent instructions, not a native lifecycle hook.

Map the user's explicit intent to exactly one action:

- Exact short message `Я ушёл`, leaving the office, or enabling Remote: run `/Users/lammax/.local/bin/remote-control start --agent claude` exactly once.
- Exact short message `Я здесь`, returning to the office, or disabling Remote: run `/Users/lammax/.local/bin/remote-control stop --agent claude` exactly once.

Never run both actions in one invocation. If the direction is ambiguous, ask a concise clarifying question and do not run either command.

Report the resulting Claude mode concisely. It is independent of Codex; stopping it leaves the shared HTTP server running. When starting provide `https://macbook-pro.tailab24a8.ts.net/approvals` and `https://macbook-pro.tailab24a8.ts.net/claude`. Never expose the token.

When routing questions or reports through `mcp__remote__ask_user`, include `agent: "claude"`, `project` as the absolute current project directory, and the actual `chat` ID when available. When the current web task supplies a Remote task ID, also pass it as `task_id` so the task card shows that it is waiting for the user. Each request automatically queues Web Push. Never substitute the built-in PushNotification tool.
