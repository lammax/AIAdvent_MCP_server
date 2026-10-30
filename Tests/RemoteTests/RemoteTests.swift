import Foundation
import XCTest
import XCTVapor
@testable import Shared

final class RemoteTests: XCTestCase {
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
        XCTAssertEqual(loaded?.options, created.options)
        XCTAssertEqual(loaded?.status, .pending)
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

    func testLoginRejectsWrongTokenAndCreatesHTTPOnlySessionForCorrectToken() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = try await makeApplication(service: fixture.service, token: fixture.token)
        defer { Task { try? await app.asyncShutdown() } }

        let formHeaders: HTTPHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        let rejected = try await app.sendRequest(
            .POST,
            "/login",
            headers: formHeaders,
            body: byteBuffer("token=wrong")
        )
        XCTAssertEqual(rejected.status, .unauthorized)

        let accepted = try await app.sendRequest(
            .POST,
            "/login",
            headers: formHeaders,
            body: byteBuffer("token=\(fixture.token)")
        )
        XCTAssertTrue(accepted.status == .seeOther || accepted.status == .temporaryRedirect)
        let cookie = accepted.headers["Set-Cookie"].joined(separator: ";")
        XCTAssertTrue(cookie.contains("remote-session="))
        XCTAssertTrue(cookie.lowercased().contains("httponly"))
        XCTAssertTrue(cookie.lowercased().contains("samesite=strict"))
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
            directory: directory,
            token: "test-token-that-is-at-least-32-characters"
        )
    }

    private func makeApplication(service: ApprovalService, token: String) async throws -> Application {
        let app = try await Application.make(.testing)
        app.sessions.use(.memory)
        app.sessions.configuration = .init(cookieName: "remote-session") { sessionID in
            HTTPCookies.Value(
                string: sessionID.string,
                expires: Date(timeIntervalSinceNow: 3_600),
                maxAge: 3_600,
                domain: nil,
                path: "/",
                isSecure: false,
                isHTTPOnly: true,
                sameSite: .strict
            )
        }
        app.middleware.use(app.sessions.middleware)
        configureApprovalHTTPRoutes(
            app: app,
            service: service,
            authorization: ApprovalHTTPAuthorization(token: token)
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
    let directory: URL
    let token: String

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
