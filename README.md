# MCPServer

Local Swift MCP servers used by WorkHarness and related agent tooling. Each server is an independent executable target. Remote uses `RemoteMCPServer` for local stdio MCP and the separate `RemoteHTTPServer` for its private iPhone web interface.

## Remote

### Codex and per-agent mode

Use `remote-control start --agent codex` or `start --agent claude` to enable that agent.
Use `stop --agent codex|claude` to disable only that agent; the shared HTTP service remains running.
The unqualified `stop` is the explicit whole-service administration command.
Modes persist in SQLite. An absent Codex mode is disabled; legacy Claude requests remain compatible.

MCP `ask_user` accepts optional `agent`, absolute `project`, and `chat` context.
Answers remain bound to the request UUID, not the selected UI filter. Approvals can be filtered by agent and project.
The `remote_mode` MCP tool reads/sets one agent's mode. Modes guide message routing; they do not grant filesystem or sandbox permissions.

The authenticated `/codex` page starts separate Codex CLI tasks in a selected existing project.
The allowed project list is `~/Library/Application Support/Remote/projects.json` (objects with `name` and absolute `path`).
Only those canonical directories are execution roots. `REMOTE_CODEX_PATH` can override the installed Codex CLI path.
Tasks use a Remote-only permission profile derived from `:workspace`, with explicit
write access to the selected project's `.git`. `.codex`, `.agents`, and `.aws` remain
read-only. Command network access uses Codex's network proxy and allows only the
HTTPS hosts of the project's `origin` fetch/push URLs. Other destinations and direct
connections are blocked. No HTTPS origin means command network access is disabled.
SSH Git remotes are not configured by this profile; use an HTTPS origin for unattended push.
The profile is passed per process; global Codex configuration and host network routes
are unchanged. Codex must support named permission profiles and the network proxy.
Tasks never bypass host permissions and use the CLI's configured model and authentication.
Requested commits are followed by a normal push and upstream synchronization check;
destructive Git operations require a separate explicit instruction. This last rule
is agent guidance, not an OS-level ban: `.git` write access permits Git state changes.
Results are persisted and displayed on `/codex`; these are new tasks, not continuations of a selected desktop chat.
Interrupted Codex jobs are marked failed rather than replayed after restart.

The **Usage** button on each agent page requests account limits and saves the answer
in that page's task history, without navigating away or queuing a model task.
Authenticated, CSRF-protected `POST /codex/usage` and `POST /claude/usage` use the
installed CLIs' existing account authentication: Codex's local app-server
`account/rateLimits/read`, and Claude's built-in `/usage` in print mode with tools,
MCP servers, and settings hooks disabled for the query. Provider tokens are not
read or copied by Remote. Replies show usage windows, remaining percentages, reset
times and the collection timestamp; unknown values remain unavailable rather than
being shown as zero. Concurrent reads are coalesced, snapshots are cached for 30
seconds, and each query process has a 25-second deadline. Claude's unrelated local
session/skill analytics are omitted from the stored report.
Each cached snapshot has a stable report ID: repeated or concurrent clicks return
the same stored answer instead of adding duplicate cards. The page shows only the
newest Usage snapshot per agent, retaining earlier snapshots in the database.

Install `CodexSkills/remote-mode` and `CodexSkills/remote-push` under `~/.codex/skills/`.
The MCP configuration should allow a tool timeout exceeding Remote's 300-second wait (for example `tool_timeout_sec = 360`).
For unattended question delivery, configure only `mcp_servers.remote.tools.ask_user.approval_mode = "approve"`.
This preauthorizes the question relay, not filesystem or shell actions. The web worker requires Remote MCP startup to succeed.
Remote's stdio adapter ignores unsupported non-string experimental capability entries that the current Swift MCP SDK cannot decode.
Refresh the app's MCP connection or restart the app after replacing the stdio binary/schema.

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
- `/remote-push [message]` — send one real approval-backed Web Push request and wait for its exact acknowledgement.

The model-invoked `remote-mode` skill accepts two short handoffs: `Я ушёл` starts Remote and `Я здесь` stops it. It also understands explicit longer office/Remote commands. It only acts when the user sends such a message; it does not perform location tracking.

### Build and test

```bash
swift build -c release --product RemoteHTTPServer
swift build -c release --product RemoteMCPServer
swift test --filter RemoteTests
```

### Signed production updates

Remote production binaries must retain a certificate-backed signing identity so
macOS can recognize them across rebuilds. One-time setup stores the chosen personal
Apple Development certificate's SHA-1 fingerprint (from `security find-identity -v -p codesigning`)
in `~/Library/Application Support/Remote/signing-identity` with mode `600`.
This file contains a certificate identifier, not its private key. Signing uses macOS Keychain.

After building, install with the helper instead of copying raw build output:

```bash
Scripts/remote-install RemoteHTTPServer .build/out/Products/Release/RemoteHTTPServer --check-only
Scripts/remote-install RemoteHTTPServer .build/out/Products/Release/RemoteHTTPServer
```

For the native SwiftPM build engine, use the binary under `.build/release/` instead.
The `MCPServer_Shared.bundle` directory must be next to the source binary.
The helper verifies signing, preserves the identity after the initial migration from
ad hoc signing, refuses updates during active jobs, backs up the installed binary and
resources, and restarts/checks HTTP. It also supports `RemoteMCPServer`; existing MCP
clients keep their current process until reconnected.

After the first signed install, grant **Documents** access on the Mac once and test
a real task using a project in Documents. Reinstall with the same certificate and
repeat that test to confirm the permission survives. Signing/health checks alone do
not verify Documents access. Do this acceptance check while physically at the Mac.
Full Disk Access is not needed for this setup. Preserve the signing identity on later
updates; certificate replacement or expiration requires a separate planned check.

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
