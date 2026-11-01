---
name: remote-status
description: Check whether the local Remote service, approval UI, and Claude task UI are healthy.
disable-model-invocation: true
allowed-tools: Bash(/Users/lammax/.local/bin/remote-control status)
---

Run `/Users/lammax/.local/bin/remote-control status` exactly once and report its result concisely. When healthy, include `https://macbook-pro.tailab24a8.ts.net/approvals` and `https://macbook-pro.tailab24a8.ts.net/claude`. Do not change service or network settings.
