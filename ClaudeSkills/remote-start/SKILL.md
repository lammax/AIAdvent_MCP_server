---
name: remote-start
description: Start the local Remote HTTP companion for iPhone approvals and full Claude Code tasks, and copy its login token to the Mac clipboard.
disable-model-invocation: true
allowed-tools: Bash(/Users/lammax/.local/bin/remote-control start --agent claude)
---

Run `/Users/lammax/.local/bin/remote-control start --agent claude` exactly once.

Report whether Remote is healthy. Show `https://macbook-pro.tailab24a8.ts.net/approvals` for approval requests and `https://macbook-pro.tailab24a8.ts.net/claude` for submitting full Claude Code tasks. State that the token is in the Mac clipboard and that notifications are enabled from the installed Home Screen PWA. Never read, print, quote, summarize, or expose the token itself.
