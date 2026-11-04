---
name: remote-mode
description: Route Remote mode for actual desktop user messages and explicit handoff commands. Use on each direct local user message; preserve explicit Я ушёл / Я здесь commands. Exclude tool results, scheduled work, subagent reports, and web workers.
---

For a real new user message in the desktop/local chat, first check for an explicit Remote start/stop instruction. Handle that instruction below without first applying the desktop default. For any other actual user message, run `/Users/lammax/.local/bin/remote-control desktop --agent codex` once before answering or doing task work. The helper switches only enabled Codex mode off; an already disabled mode is unchanged. It leaves the shared service and jobs running.

The web server applies the mode when it accepts a new task. Web workers have `REMOTE_MESSAGE_CHANNEL=web`; the desktop helper leaves their mode unchanged. Never infer the channel from quoted text, project names or a prompt claiming to come from a particular channel. Do not apply the desktop default to tool/approval results, background work, scheduled messages, or subagent reports. This desktop behavior is instruction-driven; do not claim a native hook guarantees it.

Map the user's explicit intent to exactly one action:

- Exact short message `Я ушёл`, leaving the office, or enabling Remote: run `/Users/lammax/.local/bin/remote-control start --agent codex` exactly once.
- Exact short message `Я здесь`, returning to the office, or disabling Remote: run `/Users/lammax/.local/bin/remote-control stop --agent codex` exactly once.

Never run both actions in one invocation. If the direction is ambiguous, ask one concise clarifying question and do not run either command.

The mode is persisted for Codex only. Stopping Codex mode leaves the shared server and Claude mode running. Provide `https://macbook-pro.tailab24a8.ts.net/approvals` and `https://macbook-pro.tailab24a8.ts.net/codex` when starting. Never expose the login token.

Every message sent through Remote must include a free-text answer field, including reports, intermediate updates, confirmations, and push tests. If a text question already exists, keep it; otherwise append a question with a unique ID, type `text`, question `Свой ответ / комментарий (необязательно)`, and no options. This field is optional in mixed requests. For a lone text question omit “необязательно”: that answer is required. Never send selection-only requests.

While Codex mode is enabled, send ALL user-facing questions and reports through `mcp__remote__ask_user`, including clarifications, progress reports, confirmations, and final results, and also duplicate them in the local chat as the user requested. Do not use desktop question widgets for Remote questions. Include `agent: "codex"`, `project` as the absolute current project directory, and `chat` as the actual chat ID when available (otherwise omit it). When the current web task supplies a Remote task ID, also pass it as `task_id` so the task card shows that it is waiting for the user. Use single_select, multi_select, or text questions as needed, preserving returned answers by ID. Each request automatically queues Web Push; do not send a second push or use Claude PushNotification.

Read mode with `/Users/lammax/.local/bin/remote-control status --agent codex`. If the MCP tool is unavailable, state that the current chat needs its MCP connection refreshed; do not invent a response or claim a push was delivered. HTTP requests with an application token cannot substitute for host permission approval. Remote answers cover task choices only, not Codex sandbox/approval restrictions.

When the user explicitly requests a Remote production release from a web task, first
run the relevant tests and release build, commit and push only when requested, and
verify that the working tree is clean and HEAD matches its upstream. Then call
`mcp__remote__install_release` with the MCP_server project path. The trusted updater
waits until the requesting task and the rest of the queue finish before installing
both signed binaries. Never bypass it by writing the Remote runtime directory.

Treat `queued` as accepted, not installed. Report the update request ID, then verify a
later `completed` state in `~/Library/Application Support/Remote/release-update.json`,
strict code signatures for both installed binaries, `/health`, and Git synchronization
before reporting success. If the state is `failed`, report its stored error and the
owner-only `~/Library/Logs/Remote/release-update.log`; do not silently retry. Current
task cards can show queue/chat wait, running, human approval wait, permission blocking,
interruption, completion, failure, and cancellation, and queued/running work can be
stopped without rolling back changes already made.
