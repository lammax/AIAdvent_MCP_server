---
name: remote-mode
description: Control Remote from the user's short handoff phrases. Always trigger when the complete user message is "Я ушёл" to enable Remote or "Я здесь" to disable Remote, ignoring capitalization and terminal punctuation. Also trigger for explicit longer commands about leaving or returning to the office or enabling or disabling Remote. Do not infer a mode change from those words inside unrelated longer messages.
---

Map the user's explicit intent to exactly one action:

- Exact short message `Я ушёл`, leaving the office, or enabling Remote: run `/Users/lammax/.local/bin/remote-control start --agent codex` exactly once.
- Exact short message `Я здесь`, returning to the office, or disabling Remote: run `/Users/lammax/.local/bin/remote-control stop --agent codex` exactly once.

Never run both actions in one invocation. If the direction is ambiguous, ask one concise clarifying question and do not run either command.

The mode is persisted for Codex only. Stopping Codex mode leaves the shared server and Claude mode running. Provide `https://macbook-pro.tailab24a8.ts.net/approvals` and `https://macbook-pro.tailab24a8.ts.net/codex` when starting. Never expose the login token.

Every message sent through Remote must include a free-text answer field, including reports, intermediate updates, confirmations, and push tests. If a text question already exists, keep it; otherwise append a question with a unique ID, type `text`, question `Свой ответ / комментарий (необязательно)`, and no options. This field is optional in mixed requests. For a lone text question omit “необязательно”: that answer is required. Never send selection-only requests.

While Codex mode is enabled, send ALL user-facing questions and reports through `mcp__remote__ask_user`, including clarifications, progress reports, confirmations, and final results. Do not use desktop question widgets or repeat substantive reports in the chat. Keep any host-required chat notices minimal. Include `agent: "codex"`, `project` as the absolute current project directory, and `chat` as the actual chat ID when available (otherwise omit it). Use single_select, multi_select, or text questions as needed, preserving returned answers by ID. Each request automatically queues Web Push; do not send a second push or use Claude PushNotification.

Read mode with `/Users/lammax/.local/bin/remote-control status --agent codex`. If the MCP tool is unavailable, state that the current chat needs its MCP connection refreshed; do not invent a response or claim a push was delivered. HTTP requests with an application token cannot substitute for host permission approval. Remote answers cover task choices only, not Codex sandbox/approval restrictions.
