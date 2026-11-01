---
name: remote-stop
description: Disable Claude Remote mode without stopping the shared HTTP service or Codex mode.
disable-model-invocation: true
allowed-tools: Bash(/Users/lammax/.local/bin/remote-control stop --agent claude)
---

Run `/Users/lammax/.local/bin/remote-control stop --agent claude` exactly once and report the result. The shared service and Codex mode remain available.
