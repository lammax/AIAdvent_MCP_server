import Foundation
import GRDB
import XCTest
import XCTVapor
@testable import Shared

final class RemoteTests: XCTestCase {
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
            sessionID: "stub-session"
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
