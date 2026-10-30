---
name: remote-status
description: Check whether the local Remote service, approval UI, and Claude task UI are healthy.
disable-model-invocation: true
allowed-tools: Bash(/Users/lammax/.local/bin/remote-control status)
---

Run `/Users/lammax/.local/bin/remote-control status` exactly once and report its result concisely. When healthy, include `http://100.123.251.91:3010/approvals` and `http://100.123.251.91:3010/claude`. Do not change service or network settings.
