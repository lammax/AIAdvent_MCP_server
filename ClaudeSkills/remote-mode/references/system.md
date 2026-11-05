# Remote system reference

Use this reference only for work on the Remote feature itself.

## Scope and topology

- Repository: `/Users/lammax/Documents/ThisIsMy/Programming/AI/MCP_server`.
- `RemoteMCPServer` exposes approvals, Remote mode, and controlled release tools.
- `RemoteHTTPServer` serves the authenticated PWA, agent jobs, usage, and Web Push.
- Shared implementation: `Sources/Shared/approval`.
- SQLite: `~/Library/Application Support/Remote/approval.sqlite`.
- Signed binaries: `~/Library/Application Support/Remote/bin`.
- HTTPS origin: `https://macbook-pro.tailab24a8.ts.net`.
- Pages: `/approvals`, `/codex`, and `/claude`.
- Remote uses Tailscale. Never alter ZeroTier, VPN, DNS, or routes without explicit permission.
- Never expose the login token.

## Message, chat, and approval routing

- Each web request stores its agent, registered project, optional chat ID, and task ID.
- Project/chat selection is provider- and project-scoped. Never reuse another project's chat.
- Existing Codex chats use the supported queued resume flow. Match results to the unique
  `Remote task ID:` marker through paginated summary history; never replay a persisted enqueue.
- New chats persist the emitted session ID as soon as it is known.
- A task-linked `ask_user` separates one bounded MCP wait from the durable decision lifetime.
- If it returns `pending`, the client cancels, or MCP restarts, retry with the exact same
  `task_id` and unchanged question IDs, text, types, order, and options. This atomically
  resumes the same SQLite approval and must not enqueue another Push.
- Never proceed without an answer or invent one. An answer saved during an interruption is
  returned by the retry. Stopping the Remote task cancels its linked pending approval.
- Every Remote question/report has a free-text field. It is optional in a mixed request and
  required when it is the only field.
- `mcp__remote__ask_user` already queues Web Push; never send a duplicate notification.

## Oversized Codex chat rotation

When persisted rollout history exceeds 25 MiB during a new Remote request:

1. Ask the old chat for a compact current handoff.
2. Start a clean Codex chat.
3. Send the handoff and original task to the successor.
4. Persist the successor ID immediately.
5. Retire the old chat from Remote discovery without deleting its rollout.
6. On restart, collect the persisted successor and never replay or rotate twice.

## PWA behavior

- Conversation discovery and latest-chat polling are project-scoped.
- Do not replace a selected chat while a request draft is non-empty; offer a switch.
- Manual history clearing hides only finished jobs for that agent.
- New projects must be direct children of configured roots and initialize Git on `main`.
- Web requests enable their agent's Remote mode atomically with job creation.

## Production and Git invariants

- Production installs use the trusted `mcp__remote__install_release` flow, backed by
  `Scripts/remote-install`; never copy or overwrite runtime binaries directly.
- Release requires tests, both release products, an explicitly requested commit/push,
  a clean tree, and zero upstream divergence.
- `queued` is not installed. Require `completed`, strict signatures for both binaries,
  `/health`, and Git synchronization before reporting success.
- The updater installs MCP first and HTTP last after queued/running jobs drain.
- The known mixed Debug/Release Swift cache failure is `clang dependency scanning failure`.
  Recover with `swift package clean`, then rerun tests; do not change source to chase it.
- Commit only when explicitly requested. Push normally, verify zero divergence, never force-push,
  and do not include unrelated user changes.
- Remove task-specific temporary files.

## Source map

- `ApprovalService.swift`: approval lifetimes, bounded waits, and resumable coordination.
- `SQLiteApprovalRepository.swift`: atomic retry deduplication and persistent state.
- `RemoteMCPServer.swift`: MCP tool schemas and pending/resume result contract.
- `RemoteClaudeJobService.swift`: durable job worker and restart recovery.
- `RemoteCodex.swift` / `RemoteCodexQueueRunner.swift`: Codex dispatch and result collection.
- `ApprovalHTTPRoutes.swift`: PWA/API routes, project/chat UI, and history.
- `Tests/RemoteTests/RemoteTests.swift`: Remote behavioral and regression coverage.

## Roadmap source of truth

Read `docs/REMOTE_TRANSPORT_MIGRATION.md` before roadmap/status work and verify live state
when deployment matters. Items 1–4 are accepted. Item 5 is installed with physical-iPhone
visual acceptance deferred. Item 6 has durable approval retry/restart coverage but needs
production and live delayed-answer acceptance. The next implementation tracks are security
hardening and transport independence. Always disclose uncommitted roadmap or skill edits.
