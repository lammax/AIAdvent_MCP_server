# MCPServer

Local Swift MCP servers used by WorkHarness and related agent tooling. Each server is an independent executable target. Remote uses `RemoteMCPServer` for local stdio MCP and the separate `RemoteHTTPServer` for its private iPhone web interface.

## Remote

`RemoteMCPServer` lets an MCP client pause on `ask_user`, display the decision in a mobile browser, and return the exact option selected by the user. `RemoteHTTPServer` owns HTTP, the PWA, Web Push, and the `/claude` page that queues full Claude Code tasks on the Mac. Both processes share the same SQLite database.

### Installed setup

The production service is installed in:

```text
~/Library/Application Support/Remote/
├── approval.sqlite
├── vapid.json
├── token
└── bin/
    ├── RemoteHTTPServer
    └── RemoteMCPServer
```

`RemoteHTTPServer` is started at macOS login by `~/Library/LaunchAgents/com.lammax.remote.plist`, listens only on `127.0.0.1:3010`, and logs to `~/Library/Logs/Remote/`. Tailscale Serve exposes it to the tailnet at `https://macbook-pro.tailab24a8.ts.net`; Funnel is not enabled. `RemoteMCPServer` is launched separately over stdio by Claude Code or Codex.

The token is stored with user-only permissions and is never printed. `/remote-start` copies it to the Mac clipboard so it can be pasted into Safari on the iPhone through Universal Clipboard.

The personal Claude Code commands are:

- `/remote-start` — start the service if needed and copy the login token.
- `/remote-status` — show service health.
- `/remote-stop` — stop it until the next login or manual start.
- `/remote-test` — verify single-select, multi-select, and free-text responses on the iPhone.

The model-invoked `remote-mode` skill accepts two short handoffs: `Я ушёл` starts Remote and `Я здесь` stops it. It also understands explicit longer office/Remote commands. It only acts when the user sends such a message; it does not perform location tracking.

### Build and test

```bash
swift build -c release --product RemoteHTTPServer
swift build -c release --product RemoteMCPServer
swift test --filter RemoteTests
```

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `REMOTE_HOST` | `127.0.0.1` | Loopback or exact Tailscale address. Production uses loopback behind Serve. Wildcard and ordinary LAN addresses are rejected. |
| `REMOTE_PORT` | `3010` | HTTP port. |
| `REMOTE_PUBLIC_ORIGIN` | derived from host and port | External origin used for Secure cookies and Origin validation. |
| `REMOTE_TOKEN` | none | Inline access token of at least 32 characters. |
| `REMOTE_TOKEN_FILE` | none | Preferred path to a file containing the access token. |
| `REMOTE_VAPID_FILE` | `~/Library/Application Support/Remote/vapid.json` | Stable VAPID configuration with mode `600`. Never regenerate it during startup or upgrades. |
| `REMOTE_DB_PATH` | `~/Library/Application Support/Remote/approval.sqlite` | SQLite database path. |
| `REMOTE_TIMEOUT_SECONDS` | `300` | Maximum wait for a decision, from 1 to 3,600 seconds. |
| `REMOTE_CLAUDE_PATH` | `~/.local/bin/claude` | Claude Code executable used by the remote task worker. |
| `REMOTE_CLAUDE_WORKING_DIRECTORY` | `~/Documents/ThisIsMy/Programming/AI` | Working directory for remotely submitted Claude tasks. |

For a development run, generate a token without committing or printing it:

```bash
token_file="$(mktemp)"
openssl rand -hex -out "$token_file" 32
chmod 600 "$token_file"
REMOTE_TOKEN_FILE="$token_file" swift run RemoteHTTPServer
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

The source files for the personal Claude Code commands live in `ClaudeSkills/`. Install them under `~/.claude/skills/` and restart an existing Claude Code session when the MCP schema changes. Codex-specific skill sources live in `CodexSkills/`; install them under `~/.codex/skills/`. `remote-mode` controls the Remote service, while `commit-push` makes an explicitly requested commit finish with a normal upstream push and synchronization check. Register the same stdio server in Codex with:

```bash
codex mcp add remote -- \
  "$HOME/Library/Application Support/Remote/bin/RemoteMCPServer" \
  --stdio
```

### iPhone over Tailscale

Open these HTTPS pages on the iPhone while Tailscale is connected:

```text
https://macbook-pro.tailab24a8.ts.net/approvals
https://macbook-pro.tailab24a8.ts.net/claude
```

For Web Push on iPhone, add the approvals page to the Home Screen, launch that installed PWA, and press **Enable notifications**. The service worker does not cache authenticated pages or approval data. Notifications contain only a generic message and an approval ID deep link; the question and options are fetched after authentication.

The Claude page stores requests in SQLite and runs them one at a time. Jobs survive a web-service restart, and the page polls their queued, running, completed, or failed state without disturbing the request field. Claude is intentionally started with `bypassPermissions`, so a request submitted through this page has the same broad ability to read and change files, run commands, access the network, and call configured MCP tools as a fully trusted local Claude Code task. Keep the page private to the authenticated Tailscale connection.

Run `/remote-start` in Claude Code for the initial login, then paste the token from Universal Clipboard. The login form uses the fixed username `remote`, so Chrome or Safari can save the token as a password and autofill it later. The browser receives a 90-day Secure, HttpOnly, SameSite=Strict authentication cookie derived with HMAC from the token. State-changing cookie requests also require a CSRF token and matching HTTPS origin. The cookie remains valid across `/remote-stop`, `/remote-start`, server upgrades, and Mac restarts; rotating the token invalidates it immediately. Saving the credential in the browser's synced password manager is the fallback if browser data is cleared while away from the Mac.

Push subscriptions and the transactional outbox are persisted in the same SQLite database, so they survive service and Mac restarts. Delivery retries use leases and stable notification tags; an invalid provider subscription is deactivated without affecting the approval itself. Keep `vapid.json` stable—rotating it requires enabling notifications again on each device.

Do not use `0.0.0.0`, public port forwarding, or Tailscale Funnel. The Mac intentionally does not consume Tailscale DNS settings because of its existing network coexistence setup; `remote-control` therefore checks local health over loopback. Do not change Tailscale DNS, ZeroTier, corporate routes, or exit-node settings as part of Remote troubleshooting.

The staged plan for decoupling Remote from Tailscale, evaluating alternate ingress transports, and retaining a carrier-restriction fallback is in [`docs/REMOTE_TRANSPORT_MIGRATION.md`](docs/REMOTE_TRANSPORT_MIGRATION.md).
