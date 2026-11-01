# Remote transport migration plan

## Purpose

Remote currently exposes its loopback-only HTTP service through Tailscale Serve. This plan keeps Remote usable if Tailscale becomes unreliable or must be replaced, without moving approval data off the Mac or disturbing the existing ZeroTier installation.

The transport and the user-facing Remote application are separate concerns:

- `RemoteHTTPServer` remains bound to `127.0.0.1:3010`.
- SQLite, the token, VAPID keys, Claude jobs, and approval logic remain local.
- An ingress transport supplies authenticated HTTPS connectivity from the iPhone to loopback.
- Web Push remains a notification channel, not the authority that grants an approval.

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

### Phase 0: Capture the current baseline

- Export the current Tailscale Serve configuration and record the working HTTPS origin.
- Record LaunchAgent, loopback health, tailnet ACL, certificate, and DNS behavior without changing them.
- Run the current approval, Claude job, push, restart, and LTE/Wi-Fi tests.
- Confirm the rollback backup includes configuration, not the SQLite database or token contents in logs.

### Phase 1: Remove transport assumptions from Remote

- Keep `REMOTE_PUBLIC_ORIGIN` as the single application-origin setting.
- Move Tailscale-specific status checks out of application health and into a transport diagnostics command.
- Add a transport status model: local application health, ingress health, public-origin reachability, and last successful iPhone contact.
- Ensure generated links, CSRF validation, cookie settings, push deep links, and skill output all derive from the configured public origin.
- Add tests proving that changing the configured origin changes links and validation without changing stored approvals or Claude jobs.

### Phase 2: Build a non-production alternate path

- Select one candidate after a short proof of connectivity from the iPhone over Wi-Fi and cellular data.
- Use a staging hostname and a separate authentication cookie namespace.
- Terminate the alternate ingress at a loopback proxy; never bind Remote directly to a wildcard address.
- Verify reconnect after Mac sleep, iPhone network changes, process restart, and Mac reboot.
- Block the Tailscale path during testing to prove the alternate route is genuinely independent.

### Phase 3: Introduce a stable origin

- Configure the production hostname and certificate before changing any client links.
- Test login, CSRF, PWA installation, push subscription persistence, notification deep links, and token rotation.
- Schedule the one-time iPhone transition: open the new origin, log in, install/open the PWA, enable notifications, and send a test push.
- Keep the old Tailscale origin available for a bounded rollback period, but do not allow approvals to be submitted ambiguously through two independent origins without explicit CSRF and cookie tests.

### Phase 4: Cut over and observe

- Change the configured public origin and all Remote skills together.
- Run an approval from creation through iPhone response and verify Claude receives the exact answer.
- Run a full `/claude` job and verify persisted output.
- Monitor ingress reconnects, authentication failures, push delivery, and duplicate submissions without logging sensitive content.
- Retire the old ingress only after the new path survives the agreed observation period.

### Phase 5: Add carrier-restriction fallback

- Detect prolonged iPhone unreachability, but do not interpret a failed ping alone as approval to change networking.
- Send a generic SMS or initiate a voice workflow only for an actual pending approval and only after a configured delay.
- Keep fallback decisions single-use, short-lived, and limited to approve/deny.
- Test with mobile data unavailable, not merely with Tailscale disconnected.

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

## Decision point

Do not choose a replacement solely by feature list. First determine the failure being solved:

- If only Tailscale's control plane is the concern, evaluate a Tailscale-compatible self-hosted control plane.
- If WireGuard or Tailscale endpoints are selectively blocked but general HTTPS works, evaluate a reverse HTTPS ingress with a stable owned domain.
- If all non-allowlisted mobile data is blocked, no overlay choice is sufficient; prioritize SMS/voice fallback and Wi-Fi operation.

The first engineering step should be Phase 1, because it reduces coupling without committing Remote to any provider.
