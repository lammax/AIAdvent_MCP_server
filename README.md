# MCPServer

Local Swift MCP servers used by WorkHarness and related agent tooling. Each server is an independent executable target. `RemoteMCPServer` supports an HTTP interface for the iPhone and a local stdio MCP transport for Claude Code.

## RemoteMCPServer

`RemoteMCPServer` lets an MCP client pause on `ask_user`, display the decision in a mobile browser, and return the exact option selected by the user. Its `/claude` page also queues full Claude Code tasks on the Mac and returns their responses to the browser.

### Installed setup

The production service is installed in:

```text
~/Library/Application Support/Remote/
├── approval.sqlite
├── token
└── bin/RemoteMCPServer
```

It is started at macOS login by `~/Library/LaunchAgents/com.lammax.remote.plist`, listens only on the Mac's exact Tailscale address `100.123.251.91:3010`, and logs to `~/Library/Logs/Remote/`.

The token is stored with user-only permissions and is never printed. `/remote-start` copies it to the Mac clipboard so it can be pasted into Safari on the iPhone through Universal Clipboard.

The personal Claude Code commands are:

- `/remote-start` — start the service if needed and copy the login token.
- `/remote-status` — show service health.
- `/remote-stop` — stop it until the next login or manual start.
- `/remote-test` — verify single-select, multi-select, and free-text responses on the iPhone.

The model-invoked `remote-mode` skill accepts two short handoffs: `Я ушёл` starts Remote and `Я здесь` stops it. It also understands explicit longer office/Remote commands. It only acts when the user sends such a message; it does not perform location tracking.

### Build and test

```bash
swift build -c release --product RemoteMCPServer
swift test --filter RemoteTests
```

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `REMOTE_HOST` | `127.0.0.1` | Loopback or exact Tailscale address. Wildcard and ordinary LAN addresses are rejected. |
| `REMOTE_PORT` | `3010` | HTTP port. |
| `REMOTE_TOKEN` | none | Inline access token of at least 32 characters. |
| `REMOTE_TOKEN_FILE` | none | Preferred path to a file containing the access token. |
| `REMOTE_DB_PATH` | `~/Library/Application Support/Remote/approval.sqlite` | SQLite database path. |
| `REMOTE_TIMEOUT_SECONDS` | `300` | Maximum wait for a decision, from 1 to 3,600 seconds. |
| `REMOTE_CLAUDE_PATH` | `~/.local/bin/claude` | Claude Code executable used by the remote task worker. |
| `REMOTE_CLAUDE_WORKING_DIRECTORY` | `~/Documents/ThisIsMy/Programming/AI` | Working directory for remotely submitted Claude tasks. |

For a development run, generate a token without committing or printing it:

```bash
token_file="$(mktemp)"
openssl rand -hex -out "$token_file" 32
chmod 600 "$token_file"
REMOTE_TOKEN_FILE="$token_file" swift run RemoteMCPServer
```

Do not place the token in this repository, command history, URLs, logs, or screenshots.

### Claude Code registration

Keep the HTTP process running for the iPhone UI, but connect Claude Code through the executable's local stdio mode. Both processes use the same SQLite database. Stdio mode does not start another HTTP listener and does not need the browser token.

```bash
claude mcp add \
  --scope user \
  remote \
  -- \
  "$HOME/Library/Application Support/Remote/bin/RemoteMCPServer" \
  --stdio
```

The primary tool contract groups heterogeneous questions into one request:

```text
ask_user(
  questions: [{
    id: string,
    question: string,
    type: "single_select" | "multi_select" | "text",
    options?: string[2...12]
  }]
)
```

All questions are displayed in one iPhone form and submitted atomically. Selection types require options; text questions omit them. A text answer is required when it is the only question and is an optional comment when it appears in a multi-question request. Answers are returned in the original question order and matched by `id`; an omitted optional text answer has an empty `responses` array. The original `ask_user(question, options)` form and its optional `mode` remain supported for compatibility. Timeout, cancellation, validation, and persistence failures are explicit errors; the server never invents an answer.

The source files for the personal Claude Code commands live in `ClaudeSkills/`. Install them under `~/.claude/skills/` and restart an existing Claude Code session when the MCP schema changes. The Codex-specific `remote-mode` source lives in `CodexSkills/`; install it under `~/.codex/skills/`. Register the same stdio server in Codex with:

```bash
codex mcp add remote -- \
  "$HOME/Library/Application Support/Remote/bin/RemoteMCPServer" \
  --stdio
```

### iPhone over Tailscale

Open this page on the iPhone while Tailscale is connected:

```text
http://100.123.251.91:3010/approvals
http://100.123.251.91:3010/claude
```

The Claude page stores requests in SQLite and runs them one at a time. Jobs survive a web-service restart, and the page polls their queued, running, completed, or failed state without disturbing the request field. Claude is intentionally started with `bypassPermissions`, so a request submitted through this page has the same broad ability to read and change files, run commands, access the network, and call configured MCP tools as a fully trusted local Claude Code task. Keep the page private to the authenticated Tailscale connection.

Run `/remote-start` in Claude Code for the initial login, then paste the token from Universal Clipboard. The login form uses the fixed username `remote`, so Chrome or Safari can save the token as a password and autofill it later. The browser receives a 90-day HttpOnly authentication cookie derived with HMAC from the token. It remains valid across `/remote-stop`, `/remote-start`, server upgrades, and Mac restarts; rotating the token invalidates it immediately. Saving the credential in the browser's synced password manager is the fallback if browser data is cleared while away from the Mac.

Do not use `0.0.0.0`, public port forwarding, an exit node, or DNS/routing changes. Tailscale and ZeroTier settings do not need to be modified.
