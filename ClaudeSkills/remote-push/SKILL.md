---
name: remote-push
description: Send one explicit end-to-end Remote Web Push request to the iPhone and wait for the user's acknowledgement through the authoritative approval flow.
allowed-tools:
  - Bash(/Users/lammax/.local/bin/remote-control test)
  - mcp__remote__ask_user
---

Use this skill when the user requests a Remote push or a test notification on the iPhone. It may be invoked by Claude through the Skill tool.

Remote is the user's custom Swift service. Never substitute Claude's built-in `PushNotification` or Claude Remote Control for this workflow. Terminal activity does not suppress this service's Web Push.

For an ordinary Remote report or question already sent through `mcp__remote__ask_user`, its push is queued automatically. Do not create a second approval solely to accompany that report with a notification.

Run `/Users/lammax/.local/bin/remote-control test` exactly once. If Remote is not healthy or its MCP registration is unavailable, report the failure and do not create a request.

Call `mcp__remote__ask_user` exactly once with one `single_select` question:

Include top-level `agent: "claude"`, `project` as the absolute current project directory, and the actual `chat` ID when available.

- ID: `push`
- Question: use `$ARGUMENTS` verbatim when it is non-empty; otherwise use `Remote push test: подтверди получение уведомления.`
- Options, in order: `Получено`, `Отклонить`

This must remain a real approval-backed notification: creating the approval queues Web Push through Remote's transactional outbox, and the iPhone response returns through the Approval Store. Do not call the HTTP test-push endpoint, fabricate delivery, or create a direct Web Push-to-MCP response path.

Report the returned response exactly. A response proves the end-to-end Remote request completed, but do not claim that the notification itself was displayed if the user may have opened the PWA manually. If the request times out or fails, report that outcome without retrying or sending another push.

Never include the Remote token in the request, output, URL, logs, or arguments. The push payload itself remains generic; the question is fetched only after authentication in the PWA.
