# Remote transport migration plan

## Purpose

Remote currently exposes its loopback-only HTTP service through Tailscale Serve. This plan keeps Remote usable if Tailscale becomes unreliable or must be replaced, without moving approval data off the Mac or disturbing the existing ZeroTier installation.

The transport and the user-facing Remote application are separate concerns:

- `RemoteHTTPServer` remains bound to `127.0.0.1:3010`.
- SQLite, the token, VAPID keys, Claude jobs, and approval logic remain local.
- An ingress transport supplies authenticated HTTPS connectivity from the iPhone to loopback.
- Web Push remains a notification channel, not the authority that grants an approval.

## Current implementation status

Status legend: **Implemented** is running in production and tested, **Partial** has reusable pieces but does not satisfy the whole phase, and **Planned** has not been implemented.

| Capability | Status | Current state |
| --- | --- | --- |
| Loopback-only HTTP backend | **Implemented** | `RemoteHTTPServer` listens on `127.0.0.1:3010` |
| Private HTTPS ingress | **Implemented** | Tailscale Serve exposes the app to the tailnet only; Funnel is disabled |
| Persistent local state | **Implemented** | SQLite, token, and stable VAPID configuration remain on the Mac with owner-only permissions |
| PWA and authenticated Web Push | **Implemented** | Home Screen PWA, service worker, generic payloads, persistent subscriptions, transactional outbox, retries, and stable notification tags are active |
| Approval workflows | **Implemented** | Single-select, multi-select, free-text, and mixed atomic requests are supported |
| Remote Claude jobs | **Implemented with known risk** | Jobs persist and run serially. Closed/new chats use `bypassPermissions`; delivery into an open Cursor chat keeps that chat's permission mode. |
| Browser protection | **Implemented baseline** | HMAC-derived Secure/HttpOnly/SameSite session cookie, CSRF token, Origin validation, no-store pages, and security headers |
| Automatic service lifecycle | **Implemented** | LaunchAgent startup, `/remote-start`, `/remote-status`, `/remote-stop`, `/remote-test`, and `/remote-push` |
| Independent agent modes and request context | **Implemented; basic iPhone flow verified** | Persistent Claude/Codex modes; agent/project/chat metadata; incoming request filters; agent stop keeps the shared service alive. The full multi-agent stop/restart matrix remains to be checked. |
| Switch agent mode by incoming message channel | **Implemented; desktop via agent instructions** | Valid web task submission and its agent mode are stored atomically. Desktop global rules/skills call an idempotent per-agent helper before handling a real user message. Explicit commands take priority; web workers carry a channel marker and cannot undo a later desktop switch. No unconditional native hook is installed; existing clients must load the updated rules. |
| Codex tasks in existing projects | **Implemented; iPhone tasks and Git flow verified** | Separate `/codex` page, registered projects and persisted results. A Remote-only permission profile permits project Git writes and HTTPS origin access. BrainApp's Clock Gap commit/push completed through the web. Existing desktop chat continuation is not implemented. |
| Compact task cards | **Implemented; iPhone verified** | Long requests, answers and errors collapse independently and retain disclosure state on refresh. |
| Signed deployment | **Implemented; restart verified** | `remote-install` preserves the personal certificate identity, makes backups and refuses installation while jobs are active. Documents permission survived reinstall; unattended self-update from a web job is not implemented. |
| Claude and Codex usage reports | **Implemented; iPhone verified** | Usage returns an answer in Remote's history with used/remaining percentages and reset times. Codex uses local app-server `account/rateLimits/read`; Claude uses its built-in `/usage` in print mode. No model task is queued and no provider login tokens are copied into Remote. A snapshot has a stable report ID, 30-second cache and 25-second query deadline. Only the newest Usage card per agent is displayed; older snapshots remain stored. |
| Stable user-owned application origin | **Planned** | The current origin is the Tailscale-provided hostname |
| Transport-independent diagnostics and ingress adapter | **Partial** | `REMOTE_PUBLIC_ORIGIN` exists, but health checks and skills still contain Tailscale-specific assumptions |
| Alternate ingress path | **Planned** | No Headscale, alternate overlay, reverse HTTPS tunnel, or managed access proxy is configured |
| Carrier-restriction fallback | **Planned** | No SMS or voice approval channel exists |
| Deferred security-hardening track | **Planned** | The current private-tailnet baseline remains in effect |

Updated 3 November 2026. The last committed baseline is `4f308a6` (`Usage upd`);
channel switching and latest-chat continuation are installed from the current uncommitted worktree. The current Remote test suite contains 53 passing
tests. The installed HTTP server was built with native SwiftPM in debug configuration;
a release build of this latest baseline remains a separate validation item.
Local health, bundled assets and SQLite checks passed. iPhone usage reports,
duplicate-card suppression, task disclosure controls, Codex tasks and the BrainApp
Git flow were verified. Full stop/restart, cancellation and concurrent-agent
acceptance coverage remains incomplete.

## Remaining product work

### Implemented: continue the latest working chat in a selected project

- Both pages default to the latest working chat by activity, scoped by provider
  and canonical registered project, excluding archived, diagnostic and subagent chats.
- Claude project choices use the names of chats currently open in Cursor and
  retain their exact session IDs; unopened registered projects remain available
  for explicit new chats.
- The form shows its title/date/ID before sending and pins that ID in SQLite;
  an explicit new-chat option remains. Missing targets fail without a silent fork.
- Native Codex `exec resume` and closed-chat Claude `--resume` preserve provider
  history. An open Cursor chat receives the request through Claude Code's supported
  cross-session `SendMessage`; Remote reads its next non-empty final `end_turn`
  through the public Agent SDK and returns it to the iPhone task page.
- Busy jobs retain their target and retry after five seconds without blocking
  other ready jobs. An open but `idle` Cursor chat is available to Remote; only an
  owner reporting `busy` waits. Codex uses its native writer lock at launch because
  app-server `active` also means a chat is merely loaded. Claude ownership is checked
  before delivery. The open-Cursor response collector has a 30-minute deadline.
- Claude web jobs explicitly state that Remote was enabled atomically at acceptance,
  preventing resumed chat context from reporting an obsolete disabled state or
  applying the desktop channel reset inside `REMOTE_MESSAGE_CHANNEL=web`.
- Claude discovery uses public Agent SDK 0.3.316 metadata functions, with a pinned
  Node support package outside the repo; Codex uses public app-server metadata.
- RemoteApproval now executes in MCP_server; the legacy directory is a read-only
  history lookup alias. Context and permissions remain provider/project scoped.
- Tests cover target pinning, foreign projects, diagnostics, busy owners, queue
  fairness, restart and actual session IDs. Form checks passed for stale fetches,
  retained drafts, exact submitted IDs and explicit new-chat behavior. A production
  HTTP acceptance test delivered into `artesia-ios-77` and returned
  `REMOTE_CURSOR_E2E_OK`; manual visual confirmation on the iPhone remains.
- The signed installer replaces resource bundles as a unit, preventing stale
  Contents/Resources assets from shadowing a newer native SwiftPM flat bundle.

1. **Task visibility and recovery.** Stream progress into web task cards; distinguish
   running, waiting for a human, blocked by permissions, cancelled and interrupted.
   Add a controlled stop action and document queue behavior.
2. **Controlled server updates.** A web job cannot replace its own host server:
   its sandbox forbids the Remote runtime directory and the installer rejects active
   jobs. Design a separate, explicitly authorized update path that drains the queue,
   preserves signing and supports rollback without granting broad writes to agents.
3. **Desktop lifecycle verification.** Channel switching is implemented with an
   authoritative HTTP entrypoint and instruction-driven desktop preflight. Verify
   updated instructions in all existing Claude/Cursor chats. A deterministic native
   desktop callback remains a future improvement; do not attach a blanket
   `UserPromptSubmit` mode-reset hook to synthetic/background events.
4. **Chat selection and new projects.** Add a picker for any existing chat beyond
   the implemented latest-chat continuation. Separately support creating a project
   under an allowlisted parent directory.
5. **Long-running approvals.** Investigate asynchronous resumption after the current
   wait expires, including restart/recovery; do not simply lengthen the timeout
   without confirming client behavior.
6. **Security hardening.** Follow the deferred track below, starting with Claude's
   permission bypass and per-device sessions. Complete the gate before public/shared ingress.
7. **Transport independence.** Finish application/ingress diagnostics, then test an
   alternate path, stable origin and any carrier-restriction fallback in staging.

For channel-based mode switching, only a new direct user message changes mode;
page views, polling, push receipts, tool output, and background task progress must not
change it. Mode remains independent per agent, and explicit start/stop commands take
precedence over channel defaults. Web submission stores mode and job atomically
after validation. Tests cover invalid submissions, explicit overrides, rollback,
independent agents, queued-worker behavior and child process markers. The desktop
helper is tested independently of the model; automatic client compliance still
depends on the client reading and following the installed global instructions.

## Important origin constraint

PWA installation, service workers, cookies, notification permission, and push subscriptions are tied to an HTTPS origin. Moving from `macbook-pro.tailab24a8.ts.net` to another hostname will normally require a new login, installing or opening the PWA from the new origin, and enabling notifications again.

Before changing transport, prefer introducing a stable user-owned hostname such as `remote.example.net`. The hostname should stay constant while its ingress implementation changes underneath it. This turns a later transport migration into a DNS or proxy change instead of an iPhone application migration.

Do not switch the production origin merely to prepare for a hypothetical migration. Introduce it only when the certificate, ingress, rollback, and iPhone transition have been tested end to end.

## Requirements for any replacement

A candidate transport must:

1. Provide end-to-end HTTPS for a stable hostname and support iPhone browsers and Home Screen PWAs.
2. Keep `RemoteHTTPServer` on loopback; do not expose port 3010 directly to the LAN or internet.
3. Require a private-network identity, mutual authentication, or an equally strong access boundary in addition to Remote's login token.
4. Start automatically after reboot, recover from network changes, and expose a local health check.
5. Preserve Secure, HttpOnly, SameSite cookies, CSRF origin validation, and the existing generic push payloads.
6. Allow immediate revocation of a lost iPhone and keep auditable connection logs without logging tokens, prompts, or answers.
7. Coexist with ZeroTier without changing its DNS, routes, interface, or service lifecycle.
8. Have a tested rollback to Tailscale that does not modify the database, token, or VAPID key.

## Candidate classes

| Candidate | Suitable when | Principal limitation |
| --- | --- | --- |
| Tailscale-compatible self-hosting, such as Headscale | The control plane is the concern but WireGuard connectivity is still reliable | It keeps essentially the same WireGuard data-plane dependency and does not solve a strict carrier allowlist |
| Another private overlay, including the existing ZeroTier network | Tailscale itself is unavailable but overlay traffic still passes | Certificate and routing integration are needed; strict mobile allowlists can block it too; the existing ZeroTier setup must remain untouched until a separately tested configuration is approved |
| Reverse HTTPS tunnel to an owned relay/VPS | Ordinary outbound HTTPS works but peer-to-peer VPN traffic is blocked | The relay becomes internet-facing infrastructure and needs hardening, monitoring, patching, rate limits, and a second authentication boundary |
| Managed access proxy/tunnel | Fast operational replacement with identity-aware access | Provider dependency remains; the provider's domains may also be unavailable under carrier restrictions |
| SMS or voice approval fallback | Mobile data is restricted to a strict allowlist | This is a limited emergency decision channel, not a full replacement for the PWA or free-form Claude interaction |

No VPN or tunnel should be assumed to work during a strict mobile-provider allowlist. Such a restriction can block both direct WireGuard traffic and relay/control endpoints. A truly independent fallback must use a channel that remains available, such as SMS, voice, or known working Wi-Fi.

## Recommended architecture

Use two layers rather than betting on one replacement:

1. **Stable HTTPS application origin.** Put a user-owned hostname in front of a replaceable ingress adapter. Continue to terminate requests into `127.0.0.1:3010` only.
2. **Independent emergency approval channel.** Add a narrowly scoped SMS or voice flow for approve/deny when mobile data cannot reach any private transport. Do not send task contents or secrets over that channel.

The emergency channel should use a short-lived, single-use challenge bound to one approval ID and the registered phone number. It should support only explicit approve or deny, reject replays and expired replies, rate-limit attempts, and write an audit event. Multi-select and free-text requests should wait for the PWA or Wi-Fi.

## Implementation phases

### Phase 0: Capture the current baseline — **Partial**

- Export the current Tailscale Serve configuration and record the working HTTPS origin.
- Record LaunchAgent, loopback health, tailnet ACL, certificate, and DNS behavior without changing them.
- Run the current approval, Claude job, push, restart, and LTE/Wi-Fi tests.
- Confirm the rollback backup includes configuration, not the SQLite database or token contents in logs.

### Phase 1: Remove transport assumptions from Remote — **Partial**

- Keep `REMOTE_PUBLIC_ORIGIN` as the single application-origin setting.
- Move Tailscale-specific status checks out of application health and into a transport diagnostics command.
- Add a transport status model: local application health, ingress health, public-origin reachability, and last successful iPhone contact.
- Ensure generated links, CSRF validation, cookie settings, push deep links, and skill output all derive from the configured public origin.
- Add tests proving that changing the configured origin changes links and validation without changing stored approvals or Claude jobs.

### Phase 2: Build a non-production alternate path — **Planned**

- Select one candidate after a short proof of connectivity from the iPhone over Wi-Fi and cellular data.
- Use a staging hostname and a separate authentication cookie namespace.
- Terminate the alternate ingress at a loopback proxy; never bind Remote directly to a wildcard address.
- Verify reconnect after Mac sleep, iPhone network changes, process restart, and Mac reboot.
- Block the Tailscale path during testing to prove the alternate route is genuinely independent.

### Phase 3: Introduce a stable origin — **Planned**

- Configure the production hostname and certificate before changing any client links.
- Test login, CSRF, PWA installation, push subscription persistence, notification deep links, and token rotation.
- Schedule the one-time iPhone transition: open the new origin, log in, install/open the PWA, enable notifications, and send a test push.
- Keep the old Tailscale origin available for a bounded rollback period, but do not allow approvals to be submitted ambiguously through two independent origins without explicit CSRF and cookie tests.

### Phase 4: Cut over and observe — **Planned**

- Change the configured public origin and all Remote skills together.
- Run an approval from creation through iPhone response and verify Claude receives the exact answer.
- Run a full `/claude` job and verify persisted output.
- Monitor ingress reconnects, authentication failures, push delivery, and duplicate submissions without logging sensitive content.
- Retire the old ingress only after the new path survives the agreed observation period.

### Phase 5: Add carrier-restriction fallback — **Planned**

- Detect prolonged iPhone unreachability, but do not interpret a failed ping alone as approval to change networking.
- Send a generic SMS or initiate a voice workflow only for an actual pending approval and only after a configured delay.
- Keep fallback decisions single-use, short-lived, and limited to approve/deny.
- Test with mobile data unavailable, not merely with Tailscale disconnected.

### Deferred security-hardening track — **Planned; required before broader ingress**

The current deployment is appropriate for personal use inside the private tailnet, but `/claude` is intentionally high trust: an authenticated request starts Claude with `bypassPermissions` and the privileges of the macOS user. Treat the Remote token and every authorized browser session as credentials with consequences comparable to remote shell access.

Complete this track before exposing Remote through a public ingress, shared tailnet, or less trusted transport. It may be scheduled after the current private-tailnet MVP while Tailscale Serve remains `tailnet only` and Funnel remains disabled.

Work in this order:

1. Replace `bypassPermissions` with explicit allow rules and route unmatched Claude permission requests through an approval-specific Remote MCP tool. Keep deny rules non-overridable.
2. Replace the single deterministic 90-day session with device-specific server-side sessions, individual revocation, idle and absolute expiry, and a view of authorized devices. Token rotation must still revoke every session.
3. Restrict Tailscale ACL access to the required Mac and iPhone identities, then preserve an equivalent identity boundary for any replacement transport.
4. Add rate limits and bounded queues for login attempts, approval submissions, push subscription changes, test pushes, and Claude jobs. Failed authentication must not reveal whether a token prefix was correct.
5. Add configurable retention and secure pruning for completed approvals, Claude prompts/results, push outbox history, and operational logs. Keep audit metadata without retaining task contents indefinitely.
6. Change Remote log directory and files to owner-only permissions and verify that tokens, prompts, answers, cookies, push secrets, and Claude output are never logged.
7. Move inline JavaScript and CSS to bundled resources or use per-response CSP nonces; remove `unsafe-inline`. Require the configured HTTPS Origin on browser mutations rather than accepting a missing Origin, while preserving authenticated non-browser Bearer clients explicitly.
8. Harden push subscription endpoint validation against private-address SSRF and unexpected push providers. Preserve generic notification payloads and stable deduplication tags.
9. Evaluate moving the Remote token and VAPID private key into macOS Keychain while retaining unattended LaunchAgent startup and a tested recovery procedure.
10. Add dependency-vulnerability review, update policy, restore testing, and a focused external penetration test for authentication, CSRF, XSS, request smuggling, SSRF, replay, and privilege escalation.

Security acceptance criteria:

- Compromising one authorized iPhone session does not require rotating every other device session.
- An unknown Claude tool action cannot execute until explicitly approved; a denied action cannot be overridden from the phone.
- Repeated login and job-submission attempts are rate-limited and cannot grow SQLite or the process queue without bound.
- No prompt, answer, token, session credential, VAPID secret, or Claude output appears in logs or push payloads.
- Expired data is pruned according to policy, while active approvals and retryable push deliveries are preserved.
- Browser mutations without a valid session, CSRF token, and exact production Origin are rejected.
- The application passes its automated security tests and a manual lost-device, token-rotation, restart, and rollback exercise.
- Public or shared ingress remains disabled until these criteria and the replacement transport's own security review pass.

## Acceptance tests

The migration is complete only when all of these pass:

- Existing SQLite approvals, Claude jobs, token, and VAPID configuration survive the cutover.
- The iPhone can log in and answer an approval over Wi-Fi and cellular data.
- A push opens the correct approval on the stable origin without exposing prompt content in the notification.
- A dirty free-text form is not reset by polling or reconnects.
- Restarting the ingress, Remote service, or Mac does not require a new push subscription.
- A lost or revoked device cannot reach the ingress or submit an approval.
- Duplicate, expired, forged, and cross-origin responses are rejected.
- Blocking the old transport does not break the alternate path.
- Rollback restores the old path without database migration or VAPID rotation.
- Under a strict carrier allowlist, the system clearly reports that the PWA is unreachable and uses only the separately tested emergency channel.
- Any transport broader than the current private tailnet has passed the deferred security-hardening gate.

## Decision point

Do not choose a replacement solely by feature list. First determine the failure being solved:

- If only Tailscale's control plane is the concern, evaluate a Tailscale-compatible self-hosted control plane.
- If WireGuard or Tailscale endpoints are selectively blocked but general HTTPS works, evaluate a reverse HTTPS ingress with a stable owned domain.
- If all non-allowlisted mobile data is blocked, no overlay choice is sufficient; prioritize SMS/voice fallback and Wi-Fi operation.

The first engineering step should be Phase 1, because it reduces coupling without committing Remote to any provider. The security-hardening track can follow the private-tailnet MVP, but becomes a mandatory gate before any public or shared ingress cutover.
