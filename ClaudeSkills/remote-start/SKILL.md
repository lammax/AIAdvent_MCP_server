---
name: remote-start
description: Start the local Remote HTTP companion for iPhone approvals and full Claude Code tasks, and copy its login token to the Mac clipboard.
disable-model-invocation: true
allowed-tools: Bash(/Users/lammax/.local/bin/remote-control start)
---

Run `/Users/lammax/.local/bin/remote-control start` exactly once.

Report whether Remote is healthy. Show `http://100.123.251.91:3010/approvals` for approval requests and `http://100.123.251.91:3010/claude` for submitting full Claude Code tasks. State that the token is in the Mac clipboard. Never read, print, quote, summarize, or expose the token itself.
