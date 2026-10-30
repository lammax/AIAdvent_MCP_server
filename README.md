# MCPServer

Local Swift MCP servers used by WorkHarness and related agent tooling. Each server is an independent executable target. `RemoteMCPServer` supports an HTTP interface for the iPhone and a local stdio MCP transport for Claude Code.

## RemoteMCPServer

`RemoteMCPServer` lets an MCP client pause on `ask_user`, display the decision in Safari, and return the exact option selected by the user.

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
- `/remote-test` — verify the service and request a real decision from the iPhone.

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

The tool contract is:

```text
ask_user(question: string, options: string[2...12])
```

On success it returns the request ID, `answered` status, and exact selected option. Timeout, cancellation, validation, and persistence failures are explicit errors; the server never invents a choice.

### iPhone over Tailscale

Open this page on the iPhone while Tailscale is connected:

```text
http://100.123.251.91:3010/approvals
```

Run `/remote-start` in Claude Code first, then paste the token from Universal Clipboard. A login remains valid until the server process restarts because browser sessions are intentionally held in memory.

Do not use `0.0.0.0`, public port forwarding, an exit node, or DNS/routing changes. Tailscale and ZeroTier settings do not need to be modified.
