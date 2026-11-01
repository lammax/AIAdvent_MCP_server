---
name: remote-push
description: Send a requested Remote test notification to the iPhone from Codex and wait for acknowledgement.
---

Check `/Users/lammax/.local/bin/remote-control status` and `/Users/lammax/.local/bin/remote-control status --agent codex`. If disabled or unhealthy, report that state.

Use the available `mcp__remote__ask_user` exactly once with top-level agent `codex`, project as the current absolute workspace directory, and the actual chat ID if available. Include two questions in the same request: a single_select question with ID `push`, the requested message (or `Remote Codex: подтвердите получение уведомления.`), and options `Получено` and `Отклонить`; then a text question with ID `comment`, question `Свой ответ / комментарий (необязательно)`, and no options. The text field is optional because this is a mixed request.

Creating the request automatically queues Web Push. Do not use Claude PushNotification or create an extra request for a report already sent through ask_user. Report returned answers exactly; timeouts are failures, never inferred approval. If the MCP tool is unavailable in the current chat, explain that the MCP connection must be refreshed. Do not expose the login token.
