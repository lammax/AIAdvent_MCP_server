import Foundation
import GRDB
import MCP
import XCTest
import XCTVapor
@testable import Shared

final class RemoteTests: XCTestCase {
    func testConversationCatalogScopesProjectAndSortsActivity() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let old = RemoteConversation(id: UUID().uuidString, title: "Old", project: path, updatedAt: 10, busy: false)
        let recent = RemoteConversation(id: UUID().uuidString, title: "Recent", project: path, updatedAt: 20, busy: false)
        let foreign = RemoteConversation(id: UUID().uuidString, title: "Other", project: "/other", updatedAt: 30, busy: false)
        let catalog = RemoteConversationCatalog(reader: TestConversationReader(rows: [old, foreign, recent]),
                                               repository: fixture.repository, projects: [RemoteProject(name: "Test", path: path)])
        let rows = try await catalog.list(agent: "codex", project: path)
        XCTAssertEqual(rows.map(\.id), [recent.id, old.id])
        do { _ = try await catalog.validate(agent: "codex", project: path, id: foreign.id); XCTFail("Cross-project continuation") }
        catch RemoteConversationError.missing {}
    }

    func testClearingRemoteHistoryHidesOnlyFinishedJobsAndPreservesSessions() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let now = Date()
        let completedSession = UUID().uuidString
        let completed = RemoteClaudeJob(
            id: UUID(), prompt: "Done", workingDirectory: path, status: .completed,
            response: "Result", sessionID: completedSession, createdAt: now,
            startedAt: now, completedAt: now, agent: "codex"
        )
        let failed = RemoteClaudeJob(
            id: UUID(), prompt: "Failed", workingDirectory: path, status: .failed,
            errorMessage: "Failure", createdAt: now.addingTimeInterval(1),
            completedAt: now.addingTimeInterval(1), agent: "codex"
        )
        let queued = RemoteClaudeJob(
            id: UUID(), prompt: "Queued", workingDirectory: path, status: .queued,
            createdAt: now.addingTimeInterval(2), agent: "codex"
        )
        let claude = RemoteClaudeJob(
            id: UUID(), prompt: "Claude done", workingDirectory: path, status: .completed,
            response: "Result", createdAt: now.addingTimeInterval(3),
            completedAt: now.addingTimeInterval(3), agent: "claude"
        )
        for job in [completed, failed, queued, claude] {
            try await fixture.repository.createClaudeJob(job)
        }

        let cleared = try await fixture.repository.hideFinishedClaudeJobs(agent: "codex", at: now)
        XCTAssertEqual(cleared, 2)
        let visible = try await fixture.repository.recentClaudeJobs(limit: 10)
        XCTAssertEqual(Set(visible.map(\.id)), [queued.id, claude.id])
        let retained = try await fixture.repository.claudeJob(id: completed.id)
        XCTAssertNotNil(retained)
        let sessions = try await fixture.repository.conversationSessionIDs(agent: "codex", project: path)
        XCTAssertEqual(sessions, [completedSession])
        let clearedAgain = try await fixture.repository.hideFinishedClaudeJobs(agent: "codex", at: now)
        XCTAssertEqual(clearedAgain, 0)
    }

    func testCodexCatalogExcludesUnregisteredExecAndDiagnostics() throws {
        let normal = UUID().uuidString, known = UUID().uuidString, diagnostic = UUID().uuidString
        let rows: [[String: Any]] = [
            ["id": normal, "cwd": "/project", "updatedAt": 2.0, "source": "vscode", "name": "Work"],
            ["id": known, "cwd": "/project", "updatedAt": 3.0, "source": "exec"],
            ["id": diagnostic, "cwd": "/project", "updatedAt": 5.0, "source": ["custom": "remote-diagnostic"]],
            ["id": UUID().uuidString, "cwd": "/project", "updatedAt": 6.0, "source": "exec"],
            ["id": UUID().uuidString, "cwd": "/project", "updatedAt": 7.0, "source": "subAgent"]
        ]
        let result = try RemoteCLIConversationsReader.decodeCodex(JSONSerialization.data(withJSONObject: ["data": rows]),
                                                                  knownRemoteIDs: [known, diagnostic])
        XCTAssertEqual(Set(result.map(\.id)), [normal, known])
    }

    func testCodexCatalogReadsHistorySizeAndExcludesRetiredConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let transcript = fixture.directory.appendingPathComponent("rollout.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: transcript.path, contents: nil))
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.truncate(atOffset: UInt64(RemoteAgentRunner.codexRotationThresholdBytes + 1))
        try handle.close()
        let oldID = UUID().uuidString, successorID = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["data": [[
            "id": oldID, "cwd": path, "updatedAt": 2.0, "source": "vscode",
            "name": "Large", "path": transcript.path,
        ]]])
        let decoded = try RemoteCLIConversationsReader.decodeCodex(data, knownRemoteIDs: [])
        XCTAssertEqual(decoded.first?.historyBytes, RemoteAgentRunner.codexRotationThresholdBytes + 1)

        let job = RemoteClaudeJob(id: UUID(), prompt: "Rotate", workingDirectory: path,
                                  status: .running, sessionID: oldID, createdAt: Date(), agent: "codex")
        try await fixture.repository.createClaudeJob(job)
        _ = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        try await fixture.repository.markCodexConversationRotated(
            jobID: job.id, project: path, retiredSessionID: oldID,
            successorSessionID: successorID, at: Date()
        )
        let catalog = RemoteConversationCatalog(
            reader: TestConversationReader(rows: decoded), repository: fixture.repository,
            projects: [RemoteProject(name: "Test", path: path)]
        )
        let visible = try await catalog.list(agent: "codex", project: path)
        XCTAssertTrue(visible.isEmpty)
    }

    func testClaudeUsesOpenCursorChatNamesAndKeepsUnopenedProjects() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let openPath = fixture.directory.resolvingSymlinksInPath().path
        let otherURL = fixture.directory.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: false)
        let otherPath = otherURL.resolvingSymlinksInPath().path
        let openID = UUID().uuidString
        let catalog = RemoteConversationCatalog(
            reader: TestConversationReader(rows: [
                .init(id: openID, title: "artesia-ios-ed", project: openPath, updatedAt: 20, busy: false, open: true),
                .init(id: UUID().uuidString, title: "Closed summary", project: otherPath, updatedAt: 30, busy: false)
            ]),
            repository: fixture.repository,
            projects: [RemoteProject(name: "Static Artesia", path: openPath), RemoteProject(name: "Other", path: otherPath)]
        )

        let choices = try await catalog.projectChoices(agent: "claude")
        XCTAssertEqual(choices, [
            RemoteProjectChoice(name: "artesia-ios-ed", path: openPath, sessionID: openID),
            RemoteProjectChoice(name: "Other", path: otherPath)
        ])
    }

    func testClaudeOwnerMetadataOverridesStoredSessionTitle() throws {
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let id = UUID().uuidString
        let merged = try RemoteCLIConversationsReader.mergeClaudeOwners(
            sessions: [.init(id: id, title: "Generated SDK summary", project: path, updatedAt: 42, busy: false)],
            activeRows: [["sessionId": id, "cwd": path, "name": "Cursor chat title", "startedAt": 1_000]],
            projects: [path]
        )
        XCTAssertEqual(merged, [.init(id: id, title: "Cursor chat title", project: path, updatedAt: 42, busy: false, open: true)])

        let busy = try RemoteCLIConversationsReader.mergeClaudeOwners(
            sessions: merged,
            activeRows: [["sessionId": id, "cwd": path, "name": "Cursor chat title", "status": "busy"]],
            projects: [path]
        )
        XCTAssertTrue(try XCTUnwrap(busy.first).busy)
    }

    func testContinuationPinsRequestedIDAndRejectsForeignID() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let target = RemoteConversation(id: UUID().uuidString, title: "Shown before enqueue", project: path, updatedAt: 10, busy: false)
        let newer = RemoteConversation(id: UUID().uuidString, title: "Newer", project: path, updatedAt: 20, busy: false)
        let catalog = RemoteConversationCatalog(reader: TestConversationReader(rows: [target, newer]),
            repository: fixture.repository, projects: [RemoteProject(name: "Test", path: path)])
        let jobs = RemoteClaudeJobService(repository: fixture.repository, runner: StubClaudeRunner(), workingDirectory: path)
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(app: app, service: fixture.service,
            authorization: ApprovalHTTPAuthorization(token: fixture.token), claudeService: jobs,
            agentRepository: fixture.repository, projects: [RemoteProject(name: "Test", path: path)], conversations: catalog)
        defer { Task { try? await app.asyncShutdown() } }
        let unauth = try await app.sendRequest(.GET, "/api/remote/conversations?agent=codex&project=" + path)
        XCTAssertEqual(unauth.status, .unauthorized)
        var headers = HTTPHeaders(); headers.bearerAuthorization = .init(token: fixture.token); headers.contentType = .json
        func payload(_ id: String) throws -> ByteBuffer {
            byteBuffer(String(decoding: try JSONEncoder().encode(["prompt":"Continue", "project":path,
                "conversation":"latest", "sessionID":id]), as: UTF8.self))
        }
        let invalid = try await app.sendRequest(.POST, "/codex/jobs", headers: headers, body: payload(UUID().uuidString))
        XCTAssertEqual(invalid.status, .conflict)
        let before = try await fixture.repository.recentClaudeJobs(limit: 10)
        XCTAssertTrue(before.isEmpty)
        let accepted = try await app.sendRequest(.POST, "/codex/jobs", headers: headers, body: payload(target.id))
        XCTAssertEqual(accepted.status, .ok)
        let response = try accepted.content.decode(RemoteClaudeJobResponse.self)
        XCTAssertEqual(response.sessionID, target.id)
    }

    func testBusyConversationDefersWithoutBlockingOtherJobsAndKeepsTargetOnRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(), target = UUID().uuidString
        let waiting = RemoteClaudeJob(id: UUID(), prompt: "Continue", workingDirectory: fixture.directory.path,
                                     status: .queued, sessionID: target, createdAt: now, agent: "codex")
        try await fixture.repository.createClaudeJob(waiting)
        _ = try await fixture.repository.claimNextClaudeJob(startedAt: now)
        try await fixture.repository.deferBusyConversation(id: waiting.id, until: now.addingTimeInterval(60))
        let next = RemoteClaudeJob(id: UUID(), prompt: "Other", workingDirectory: fixture.directory.path,
                                  status: .queued, createdAt: now.addingTimeInterval(1))
        try await fixture.repository.createClaudeJob(next)
        let runnable = try await fixture.repository.claimNextClaudeJob(startedAt: now.addingTimeInterval(2))
        XCTAssertEqual(runnable?.id, next.id)
        try await fixture.repository.completeClaudeJob(id: next.id, result: .init(response: "Done", sessionID: nil), completedAt: now)
        let path = await fixture.repository.path
        let reopened = try SQLiteApprovalRepository(path: path)
        try await reopened.requeueInterruptedClaudeJobs()
        let resumed = try await reopened.claimNextClaudeJob(startedAt: now.addingTimeInterval(61))
        XCTAssertEqual(resumed?.id, waiting.id)
        XCTAssertEqual(resumed?.sessionID, target)
    }
    func testResumedRunnerUsesPinnedSessionAndRejectsBusyOwner() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let id = UUID().uuidString
        let script = fixture.directory.appendingPathComponent("queue-probe")
        let queueCount = fixture.directory.appendingPathComponent("queue-count")
        let jobID = UUID()
        try """
        #!/bin/sh
        case "$1" in
          queue)
            printf x >> "\(queueCount.path)"
            exit 0
            ;;
          app-server)
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              case "$count" in
                1)
                  printf '%s\\n' '{"id":1,"result":{}}'
                  ;;
                3)
                  printf '%s\\n' '{"id":2,"result":{"data":[{"id":"newer","status":"completed","itemsView":"summary","items":[]}],"nextCursor":"older"}}'
                  ;;
                4)
                  (sleep 1; printf '%s\\n' '{"id":3,"result":{"data":[{"id":"turn","status":"completed","itemsView":"summary","items":[{"id":"user","type":"userMessage","content":[{"type":"text","text":"Remote task ID: \(jobID.uuidString)"}]},{"id":"agent","type":"agentMessage","text":"Retained"}]}],"nextCursor":null}}') &
                  response_pid=$!
                  ;;
              esac
            done
            if [ -n "${response_pid:-}" ]; then kill "$response_pid" 2>/dev/null || true; fi
            exit 0
            ;;
        esac
        exit 8
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let project = RemoteProject(name: "Test", path: path)
        let job = RemoteClaudeJob(id: jobID, prompt: "Continue", workingDirectory: path,
                                 status: .running, sessionID: id, createdAt: Date(), agent: "codex")
        let result = try await RemoteCodexQueueRunner(
            codexPath: script.path, repository: fixture.repository,
            timeout: 5, pollInterval: 0.01
        ).run(job: job, directory: path, prompt: RemoteAgentRunner.codexPrompt(job: job, directory: path))
        XCTAssertEqual(result.sessionID, id)
        XCTAssertEqual(result.response, "Retained")
        XCTAssertEqual(try String(contentsOf: queueCount, encoding: .utf8), "x")

        let catalog = RemoteConversationCatalog(reader: TestConversationReader(rows: [
            .init(id: id, title: "Existing", project: path, updatedAt: 1, busy: true)
        ]), repository: fixture.repository, projects: [project])
        let runner = RemoteAgentRunner(claude: ClaudeCLIRunner(executablePath: script.path), codexPath: script.path,
                                       projects: [project], conversations: catalog, repository: fixture.repository)
        do {
            _ = try await runner.run(job: job)
            XCTFail("Busy owner must defer")
        } catch RemoteConversationError.busy {}
    }

    func testCodexRunnerWaitsForTransientInterruptedTurnToComplete() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let id = UUID().uuidString
        let jobID = UUID()
        let script = fixture.directory.appendingPathComponent("queue-transient-interrupted")
        let pollCount = fixture.directory.appendingPathComponent("poll-count")
        try """
        #!/bin/sh
        case "$1" in
          queue)
            exit 0
            ;;
          app-server)
            polls=0
            if [ -f "\(pollCount.path)" ]; then polls=$(cat "\(pollCount.path)"); fi
            polls=$((polls + 1))
            printf '%s' "$polls" > "\(pollCount.path)"
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              case "$count" in
                1)
                  printf '%s\n' '{"id":1,"result":{}}'
                  ;;
                3)
                  if [ "$polls" -eq 1 ]; then
                    status=interrupted
                    agent=''
                  else
                    status=completed
                    agent=',{"type":"agentMessage","text":"Finished after polling"}'
                  fi
                  printf '%s\n' '{"id":2,"result":{"data":[{"id":"turn","status":"'"$status"'","error":null,"items":[{"type":"userMessage","content":[{"type":"text","text":"Remote task ID: \(jobID.uuidString)"}]}'"$agent"']}],"nextCursor":null}}'
                  ;;
              esac
            done
            exit 0
            ;;
        esac
        exit 8
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let job = RemoteClaudeJob(id: jobID, prompt: "Continue", workingDirectory: path,
                                  status: .running, sessionID: id, createdAt: Date(), agent: "codex")

        let result = try await RemoteCodexQueueRunner(
            codexPath: script.path, repository: fixture.repository,
            timeout: 2, pollInterval: 0.01
        ).run(job: job, directory: path, prompt: RemoteAgentRunner.codexPrompt(job: job, directory: path))

        XCTAssertEqual(result, .init(response: "Finished after polling", sessionID: id))
        XCTAssertEqual(try String(contentsOf: pollCount, encoding: .utf8), "2")
    }

    func testOversizedCodexConversationRotatesThroughSummaryAndRetiresOldChat() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let oldID = UUID().uuidString, newID = UUID().uuidString, jobID = UUID()
        let script = fixture.directory.appendingPathComponent("rotation-probe")
        let queueArguments = fixture.directory.appendingPathComponent("queue-arguments")
        let newPrompt = fixture.directory.appendingPathComponent("new-prompt")
        try """
        #!/bin/sh
        case "$1" in
          queue)
            printf '%s\\n' "$@" > "\(queueArguments.path)"
            exit 0
            ;;
          app-server)
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              case "$count" in
                1) printf '%s\\n' '{"id":1,"result":{}}' ;;
                3) printf '%s\\n' '{"id":2,"result":{"data":[{"id":"summary","status":"completed","itemsView":"summary","items":[{"type":"userMessage","content":[{"type":"text","text":"Remote task ID: \(jobID.uuidString)"}]},{"type":"agentMessage","text":"CURRENT IMPORTANT SUMMARY"}]}],"nextCursor":null}}' ;;
              esac
            done
            exit 0
            ;;
          exec)
            output=''
            prompt=''
            while [ "$#" -gt 0 ]; do
              if [ "$1" = '--output-last-message' ]; then shift; output="$1"; fi
              prompt="$1"
              shift
            done
            printf '%s' "$prompt" > "\(newPrompt.path)"
            printf '%s' 'Rotated answer' > "$output"
            printf '%s\\n' '{"type":"thread.started","thread_id":"\(newID)"}'
            exit 0
            ;;
        esac
        exit 8
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let project = RemoteProject(name: "Test", path: path)
        let job = RemoteClaudeJob(id: jobID, prompt: "Do the current task", workingDirectory: path,
                                  status: .queued, sessionID: oldID, createdAt: Date(), agent: "codex")
        try await fixture.repository.createClaudeJob(job)
        let claimed = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        let running = try XCTUnwrap(claimed)
        let catalog = RemoteConversationCatalog(
            reader: TestConversationReader(rows: [
                .init(id: oldID, title: "Large", project: path, updatedAt: 1, busy: false,
                      historyBytes: RemoteAgentRunner.codexRotationThresholdBytes + 1)
            ]),
            repository: fixture.repository,
            projects: [project]
        )
        let runner = RemoteAgentRunner(
            claude: ClaudeCLIRunner(executablePath: script.path), codexPath: script.path,
            projects: [project], conversations: catalog, repository: fixture.repository
        )
        let result = try await runner.run(job: running)
        XCTAssertEqual(result, .init(response: "Rotated answer", sessionID: newID))
        XCTAssertTrue(try String(contentsOf: queueArguments, encoding: .utf8).contains("persisted history exceeded 25 MiB"))
        let prompt = try String(contentsOf: newPrompt, encoding: .utf8)
        XCTAssertTrue(prompt.contains("CURRENT IMPORTANT SUMMARY"))
        XCTAssertTrue(prompt.contains("Do the current task"))
        let persisted = try await fixture.repository.claudeJob(id: jobID)
        let retired = try await fixture.repository.retiredConversationSessionIDs(agent: "codex", project: path)
        XCTAssertEqual(persisted?.sessionID, newID)
        XCTAssertEqual(retired, [oldID])
    }

    func testDispatchedCodexJobResumesCollectionAfterRestartWithoutReplay() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date()
        let dispatched = RemoteClaudeJob(
            id: UUID(), prompt: "Queued", workingDirectory: fixture.directory.path,
            status: .queued, sessionID: UUID().uuidString, createdAt: now, agent: "codex"
        )
        try await fixture.repository.createClaudeJob(dispatched)
        _ = try await fixture.repository.claimNextClaudeJob(startedAt: now)
        try await fixture.repository.markCodexMessageQueued(id: dispatched.id, at: now)
        try await fixture.repository.requeueInterruptedClaudeJobs()
        let resumed = try await fixture.repository.claimNextClaudeJob(startedAt: now.addingTimeInterval(1))
        XCTAssertEqual(resumed?.id, dispatched.id)
        XCTAssertNotNil(resumed?.messageQueuedAt)

        try await fixture.repository.failClaudeJob(
            id: dispatched.id, message: "test cleanup", completedAt: now.addingTimeInterval(1)
        )
        let unsafe = RemoteClaudeJob(
            id: UUID(), prompt: "Legacy exec", workingDirectory: fixture.directory.path,
            status: .queued, sessionID: UUID().uuidString, createdAt: now.addingTimeInterval(2), agent: "codex"
        )
        try await fixture.repository.createClaudeJob(unsafe)
        _ = try await fixture.repository.claimNextClaudeJob(startedAt: now.addingTimeInterval(2))
        try await fixture.repository.requeueInterruptedClaudeJobs()
        let interrupted = try await fixture.repository.claudeJob(id: unsafe.id)
        XCTAssertEqual(interrupted?.status, .failed)
    }

    func testChannelDefaultsAndExplicitCommands() {
        XCTAssertTrue(RemoteModePolicy.enabled(channel: .web, prompt: "Build"))
        XCTAssertFalse(RemoteModePolicy.enabled(channel: .desktop, prompt: "Build"))
        XCTAssertTrue(RemoteModePolicy.enabled(channel: .desktop, prompt: "Я УШЁЛ!"))
        XCTAssertFalse(RemoteModePolicy.enabled(channel: .web, prompt: "Я здесь."))
        XCTAssertTrue(RemoteModePolicy.enabled(channel: .desktop, prompt: "/remote-start"))
        XCTAssertFalse(RemoteModePolicy.enabled(channel: .web, prompt: "/remote-stop"))
        XCTAssertFalse(RemoteModePolicy.enabled(channel: .desktop, prompt: "В тексте написано Я ушёл"))
    }

    func testWebModeAndJobAreAtomicAndDoNotAffectOtherAgent() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try await fixture.repository.setRemoteMode(agent: "claude", enabled: false)
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: false)
        let job = RemoteClaudeJob(id: UUID(), prompt: "Web", workingDirectory: fixture.directory.path,
                                 status: .queued, createdAt: Date(), agent: "codex")
        try await fixture.repository.createWebJob(job, remoteEnabled: true)
        var modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, true)
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, false)
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: false)
        do {
            try await fixture.repository.createWebJob(job, remoteEnabled: true)
            XCTFail("Duplicate insert must fail and roll back the mode write")
        } catch {}
        modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, false)
        let queued = try await fixture.repository.claudeJob(id: job.id)
        XCTAssertEqual(queued?.status, .queued)
        _ = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, false,
                       "A queued worker must not override a newer desktop message")
    }

    func testClaudeWebMessageEnablesModeAndExplicitStopWins() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: false)
        try await fixture.repository.setRemoteMode(agent: "claude", enabled: false)
        let jobs = RemoteClaudeJobService(repository: fixture.repository, runner: StubClaudeRunner(),
                                         workingDirectory: fixture.directory.path)
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(app: app, service: fixture.service,
                                    authorization: ApprovalHTTPAuthorization(token: fixture.token),
                                    claudeService: jobs, agentRepository: fixture.repository)
        defer { Task { try? await app.asyncShutdown() } }
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        _ = try await app.sendRequest(.GET, "/claude", headers: headers)
        _ = try await app.sendRequest(.GET, "/claude/jobs", headers: headers)
        var modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, false)
        headers.contentType = .json
        let accepted = try await app.sendRequest(.POST, "/claude/jobs", headers: headers,
                                                body: byteBuffer(#"{"prompt":"Test"}"#))
        XCTAssertEqual(accepted.status, .ok)
        modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, true)
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, false)
        let stopped = try await app.sendRequest(.POST, "/claude/jobs", headers: headers,
                                               body: byteBuffer(#"{"prompt":"Я здесь"}"#))
        XCTAssertEqual(stopped.status, .ok)
        modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, false)
    }

    func testBothWebRunnersMarkChildChannel() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let claudeScript = fixture.directory.appendingPathComponent("claude-probe")
        try """
        #!/bin/sh
        for argument in "$@"; do last="$argument"; done
        case "$last" in
          *"Remote mode for Claude was enabled atomically"*"User request:"*) ;;
          *) exit 12 ;;
        esac
        printf '{"result":"%s"}' "$REMOTE_MESSAGE_CHANNEL"
        """.write(to: claudeScript, atomically: true, encoding: .utf8)
        let codexScript = fixture.directory.appendingPathComponent("codex-probe")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--output-last-message" ]; then shift; output="$1"; break; fi
            shift
        done
        printf '%s' "$REMOTE_MESSAGE_CHANNEL" > "$output"
        printf '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001"}\\n'
        """.write(to: codexScript, atomically: true, encoding: .utf8)
        for path in [claudeScript, codexScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let runner = RemoteAgentRunner(claude: ClaudeCLIRunner(executablePath: claudeScript.path),
                                       codexPath: codexScript.path,
                                       projects: [RemoteProject(name: "Test", path: fixture.directory.path)])
        for agent in ["claude", "codex"] {
            let job = RemoteClaudeJob(id: UUID(), prompt: "Probe", workingDirectory: fixture.directory.path,
                                      status: .running, createdAt: Date(), agent: agent)
            let result = try await runner.run(job: job)
            XCTAssertEqual(result.response, "web")
        }
    }

    func testUsageParsersPreserveMissingValuesAndExcludeLocalAnalytics() throws {
        let report = try RemoteCLIUsageReader.codexText(Data(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"windowDurationMins":10080}},"rateLimitsByLimitId":{}}"#.utf8))
        XCTAssertTrue(report.contains("осталось 100%"))
        XCTAssertFalse(report.contains("7 дней"))
        XCTAssertThrowsError(try RemoteCLIUsageReader.codexText(Data(#"{"rateLimits":null}"#.utf8)))
        let claude = try RemoteCLIUsageReader.claudeText("Current session: 9% used · resets Nov 2 at 1:09pm (Europe/Moscow)\nCurrent week (all models): 27% used · resets Nov 7 at 8:59am (Europe/Moscow)\nTop skills: private local history")
        XCTAssertTrue(claude.contains("осталось 91%"))
        XCTAssertTrue(claude.contains("осталось 73%"))
        XCTAssertFalse(claude.contains("private local history"))
        XCTAssertThrowsError(try RemoteCLIUsageReader.claudeText("Not logged in"))
    }

    func testUsageReturnsPersistedAnswerWithoutQueueOrAgentMode() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let reader = TestUsageReader()
        let usage = RemoteUsageService(reader: reader)
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(app: app, service: fixture.service,
                                    authorization: ApprovalHTTPAuthorization(token: fixture.token),
                                    agentRepository: fixture.repository, usage: usage)
        defer { Task { try? await app.asyncShutdown() } }
        let unauthorized = try await app.sendRequest(.POST, "/codex/usage")
        XCTAssertEqual(unauthorized.status, .forbidden)
        let initialCalls = await reader.calls
        XCTAssertEqual(initialCalls, 0)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let first = try await app.sendRequest(.POST, "/codex/usage", headers: headers)
        XCTAssertEqual(first.status, .ok)
        let second = try await app.sendRequest(.POST, "/codex/usage", headers: headers)
        XCTAssertEqual(second.status, .ok)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.body.readableBytesView)) as? [String: Any])
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.body.readableBytesView)) as? [String: Any])
        XCTAssertEqual(firstJSON["id"] as? String, secondJSON["id"] as? String)
        XCTAssertEqual(firstJSON["createdAt"] as? String, secondJSON["createdAt"] as? String)
        let calls = await reader.calls
        XCTAssertEqual(calls, 1)
        let jobs = try await fixture.repository.recentClaudeJobs(limit: 10)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertTrue(jobs.allSatisfy { $0.status == .completed && $0.agent == "codex" && $0.response?.contains("fixture usage") == true })
        let next = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        XCTAssertNil(next)
    }

    func testUsageSnapshotInsertIsIdempotentUnderConcurrency() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date()
        let snapshot = RemoteClaudeJob(id: UUID(), prompt: "Usage", workingDirectory: "",
                                      status: .completed, response: "snapshot", createdAt: now, agent: "codex")
        async let first = fixture.repository.saveUsageJobIfAbsent(snapshot)
        async let second = fixture.repository.saveUsageJobIfAbsent(snapshot)
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1)
        let jobs = try await fixture.repository.recentClaudeJobs(limit: 10)
        XCTAssertEqual(jobs.count, 1)
        let fresh = RemoteClaudeJob(id: UUID(), prompt: "Usage", workingDirectory: "",
                                   status: .completed, response: "new snapshot", createdAt: now, agent: "codex")
        _ = try await fixture.repository.saveUsageJobIfAbsent(fresh)
        let refreshed = try await fixture.repository.recentClaudeJobs(limit: 10)
        XCTAssertEqual(refreshed.count, 2)
    }

    func testCodexInitializeAcceptsObjectExperimentalCapabilities() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"codex","version":"test"},"capabilities":{"experimental":{"extension":{},"known":"value"},"roots":{"listChanged":true}}}}"#.utf8)
        let normalized = RemoteMCPTransport.normalizeInitialize(raw)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        let decoded = try JSONDecoder().decode(Initialize.Parameters.self,
                                              from: JSONSerialization.data(withJSONObject: params))
        XCTAssertEqual(decoded.capabilities.experimental, ["known": "value"])
        XCTAssertEqual(decoded.capabilities.roots?.listChanged, true)
        let toolRequest = Data(#"{"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Original"}}}"#.utf8)
        XCTAssertEqual(RemoteMCPTransport.normalizeInitialize(toolRequest), toolRequest)
    }
    func testAgentModesAreIndependentAndSurviveRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try await fixture.repository.setRemoteMode(agent: "claude", enabled: true)
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: true)
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: false)
        let path = await fixture.repository.path
        let reopened = try SQLiteApprovalRepository(path: path)
        let modes = try await reopened.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, true)
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, false)
    }

    func testSourceSurvivesAnswerAndDoesNotRouteToOtherRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = RemoteRequestSource(agent: "codex", project: "/projects/one", chat: "chat-one")
        let first = try await fixture.service.create(
            questions: [ApprovalQuestion(id: "answer", question: "First", kind: .singleSelect, options: ["A", "B"])],
            source: source)
        let second = try await fixture.service.create(question: "Second", options: ["A", "B"])
        let answered = try await fixture.service.respond(id: first.id, response: "B")
        XCTAssertEqual(answered.source, source)
        let other = try await fixture.service.approval(id: second.id)
        XCTAssertEqual(other?.status, .pending)
        XCTAssertNil(other?.source)
    }

    func testCodexJobKeepsProjectAndDoesNotReplayAfterRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let job = RemoteClaudeJob(id: UUID(), prompt: "Inspect", workingDirectory: fixture.directory.path,
                                 status: .queued, createdAt: Date(), agent: "codex")
        try await fixture.repository.createClaudeJob(job)
        let claimed = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        XCTAssertEqual(claimed?.agent, "codex")
        XCTAssertEqual(claimed?.workingDirectory, fixture.directory.path)
        try await fixture.repository.requeueInterruptedClaudeJobs()
        let interrupted = try await fixture.repository.claudeJob(id: job.id)
        XCTAssertEqual(interrupted?.status, .failed)
        let replay = try await fixture.repository.claimNextClaudeJob(startedAt: Date())
        XCTAssertNil(replay)
    }

    func testProjectAllowlistRejectsUnregisteredAndTraversalPaths() throws {
        let directory = FileManager.default.temporaryDirectory
        let projects = [RemoteProject(name: "Test", path: directory.path)]
        XCTAssertEqual(try RemoteProject.resolve(directory.path, in: projects),
                       directory.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertThrowsError(try RemoteProject.resolve("/", in: projects))
        XCTAssertThrowsError(try RemoteProject.resolve(directory.appendingPathComponent("..").path, in: projects))
    }

    func testCodexHTTPEnablesModeOnlyAfterValidAuthenticatedMessage() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let jobs = RemoteClaudeJobService(repository: fixture.repository, runner: StubClaudeRunner(),
                                         workingDirectory: fixture.directory.path)
        configureApprovalHTTPRoutes(app: app, service: fixture.service,
                                    authorization: ApprovalHTTPAuthorization(token: fixture.token),
                                    claudeService: jobs, agentRepository: fixture.repository,
                                    projects: [RemoteProject(name: "Test", path: fixture.directory.path)])
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let unauthorized = try await app.sendRequest(.GET, "/api/remote/projects")
        XCTAssertEqual(unauthorized.status, .unauthorized)
        let codexPage = try await app.sendRequest(.GET, "/codex", headers: headers)
        XCTAssertEqual(codexPage.status, .ok)
        XCTAssertTrue(codexPage.body.string.contains(
            "fetch('/codex/usage'"
        ))
        headers.contentType = .json
        let body = byteBuffer(String(decoding: try JSONEncoder().encode(["prompt": "Test", "project": fixture.directory.path]), as: UTF8.self))
        try await fixture.repository.setRemoteMode(agent: "codex", enabled: false)
        try await fixture.repository.setRemoteMode(agent: "claude", enabled: false)
        let rejected = try await app.sendRequest(.POST, "/codex/jobs", body: body)
        XCTAssertEqual(rejected.status, .forbidden)
        let unregistered = try await app.sendRequest(.POST, "/codex/jobs", headers: headers,
            body: byteBuffer(#"{"prompt":"Test","project":"/"}"#))
        XCTAssertEqual(unregistered.status, .badRequest)
        let empty = try await app.sendRequest(.POST, "/codex/jobs", headers: headers,
            body: byteBuffer(String(decoding: try JSONEncoder().encode(["prompt": "   ", "project": fixture.directory.path]), as: UTF8.self)))
        XCTAssertEqual(empty.status, .badRequest)
        let unchanged = try await fixture.repository.remoteModes()
        XCTAssertEqual(unchanged.first { $0.agent == "codex" }?.enabled, false)
        let accepted = try await app.sendRequest(.POST, "/codex/jobs", headers: headers, body: body)
        XCTAssertEqual(accepted.status, .ok)
        let job = try accepted.content.decode(RemoteClaudeJobResponse.self)
        XCTAssertEqual(job.agent, "codex")
        XCTAssertEqual(job.workingDirectory, fixture.directory.resolvingSymlinksInPath().path)
        let modes = try await fixture.repository.remoteModes()
        XCTAssertEqual(modes.first { $0.agent == "codex" }?.enabled, true)
        XCTAssertEqual(modes.first { $0.agent == "claude" }?.enabled, false)
    }

    func testRemoteHistoryClearEndpointIsAgentScopedAndShownOnMobilePage() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let path = fixture.directory.resolvingSymlinksInPath().path
        let now = Date()
        for agent in ["codex", "claude"] {
            try await fixture.repository.createClaudeJob(RemoteClaudeJob(
                id: UUID(), prompt: "Finished", workingDirectory: path, status: .completed,
                response: "Done", createdAt: now, completedAt: now, agent: agent
            ))
        }
        let jobs = RemoteClaudeJobService(
            repository: fixture.repository, runner: StubClaudeRunner(), workingDirectory: path
        )
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(
            app: app, service: fixture.service,
            authorization: ApprovalHTTPAuthorization(token: fixture.token),
            claudeService: jobs, agentRepository: fixture.repository
        )
        defer { Task { try? await app.asyncShutdown() } }

        let unauthorized = try await app.sendRequest(.DELETE, "/codex/jobs")
        XCTAssertEqual(unauthorized.status, .forbidden)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let page = try await app.sendRequest(.GET, "/codex", headers: headers)
        XCTAssertTrue(page.body.string.contains("id=\"clear-history\""))
        XCTAssertTrue(page.body.string.contains("window.setInterval(pollLatestConversation, 4000)"))
        XCTAssertTrue(page.body.string.contains("document.addEventListener('visibilitychange'"))
        XCTAssertTrue(page.body.string.contains("Переключиться на новый чат"))
        XCTAssertTrue(page.body.string.contains("Новый чат доступен"))

        let cleared = try await app.sendRequest(.DELETE, "/codex/jobs", headers: headers)
        XCTAssertEqual(cleared.status, .ok)
        XCTAssertEqual(try cleared.content.decode(RemoteJobHistoryClearResponse.self).cleared, 1)
        let codexJobs = try await app.sendRequest(.GET, "/codex/jobs", headers: headers)
        let claudeJobs = try await app.sendRequest(.GET, "/claude/jobs", headers: headers)
        XCTAssertTrue(try codexJobs.content.decode(RemoteClaudeJobListResponse.self).jobs.isEmpty)
        XCTAssertEqual(try claudeJobs.content.decode(RemoteClaudeJobListResponse.self).jobs.count, 1)
    }
    func testPushMigrationPreservesExistingApprovalsAndClaudeJobs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("approval.sqlite").path
        let approvalID = UUID()
        let jobID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let questions = [
            ApprovalQuestion(
                id: "question-1",
                question: "Preserved?",
                kind: .singleSelect,
                options: ["Yes", "No"]
            )
        ]
        let questionsJSON = String(
            decoding: try JSONEncoder().encode(questions),
            as: UTF8.self
        )
        let legacyDatabase = try DatabaseQueue(path: databasePath)
        try await legacyDatabase.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in [
                "createApprovals",
                "addApprovalKindsAndResponses",
                "addApprovalQuestions",
                "createRemoteClaudeJobs",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
            }
            try db.execute(sql: """
                CREATE TABLE approvals (
                    id TEXT PRIMARY KEY NOT NULL,
                    question TEXT NOT NULL,
                    options_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    response TEXT,
                    created_at DOUBLE NOT NULL,
                    expires_at DOUBLE NOT NULL,
                    answered_at DOUBLE,
                    kind TEXT NOT NULL DEFAULT 'single_select',
                    responses_json TEXT,
                    questions_json TEXT
                )
                """)
            try db.execute(
                sql: """
                INSERT INTO approvals (
                    id, question, options_json, status, created_at, expires_at,
                    kind, responses_json, questions_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    approvalID.uuidString,
                    "Preserved?",
                    #"["Yes","No"]"#,
                    ApprovalStatus.pending.rawValue,
                    now.timeIntervalSince1970,
                    now.addingTimeInterval(300).timeIntervalSince1970,
                    ApprovalKind.singleSelect.rawValue,
                    "[]",
                    questionsJSON,
                ]
            )
            try db.execute(sql: """
                CREATE TABLE remote_claude_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    prompt TEXT NOT NULL,
                    working_directory TEXT NOT NULL,
                    status TEXT NOT NULL,
                    response TEXT,
                    error_message TEXT,
                    session_id TEXT,
                    created_at DOUBLE NOT NULL,
                    started_at DOUBLE,
                    completed_at DOUBLE
                )
                """)
            try db.execute(
                sql: """
                INSERT INTO remote_claude_jobs (
                    id, prompt, working_directory, status, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    jobID.uuidString,
                    "Preserve this job",
                    directory.path,
                    RemoteClaudeJobStatus.queued.rawValue,
                    now.timeIntervalSince1970,
                ]
            )
        }

        let migratedRepository = try SQLiteApprovalRepository(path: databasePath)
        let approval = try await migratedRepository.approval(id: approvalID, now: now)
        let job = try await migratedRepository.claudeJob(id: jobID)

        XCTAssertEqual(approval?.question, "Preserved?")
        XCTAssertEqual(approval?.status, .pending)
        XCTAssertEqual(job?.prompt, "Preserve this job")
        XCTAssertEqual(job?.status, .queued)
    }

    func testCreatePersistsPendingApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let created = try await fixture.service.create(
            question: "Choose an architecture",
            options: ["MVVM", "TCA", "Clean Architecture"]
        )
        let loaded = try await fixture.service.approval(id: created.id)

        XCTAssertEqual(loaded?.id, created.id)
        XCTAssertEqual(loaded?.question, created.question)
        XCTAssertEqual(loaded?.kind, .singleSelect)
        XCTAssertEqual(loaded?.options, created.options)
        XCTAssertEqual(loaded?.status, .pending)
        XCTAssertEqual(loaded?.responses, [])
        XCTAssertEqual(try XCTUnwrap(loaded?.createdAt).timeIntervalSince1970, created.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(loaded?.expiresAt).timeIntervalSince1970, created.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRespondReturnsExactSelectionAndRejectsSecondResponse() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(question: "Choose", options: ["MVVM", "TCA"])

        let answered = try await fixture.service.respond(id: approval.id, response: "TCA")
        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.response, "TCA")

        do {
            _ = try await fixture.service.respond(id: approval.id, response: "MVVM")
            XCTFail("A second response must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .alreadyAnswered(approval.id))
        }
    }

    func testInvalidResponseAndUnknownIDAreRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])

        do {
            _ = try await fixture.service.respond(id: approval.id, response: "C")
            XCTFail("An unknown option must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .invalidResponse)
        }

        let unknownID = UUID()
        do {
            _ = try await fixture.service.respond(id: unknownID, response: "A")
            XCTFail("An unknown approval must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .notFound(unknownID))
        }
    }

    func testMultiSelectReturnsEverySelectionAndRejectsInvalidSets() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(
            question: "Choose integrations",
            options: ["GitHub", "Linear", "Slack"],
            kind: .multiSelect
        )

        do {
            _ = try await fixture.service.respond(
                id: approval.id,
                responses: ["GitHub", "GitHub"]
            )
            XCTFail("Duplicate selections must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .invalidResponse)
        }

        let answered = try await fixture.service.respond(
            id: approval.id,
            responses: ["GitHub", "Slack"]
        )
        XCTAssertEqual(answered.kind, .multiSelect)
        XCTAssertEqual(answered.responses, ["GitHub", "Slack"])
    }

    func testTextResponseIsTrimmedAndValidated() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(
            question: "What should Claude change?",
            options: [],
            kind: .text
        )

        do {
            _ = try await fixture.service.respond(id: approval.id, response: "   ")
            XCTFail("An empty text response must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .emptyResponse)
        }

        let answered = try await fixture.service.respond(
            id: approval.id,
            response: "  Add a compact mode  "
        )
        XCTAssertEqual(answered.kind, .text)
        XCTAssertEqual(answered.response, "Add a compact mode")
        XCTAssertEqual(answered.responses, ["Add a compact mode"])
    }

    func testMixedQuestionRequestIsAnsweredAtomically() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(questions: [
            ApprovalQuestion(
                id: "architecture",
                question: "Choose architecture",
                kind: .singleSelect,
                options: ["MVVM", "TCA"]
            ),
            ApprovalQuestion(
                id: "integrations",
                question: "Choose integrations",
                kind: .multiSelect,
                options: ["GitHub", "Linear", "Slack"]
            ),
            ApprovalQuestion(
                id: "comment",
                question: "Additional notes",
                kind: .text
            )
        ])

        do {
            _ = try await fixture.service.respond(
                id: approval.id,
                answers: [ApprovalAnswer(id: "architecture", responses: ["TCA"])]
            )
            XCTFail("A partial batch response must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .invalidResponse)
        }

        let answered = try await fixture.service.respond(
            id: approval.id,
            answers: [
                ApprovalAnswer(id: "comment", responses: ["  Ship it  "]),
                ApprovalAnswer(id: "integrations", responses: ["GitHub", "Slack"]),
                ApprovalAnswer(id: "architecture", responses: ["TCA"])
            ]
        )

        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.questions.map(\.id), ["architecture", "integrations", "comment"])
        XCTAssertEqual(answered.questions.map(\.responses), [
            ["TCA"], ["GitHub", "Slack"], ["Ship it"]
        ])
    }

    func testTextResponseIsOptionalOnlyInAMixedRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(questions: [
            ApprovalQuestion(
                id: "choice",
                question: "Choose architecture",
                kind: .singleSelect,
                options: ["MVVM", "TCA"]
            ),
            ApprovalQuestion(
                id: "comment",
                question: "Additional notes",
                kind: .text
            )
        ])

        let answered = try await fixture.service.respond(
            id: approval.id,
            answers: [
                ApprovalAnswer(id: "choice", responses: ["TCA"]),
                ApprovalAnswer(id: "comment", responses: [])
            ]
        )

        XCTAssertEqual(answered.questions.map(\.responses), [["TCA"], []])
        XCTAssertNil(answered.questions[1].response)
    }

    func testInvalidApprovalInputIsRejectedBeforePersistence() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.service.create(question: " ", options: ["A", "B"])
            XCTFail("An empty question must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .emptyQuestion)
        }

        do {
            _ = try await fixture.service.create(question: "Choose", options: ["A", "A"])
            XCTFail("Duplicate options must be rejected")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .duplicateOptions)
        }

        let pending = try await fixture.service.pendingApprovals()
        XCTAssertTrue(pending.isEmpty)
    }

    func testWaitReturnsAnswer() async throws {
        let fixture = try makeFixture(pollInterval: .milliseconds(10))
        defer { fixture.remove() }
        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])

        async let waiting = fixture.service.waitForResponse(id: approval.id)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await fixture.service.respond(id: approval.id, response: "B")
        let result = try await waiting

        XCTAssertEqual(result.response, "B")
    }

    func testWaitTimesOutAndPersistsExpiredStatus() async throws {
        let fixture = try makeFixture(timeout: 0.03, pollInterval: .milliseconds(5))
        defer { fixture.remove() }
        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])

        do {
            _ = try await fixture.service.waitForResponse(id: approval.id)
            XCTFail("Waiting should time out")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .timedOut(approval.id))
        }
        let persisted = try await fixture.service.approval(id: approval.id)
        XCTAssertEqual(persisted?.status, .expired)

        do {
            _ = try await fixture.service.respond(id: approval.id, response: "A")
            XCTFail("An expired approval must not accept a response")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .expired(approval.id))
        }
    }

    func testCancellingWaitCancelsPersistedApproval() async throws {
        let fixture = try makeFixture(timeout: 5, pollInterval: .milliseconds(10))
        defer { fixture.remove() }

        let task = Task {
            try await fixture.service.createAndWait(question: "Choose", options: ["A", "B"])
        }

        var pending: [Approval] = []
        for _ in 0..<50 where pending.isEmpty {
            pending = try await fixture.service.pendingApprovals()
            if pending.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let approval = try XCTUnwrap(pending.first)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled wait must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        let persisted = try await fixture.service.approval(id: approval.id)
        XCTAssertEqual(persisted?.status, .cancelled)
    }

    func testOnlyOneConcurrentResponseWins() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for response in ["A", "B"] {
                group.addTask {
                    do {
                        _ = try await fixture.service.respond(id: approval.id, response: response)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await success in group where success {
                count += 1
            }
            return count
        }

        XCTAssertEqual(successes, 1)
        let persisted = try await fixture.service.approval(id: approval.id)
        XCTAssertEqual(persisted?.status, .answered)
    }

    func testMultipleApprovalsCanCompleteIndependently() async throws {
        let fixture = try makeFixture(pollInterval: .milliseconds(10))
        defer { fixture.remove() }
        let first = try await fixture.service.create(question: "First", options: ["A", "B"])
        let second = try await fixture.service.create(question: "Second", options: ["C", "D"])

        async let firstWait = fixture.service.waitForResponse(id: first.id)
        async let secondWait = fixture.service.waitForResponse(id: second.id)
        _ = try await fixture.service.respond(id: second.id, response: "D")
        _ = try await fixture.service.respond(id: first.id, response: "A")
        let results = try await [firstWait, secondWait]

        XCTAssertEqual(results.map(\.response), ["A", "D"])
    }

    func testHTTPAPIRequiresAuthorizationAndCompletesApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }
        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])

        let unauthorized = try await app.sendRequest(.GET, "/approvals/pending")
        XCTAssertEqual(unauthorized.status, .unauthorized)

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let pending = try await app.sendRequest(.GET, "/approvals/pending", headers: headers)
        XCTAssertEqual(pending.status, .ok)
        let pendingBody = try pending.content.decode(ApprovalListResponse.self)
        XCTAssertEqual(pendingBody.approvals.map(\.id), [approval.id])

        let missing = try await app.sendRequest(
            .GET,
            "/approvals/\(UUID().uuidString)",
            headers: headers
        )
        XCTAssertEqual(missing.status, .notFound)

        headers.contentType = .json
        let response = try await app.sendRequest(
            .POST,
            "/approvals/\(approval.id.uuidString)/respond",
            headers: headers,
            body: byteBuffer(#"{"response":"B"}"#)
        )
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(try response.content.decode(ApprovalResponse.self).response, "B")
    }

    func testHTTPAPIAcceptsMultipleSelections() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }
        let approval = try await fixture.service.create(
            question: "Choose",
            options: ["A", "B", "C"],
            kind: .multiSelect
        )

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        headers.contentType = .json
        let response = try await app.sendRequest(
            .POST,
            "/approvals/\(approval.id.uuidString)/respond",
            headers: headers,
            body: byteBuffer(#"{"responses":["A","C"]}"#)
        )

        XCTAssertEqual(response.status, .ok)
        let decoded = try response.content.decode(ApprovalResponse.self)
        XCTAssertEqual(decoded.kind, .multiSelect)
        XCTAssertEqual(decoded.responses, ["A", "C"])
    }

    func testHTTPAPIAcceptsMixedQuestionAnswers() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }
        let approval = try await fixture.service.create(questions: [
            ApprovalQuestion(
                id: "choice",
                question: "Choose",
                kind: .singleSelect,
                options: ["A", "B"]
            ),
            ApprovalQuestion(id: "note", question: "Explain", kind: .text)
        ])

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        headers.contentType = .json
        let response = try await app.sendRequest(
            .POST,
            "/approvals/\(approval.id.uuidString)/respond",
            headers: headers,
            body: byteBuffer(
                #"{"answers":[{"id":"choice","responses":["B"]},{"id":"note","responses":["Because"]}]}"#
            )
        )

        XCTAssertEqual(response.status, .ok)
        let decoded = try response.content.decode(ApprovalResponse.self)
        XCTAssertEqual(decoded.questions.map(\.responses), [["B"], ["Because"]])
    }

    func testApprovalPageDoesNotReplaceAnUnchangedOrDirtyForm() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let response = try await app.sendRequest(.GET, "/approvals", headers: headers)
        let html = try XCTUnwrap(
            response.body.getString(
                at: response.body.readerIndex,
                length: response.body.readableBytes
            )
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(html.contains("if (signature === renderedSignature) return;"))
        XCTAssertTrue(html.contains("if (formDirty && state.querySelector('form')) return;"))
        XCTAssertTrue(html.contains("form.addEventListener('focusin'"))
        XCTAssertTrue(html.contains("form.addEventListener('input'"))
        XCTAssertTrue(html.contains("input.required = textRequired"))
        XCTAssertTrue(html.contains("approval.questions.length === 1"))
        XCTAssertEqual(response.headers.first(name: "Cache-Control"), "no-store, no-cache, must-revalidate")
    }

    func testApprovalPageWrapsLongUnbrokenContentInsideCards() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let response = try await app.sendRequest(.GET, "/approvals", headers: headers)
        let html = try XCTUnwrap(
            response.body.getString(
                at: response.body.readerIndex,
                length: response.body.readableBytes
            )
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(html.contains(".question {"))
        XCTAssertTrue(html.contains("overflow-wrap: anywhere; word-break: break-word;"))
        XCTAssertTrue(html.contains(".option span { min-width: 0; overflow-wrap: anywhere;"))
        XCTAssertTrue(html.contains(".card { min-width: 0; max-width: 100%;"))
    }

    func testRemoteClaudeJobRunsAndPersistsResponse() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let service = RemoteClaudeJobService(
            repository: fixture.repository,
            runner: StubClaudeRunner(),
            workingDirectory: fixture.directory.path
        )
        try await service.start()

        let submitted = try await service.submit(prompt: "  Inspect the project  ")
        XCTAssertEqual(submitted.prompt, "Inspect the project")
        XCTAssertEqual(submitted.status, .queued)

        var completed: RemoteClaudeJob?
        for _ in 0..<100 {
            let current = try await service.job(id: submitted.id)
            if current?.status == .completed {
                completed = current
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(completed?.response, "Done: Inspect the project")
        XCTAssertEqual(completed?.sessionID, "stub-session")
        XCTAssertNotNil(completed?.startedAt)
        XCTAssertNotNil(completed?.completedAt)
    }

    func testRemoteClaudeHTTPPageQueuesRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let claudeService = RemoteClaudeJobService(
            repository: fixture.repository,
            runner: StubClaudeRunner(),
            workingDirectory: fixture.directory.path
        )
        try await claudeService.start()
        let app = try await makeApplication(
            service: fixture.service,
            token: fixture.token,
            claudeService: claudeService
        )
        defer { Task { try? await app.asyncShutdown() } }

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        let page = try await app.sendRequest(.GET, "/claude", headers: headers)
        XCTAssertEqual(page.status, .ok)
        XCTAssertTrue(
            page.body.getString(at: page.body.readerIndex, length: page.body.readableBytes)?
                .contains("Send to Claude") == true
        )
        XCTAssertTrue(page.body.string.contains(
            "fetch('/claude/usage'"
        ))
        XCTAssertTrue(page.body.string.contains(
            "appendJobOutput(article, job, 'job-prompt', job.prompt, 'prompt');"
        ))
        XCTAssertTrue(page.body.string.contains(".job-prompt.output-collapsed { max-height: 12em; }"))

        headers.contentType = .json
        let submitted = try await app.sendRequest(
            .POST,
            "/claude/jobs",
            headers: headers,
            body: byteBuffer(#"{"prompt":"Review Remote"}"#)
        )
        XCTAssertEqual(submitted.status, .ok)
        let submittedJob = try submitted.content.decode(RemoteClaudeJobResponse.self)
        XCTAssertEqual(submittedJob.prompt, "Review Remote")

        var completed = false
        for _ in 0..<100 {
            let response = try await app.sendRequest(.GET, "/claude/jobs", headers: headers)
            let jobs = try response.content.decode(RemoteClaudeJobListResponse.self).jobs
            if jobs.first(where: { $0.id == submittedJob.id })?.status == .completed {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(completed)
    }

    func testLoginCookieSurvivesServerRestartAndRejectsTokenRotation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }

        let loginPage = try await app.sendRequest(.GET, "/login")
        let loginHTML = loginPage.body.string
        XCTAssertTrue(loginHTML.contains("name=\"username\""))
        XCTAssertTrue(loginHTML.contains("value=\"remote\""))
        XCTAssertTrue(loginHTML.contains("autocomplete=\"username\""))
        XCTAssertTrue(loginHTML.contains("autocomplete=\"current-password\""))

        let formHeaders: HTTPHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        let rejected = try await app.sendRequest(
            .POST,
            "/login",
            headers: formHeaders,
            body: byteBuffer("username=remote&token=wrong")
        )
        XCTAssertEqual(rejected.status, .unauthorized)

        let accepted = try await app.sendRequest(
            .POST,
            "/login",
            headers: formHeaders,
            body: byteBuffer("username=remote&token=\(fixture.token)")
        )
        XCTAssertTrue(accepted.status == .seeOther || accepted.status == .temporaryRedirect)
        let cookie = accepted.headers["Set-Cookie"].joined(separator: ";")
        XCTAssertTrue(cookie.contains("remote-auth="))
        XCTAssertTrue(cookie.lowercased().contains("httponly"))
        XCTAssertTrue(cookie.lowercased().contains("samesite=strict"))
        let cookiePair = try XCTUnwrap(cookie.split(separator: ";").first.map(String.init))

        var cookieHeaders = HTTPHeaders()
        cookieHeaders.add(name: .cookie, value: cookiePair)
        let restartedApp = try await makeApplication(
            service: fixture.service,
            token: fixture.token
        )
        let afterRestart = try await restartedApp.sendRequest(
            .GET,
            "/approvals",
            headers: cookieHeaders
        )
        XCTAssertEqual(afterRestart.status, .ok)
        try await restartedApp.asyncShutdown()

        let rotatedTokenApp = try await makeApplication(
            service: fixture.service,
            token: fixture.token + "-rotated"
        )
        let afterRotation = try await rotatedTokenApp.sendRequest(
            .GET,
            "/approvals",
            headers: cookieHeaders
        )
        XCTAssertTrue(afterRotation.status == .seeOther || afterRotation.status == .temporaryRedirect)
        try await rotatedTokenApp.asyncShutdown()
    }

    func testPushSubscriptionUpsertKeepsOneActiveDevice() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let original = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "first-key",
            auth: "first-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone",
            now: now
        )
        let updated = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "updated-key",
            auth: "updated-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone XR",
            now: now.addingTimeInterval(10)
        )

        let subscriptions = try await fixture.repository.activePushSubscriptions()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(original.id, updated.id)
        XCTAssertEqual(subscriptions[0].p256dh, "updated-key")
        XCTAssertEqual(subscriptions[0].deviceLabel, "iPhone XR")
        XCTAssertEqual(original.vapidKeyFingerprint, updated.vapidKeyFingerprint)
        XCTAssertNotEqual(subscriptions[0].vapidKeyFingerprint, "vapid-key")
    }

    func testApprovalCreatesStablePushDeliveryAndLeaseRecoversAfterRestart() async throws {
        let fixture = try makeFixture(timeout: 300)
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone",
            now: now
        )

        let approval = try await fixture.service.create(
            question: "Deploy?",
            options: ["Yes", "No"],
            now: now
        )
        let firstClaim = try await fixture.repository.claimNextPushDelivery(
            now: now,
            leaseDuration: 30
        )
        let first = try XCTUnwrap(firstClaim)

        XCTAssertEqual(first.notification.approvalID, approval.id)
        XCTAssertEqual(
            first.notification.tag,
            "remote-approval-\(approval.id.uuidString.lowercased())"
        )
        XCTAssertFalse(first.notification.body.contains("Deploy"))
        XCTAssertEqual(first.attemptCount, 1)

        let claimBeforeLeaseExpiry = try await fixture.repository.claimNextPushDelivery(
            now: now.addingTimeInterval(20),
            leaseDuration: 30
        )
        XCTAssertNil(claimBeforeLeaseExpiry)
        let recoveredClaim = try await fixture.repository.claimNextPushDelivery(
            now: now.addingTimeInterval(31),
            leaseDuration: 30
        )
        let recovered = try XCTUnwrap(recoveredClaim)
        XCTAssertEqual(recovered.deliveryID, first.deliveryID)
        XCTAssertEqual(recovered.notification.tag, first.notification.tag)
        XCTAssertEqual(recovered.attemptCount, 2)

        try await fixture.repository.completePushDelivery(
            id: recovered.deliveryID,
            now: now.addingTimeInterval(32)
        )
        let claimAfterCompletion = try await fixture.repository.claimNextPushDelivery(
            now: now.addingTimeInterval(60),
            leaseDuration: 30
        )
        XCTAssertNil(claimAfterCompletion)
    }

    func testInvalidPushSubscriptionIsDeactivated() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: nil,
            deviceLabel: nil,
            now: now
        )
        _ = try await fixture.service.create(
            question: "Continue?",
            options: ["Yes", "No"],
            now: now
        )
        let pendingClaim = try await fixture.repository.claimNextPushDelivery(
            now: now,
            leaseDuration: 30
        )
        let claim = try XCTUnwrap(pendingClaim)

        try await fixture.repository.failPushDelivery(
            id: claim.deliveryID,
            now: now,
            error: "gone",
            deactivateSubscription: true
        )

        let subscriptions = try await fixture.repository.activePushSubscriptions()
        XCTAssertTrue(subscriptions.isEmpty)
    }

    func testManuallyDisabledSubscriptionDoesNotReceiveAnOldDeliveryAfterReactivation() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone",
            now: now
        )
        _ = try await fixture.service.create(
            question: "Old request",
            options: ["Yes", "No"],
            now: now
        )
        let leasedDelivery = try await fixture.repository.claimNextPushDelivery(
            now: now,
            leaseDuration: 30
        )
        XCTAssertNotNil(leasedDelivery)

        try await fixture.repository.deactivatePushSubscription(
            endpoint: "https://push.example/device",
            now: now.addingTimeInterval(1)
        )
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "new-device-key",
            auth: "new-device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone",
            now: now.addingTimeInterval(2)
        )

        let oldDelivery = try await fixture.repository.claimNextPushDelivery(
            now: now.addingTimeInterval(60),
            leaseDuration: 30
        )
        XCTAssertNil(oldDelivery)
    }

    func testPushWorkerRetriesThenDeliversWithoutChangingTheNotificationTag() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: "iPhone",
            now: now
        )
        _ = try await fixture.service.create(
            question: "Private question must not enter push payload",
            options: ["Yes", "No"],
            now: now
        )
        let sender = SequencePushSender(results: [.retryable("temporary"), .delivered])
        let worker = RemotePushWorker(
            repository: fixture.repository,
            sender: sender,
            configuration: .init(pollInterval: .milliseconds(10), maximumAttempts: 3)
        )

        let firstAttempt = try await worker.processNext(now: now)
        let beforeRetry = try await worker.processNext(now: now.addingTimeInterval(0.5))
        let secondAttempt = try await worker.processNext(now: now.addingTimeInterval(1))
        let afterDelivery = try await worker.processNext(now: now.addingTimeInterval(2))
        XCTAssertTrue(firstAttempt)
        XCTAssertFalse(beforeRetry)
        XCTAssertTrue(secondAttempt)
        XCTAssertFalse(afterDelivery)

        let notifications = await sender.notifications
        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(notifications[0].tag, notifications[1].tag)
        XCTAssertFalse(notifications[0].body.contains("Private question"))
        let activeSubscriptions = try await fixture.repository.activePushSubscriptions()
        XCTAssertEqual(activeSubscriptions.count, 1)
    }

    func testPushWorkerPermanentFailureDoesNotAffectTheApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: nil,
            now: now
        )
        let approval = try await fixture.service.create(
            question: "Still pending?",
            options: ["Yes", "No"],
            now: now
        )
        let sender = SequencePushSender(results: [.permanentFailure("rejected")])
        let worker = RemotePushWorker(repository: fixture.repository, sender: sender)

        let processed = try await worker.processNext(now: now)
        let persistedApproval = try await fixture.service.approval(id: approval.id)
        XCTAssertTrue(processed)
        XCTAssertEqual(persistedApproval?.status, .pending)
    }

    func testNonPendingApprovalsDoNotProducePushDeliveries() async throws {
        let fixture = try makeFixture(timeout: 1)
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_400)
        _ = try await fixture.repository.upsertPushSubscription(
            endpoint: "https://push.example/device",
            p256dh: "device-key",
            auth: "device-auth",
            applicationServerKey: "vapid-key",
            deviceLabel: nil,
            now: now
        )
        _ = try await fixture.service.create(
            question: "Already expired?",
            options: ["Yes", "No"],
            now: now
        )
        let answered = try await fixture.service.create(
            question: "Already answered?",
            options: ["Yes", "No"],
            now: now
        )
        _ = try await fixture.service.respond(
            id: answered.id,
            response: "Yes",
            now: now.addingTimeInterval(0.1)
        )
        let cancelled = try await fixture.service.create(
            question: "Already cancelled?",
            options: ["Yes", "No"],
            now: now
        )
        try await fixture.service.cancel(
            id: cancelled.id,
            now: now.addingTimeInterval(0.1)
        )

        let claim = try await fixture.repository.claimNextPushDelivery(
            now: now.addingTimeInterval(2),
            leaseDuration: 30
        )
        XCTAssertNil(claim)
    }

    func testPWAResourcesHaveExpectedContentTypesAndScope() async throws {
        XCTAssertNotNil(RemoteBundledResource.url(name: "claude-sessions", extension: "mjs"))
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }

        let manifest = try await app.sendRequest(.GET, "/manifest.webmanifest")
        XCTAssertEqual(manifest.status, .ok)
        XCTAssertEqual(manifest.headers.first(name: .contentType), "application/manifest+json")
        XCTAssertTrue(manifest.body.string.contains("\"name\": \"Remote\""))
        XCTAssertTrue(manifest.body.string.contains("\"scope\": \"/\""))

        let worker = try await app.sendRequest(.GET, "/service-worker.js")
        XCTAssertEqual(worker.status, .ok)
        XCTAssertEqual(worker.headers.first(name: .contentType), "text/javascript; charset=utf-8")
        XCTAssertEqual(worker.headers.first(name: .cacheControl), "no-cache")
        XCTAssertTrue(worker.body.string.contains("remote-approval"))
        XCTAssertTrue(worker.body.string.contains("renotify: false"))

        let icon = try await app.sendRequest(.GET, "/assets/remote-icon.svg")
        XCTAssertEqual(icon.status, .ok)
        XCTAssertEqual(icon.headers.first(name: .contentType), "image/svg+xml")

        for path in [
            "/assets/remote-icon-192.png",
            "/assets/remote-icon-512.png",
            "/assets/apple-touch-icon.png",
        ] {
            let png = try await app.sendRequest(.GET, path)
            XCTAssertEqual(png.status, .ok)
            XCTAssertEqual(png.headers.first(name: .contentType), "image/png")
            XCTAssertGreaterThan(png.body.readableBytes, 100)
        }
    }

    func testVAPIDConfigurationIsStableAcrossSenderRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteVAPIDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("vapid.json")
        let configuration = """
        {
          "contactInformation": "mailto:test@example.com",
          "expirationDuration": 79200,
          "primaryKey": "FniTgSrf0l+BdfeC6LiblKXBbY4LQm0S+4STNCoJI+0=",
          "validityDuration": 72000
        }
        """
        try Data(configuration.utf8).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }

        let firstKey: String
        do {
            firstKey = try RemoteWebPushSender(
                configurationPath: configurationURL.path,
                logger: app.logger
            ).publicKey
        }
        let secondKey = try RemoteWebPushSender(
            configurationPath: configurationURL.path,
            logger: app.logger
        ).publicKey

        XCTAssertEqual(firstKey, secondKey)
        XCTAssertFalse(firstKey.isEmpty)
        XCTAssertFalse(firstKey.contains("FniTgSrf0l"))
    }

    func testHTTPSAuthorizationUsesSecureCookieAndRejectsMissingCSRF() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await Application.make(.testing)
        let authorization = ApprovalHTTPAuthorization(
            token: fixture.token,
            secureCookies: true,
            publicOrigin: URL(string: "https://remote.example")!
        )
        configureApprovalHTTPRoutes(
            app: app,
            service: fixture.service,
            authorization: authorization
        )
        defer { Task { try? await app.asyncShutdown() } }

        let formHeaders: HTTPHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        let accepted = try await app.sendRequest(
            .POST,
            "/login",
            headers: formHeaders,
            body: byteBuffer("username=remote&token=\(fixture.token)")
        )
        let setCookie = accepted.headers["Set-Cookie"].joined(separator: ";")
        XCTAssertTrue(setCookie.lowercased().contains("secure"))
        XCTAssertEqual(accepted.headers.first(name: "X-Content-Type-Options"), nil)
        let cookiePair = try XCTUnwrap(setCookie.split(separator: ";").first.map(String.init))

        let loginPage = try await app.sendRequest(.GET, "/login")
        XCTAssertEqual(loginPage.headers.first(name: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(
            loginPage.headers.first(name: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true
        )

        let approval = try await fixture.service.create(question: "Choose", options: ["A", "B"])
        var cookieHeaders = HTTPHeaders()
        cookieHeaders.add(name: .cookie, value: cookiePair)
        cookieHeaders.contentType = .json
        let rejected = try await app.sendRequest(
            .POST,
            "/approvals/\(approval.id.uuidString)/respond",
            headers: cookieHeaders,
            body: byteBuffer(#"{"response":"A"}"#)
        )
        XCTAssertEqual(rejected.status, .forbidden)

        cookieHeaders.replaceOrAdd(name: "X-CSRF-Token", value: authorization.csrfTokenValue)
        cookieHeaders.replaceOrAdd(name: .origin, value: "https://remote.example")
        let acceptedMutation = try await app.sendRequest(
            .POST,
            "/approvals/\(approval.id.uuidString)/respond",
            headers: cookieHeaders,
            body: byteBuffer(#"{"response":"A"}"#)
        )
        XCTAssertEqual(acceptedMutation.status, .ok)
    }

    func testPushAPIRequiresAuthorizationAndUpsertsSubscription() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(
            app: app,
            service: fixture.service,
            authorization: ApprovalHTTPAuthorization(token: fixture.token),
            push: RemotePushHTTPContext(
                repository: fixture.repository,
                publicKey: "cccccccccccccccccccccccccccccccc"
            )
        )
        defer { Task { try? await app.asyncShutdown() } }

        let publicKey = try await app.sendRequest(.GET, "/api/push/vapid-public-key")
        XCTAssertEqual(publicKey.status, .ok)
        XCTAssertEqual(
            try publicKey.content.decode(RemotePushPublicKeyResponse.self).publicKey,
            "cccccccccccccccccccccccccccccccc"
        )
        let unauthorized = try await app.sendRequest(.GET, "/api/push/status")
        XCTAssertEqual(unauthorized.status, .unauthorized)

        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: fixture.token)
        headers.contentType = .json
        let subscription = """
        {
          "endpoint": "https://push.example/device",
          "keys": {
            "p256dh": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "auth": "bbbbbbbbbbbbbbbb"
          },
          "applicationServerKey": "cccccccccccccccccccccccccccccccc",
          "deviceLabel": "iPhone"
        }
        """
        let outdatedSubscription = subscription.replacingOccurrences(
            of: "cccccccccccccccccccccccccccccccc",
            with: "dddddddddddddddddddddddddddddddd"
        )
        let outdated = try await app.sendRequest(
            .POST,
            "/api/push/subscribe",
            headers: headers,
            body: byteBuffer(outdatedSubscription)
        )
        XCTAssertEqual(outdated.status, .conflict)
        let subscriptionsAfterMismatch = try await fixture.repository.activePushSubscriptions()
        XCTAssertTrue(subscriptionsAfterMismatch.isEmpty)

        let registered = try await app.sendRequest(
            .POST,
            "/api/push/subscribe",
            headers: headers,
            body: byteBuffer(subscription)
        )
        XCTAssertEqual(registered.status, .ok)
        XCTAssertEqual(
            try registered.content.decode(RemotePushStatusResponse.self).activeSubscriptions,
            1
        )

        let disabled = try await app.sendRequest(
            .DELETE,
            "/api/push/subscribe",
            headers: headers,
            body: byteBuffer(#"{"endpoint":"https://push.example/device"}"#)
        )
        XCTAssertEqual(disabled.status, .ok)
        XCTAssertEqual(
            try disabled.content.decode(RemotePushStatusResponse.self).activeSubscriptions,
            0
        )
        let disabledAgain = try await app.sendRequest(
            .DELETE,
            "/api/push/subscribe",
            headers: headers,
            body: byteBuffer(#"{"endpoint":"https://push.example/device"}"#)
        )
        XCTAssertEqual(disabledAgain.status, .ok)
        XCTAssertEqual(
            try disabledAgain.content.decode(RemotePushStatusResponse.self).activeSubscriptions,
            0
        )
    }

    private func makeFixture(
        timeout: TimeInterval = 5,
        pollInterval: Duration = .milliseconds(20)
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteTests-\(UUID().uuidString)", isDirectory: true)
        let repository = try SQLiteApprovalRepository(
            path: directory.appendingPathComponent("approval.sqlite").path
        )
        return Fixture(
            service: ApprovalService(
                repository: repository,
                timeout: timeout,
                pollInterval: pollInterval
            ),
            repository: repository,
            directory: directory,
            token: "test-token-that-is-at-least-32-characters"
        )
    }

    private func makeApplication(
        service: ApprovalService,
        token: String,
        claudeService: RemoteClaudeJobService? = nil
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        configureApprovalHTTPRoutes(
            app: app,
            service: service,
            authorization: ApprovalHTTPAuthorization(token: token),
            claudeService: claudeService
        )
        return app
    }

    private func byteBuffer(_ string: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }
}

private actor TestUsageReader: RemoteUsageReading {
    private(set) var calls = 0
    func read(agent: String) async throws -> RemoteUsageReport {
        calls += 1
        return RemoteUsageReport(text: "fixture usage")
    }
}

private struct TestConversationReader: RemoteConversationsReading {
    let rows: [RemoteConversation]
    func list(agent: String, projects: [String], knownRemoteIDs: Set<String>) async throws -> [RemoteConversation] { rows }
}

private struct Fixture: Sendable {
    let service: ApprovalService
    let repository: SQLiteApprovalRepository
    let directory: URL
    let token: String

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct StubClaudeRunner: RemoteClaudeJobRunning {
    func run(job: RemoteClaudeJob) async throws -> RemoteClaudeJobResult {
        try await Task.sleep(for: .milliseconds(10))
        return RemoteClaudeJobResult(
            response: "Done: \(job.prompt)",
            sessionID: job.sessionID ?? "stub-session"
        )
    }
}

private actor SequencePushSender: RemotePushSending {
    private var results: [RemotePushSendResult]
    private(set) var notifications: [RemotePushNotification] = []

    init(results: [RemotePushSendResult]) {
        self.results = results
    }

    func send(
        _ notification: RemotePushNotification,
        to subscription: RemotePushSubscription
    ) async -> RemotePushSendResult {
        notifications.append(notification)
        guard !results.isEmpty else {
            return .permanentFailure("No test result was configured.")
        }
        return results.removeFirst()
    }
}
