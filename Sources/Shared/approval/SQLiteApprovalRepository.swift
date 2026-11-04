import Foundation
import CryptoKit
import GRDB

public actor SQLiteApprovalRepository: ApprovalRepository, RemoteClaudeJobRepository,
    RemotePushRepository
{
    private let dbQueue: DatabaseQueue
    public let path: String

    public init(path: String = SQLiteApprovalRepository.defaultDatabasePath()) throws {
        self.path = NSString(string: path).expandingTildeInPath
        let databaseURL = URL(fileURLWithPath: self.path)
        let directoryURL = databaseURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: self.path, configuration: configuration)
        try Self.makeMigrator().migrate(dbQueue)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: self.path
        )
    }

    public static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Remote", isDirectory: true)
            .appendingPathComponent("approval.sqlite")
            .path
    }

    public func setRemoteMode(agent: String, enabled: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO remote_agent_modes (agent, enabled) VALUES (?, ?) ON CONFLICT(agent) DO UPDATE SET enabled = excluded.enabled WHERE remote_agent_modes.enabled != excluded.enabled",
                           arguments: [agent, enabled])
        }
    }

    public func remoteModes() async throws -> [RemoteAgentMode] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM remote_agent_modes ORDER BY agent").map {
                RemoteAgentMode(agent: $0["agent"], enabled: $0["enabled"])
            }
        }
    }

    public func create(_ approval: Approval) async throws {
        let optionsJSON = try Self.encodeOptions(approval.options)
        let responsesJSON = try Self.encodeOptions(approval.responses)
        let questionsJSON = try Self.encode(approval.questions)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO approvals (
                    id, question, kind, options_json, status, response, responses_json, questions_json,
                    created_at, expires_at, answered_at, source_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    approval.id.uuidString,
                    approval.question,
                    approval.kind.rawValue,
                    optionsJSON,
                    approval.status.rawValue,
                    approval.response,
                    responsesJSON,
                    questionsJSON,
                    approval.createdAt.timeIntervalSince1970,
                    approval.expiresAt.timeIntervalSince1970,
                    approval.answeredAt?.timeIntervalSince1970,
                    try approval.source.map(Self.encode)
                ]
            )
            let eventID = UUID()
            try db.execute(
                sql: """
                INSERT INTO remote_push_outbox (
                    id, event_key, kind, approval_id, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    eventID.uuidString,
                    "approval.created:\(approval.id.uuidString.lowercased())",
                    RemotePushEventKind.approvalCreated.rawValue,
                    approval.id.uuidString,
                    approval.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }

    public func approval(id: UUID, now: Date) async throws -> Approval? {
        try await dbQueue.write { db in
            try Self.expirePendingApprovals(db: db, now: now)
            return try Self.fetchApproval(db: db, id: id)
        }
    }

    public func pendingApprovals(now: Date) async throws -> [Approval] {
        try await dbQueue.write { db in
            try Self.expirePendingApprovals(db: db, now: now)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM approvals
                WHERE status = ?
                ORDER BY created_at ASC
                """,
                arguments: [ApprovalStatus.pending.rawValue]
            )
            return try rows.map(Self.decodeApproval)
        }
    }

    public func respond(id: UUID, answers: [ApprovalAnswer], now: Date) async throws -> Approval {
        try await dbQueue.write { db in
            try Self.expirePendingApprovals(db: db, now: now)
            guard let existing = try Self.fetchApproval(db: db, id: id) else {
                throw ApprovalError.notFound(id)
            }

            switch existing.status {
            case .answered:
                throw ApprovalError.alreadyAnswered(id)
            case .expired:
                throw ApprovalError.expired(id)
            case .cancelled:
                throw ApprovalError.cancelled(id)
            case .pending:
                break
            }

            let answeredQuestions = try Self.applying(answers: answers, to: existing.questions)
            let firstResponses = answeredQuestions.first?.responses ?? []
            let responsesJSON = try Self.encodeOptions(firstResponses)
            let questionsJSON = try Self.encode(answeredQuestions)

            try db.execute(
                sql: """
                UPDATE approvals
                SET status = ?, response = ?, responses_json = ?, questions_json = ?, answered_at = ?
                WHERE id = ? AND status = ? AND expires_at > ?
                """,
                arguments: [
                    ApprovalStatus.answered.rawValue,
                    firstResponses.first,
                    responsesJSON,
                    questionsJSON,
                    now.timeIntervalSince1970,
                    id.uuidString,
                    ApprovalStatus.pending.rawValue,
                    now.timeIntervalSince1970
                ]
            )
            guard db.changesCount == 1,
                  let updated = try Self.fetchApproval(db: db, id: id)
            else {
                throw ApprovalError.expired(id)
            }
            return updated
        }
    }

    public func cancel(id: UUID, now: Date) async throws {
        try await dbQueue.write { db in
            try Self.expirePendingApprovals(db: db, now: now)
            guard try Self.fetchApproval(db: db, id: id) != nil else {
                throw ApprovalError.notFound(id)
            }
            try db.execute(
                sql: """
                UPDATE approvals
                SET status = ?
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    ApprovalStatus.cancelled.rawValue,
                    id.uuidString,
                    ApprovalStatus.pending.rawValue
                ]
            )
        }
    }

    public func cancelPendingApprovals(taskID: UUID, now: Date) async throws {
        try await dbQueue.write { db in
            try Self.expirePendingApprovals(db: db, now: now)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, source_json FROM approvals WHERE status = ? AND source_json IS NOT NULL",
                arguments: [ApprovalStatus.pending.rawValue]
            )
            for row in rows {
                let sourceJSON: String = row["source_json"]
                guard let source = try? Self.decode(RemoteRequestSource.self, from: sourceJSON),
                      source.taskID == taskID else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE approvals SET status = ? WHERE id = ? AND status = ?",
                    arguments: [ApprovalStatus.cancelled.rawValue, id, ApprovalStatus.pending.rawValue]
                )
            }
        }
    }

    public func createClaudeJob(_ job: RemoteClaudeJob) async throws {
        try await insertClaudeJob(job, ifAbsent: false)
    }

    public func createWebJob(_ job: RemoteClaudeJob, remoteEnabled: Bool) async throws {
        try await insertClaudeJob(job, ifAbsent: false, remoteEnabled: remoteEnabled)
    }

    /// A cached usage snapshot has one UUID, including simultaneous/retried HTTP requests.
    public func saveUsageJobIfAbsent(_ job: RemoteClaudeJob) async throws -> RemoteClaudeJob {
        try await insertClaudeJob(job, ifAbsent: true)
        guard let saved = try await claudeJob(id: job.id) else { throw ApprovalPersistenceError.corruptRecord }
        return saved
    }

    private func insertClaudeJob(_ job: RemoteClaudeJob, ifAbsent: Bool, remoteEnabled: Bool? = nil) async throws {
        try await dbQueue.write { db in
            if let remoteEnabled {
                try db.execute(sql: "INSERT INTO remote_agent_modes (agent, enabled) VALUES (?, ?) ON CONFLICT(agent) DO UPDATE SET enabled = excluded.enabled WHERE remote_agent_modes.enabled != excluded.enabled",
                               arguments: [job.agent, remoteEnabled])
            }
            try db.execute(
                sql: """
                INSERT INTO remote_claude_jobs (
                    id, prompt, working_directory, status, response, error_message, session_id,
                    created_at, started_at, completed_at, agent
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                \(ifAbsent ? "ON CONFLICT(id) DO UPDATE SET history_hidden_at = NULL" : "")
                """,
                arguments: [
                    job.id.uuidString,
                    job.prompt,
                    job.workingDirectory,
                    job.status.rawValue,
                    job.response,
                    job.errorMessage,
                    job.sessionID,
                    job.createdAt.timeIntervalSince1970,
                    job.startedAt?.timeIntervalSince1970,
                    job.completedAt?.timeIntervalSince1970,
                    job.agent,
                ]
            )
        }
    }

    public func claudeJob(id: UUID) async throws -> RemoteClaudeJob? {
        try await dbQueue.read { db in
            try Self.fetchClaudeJob(db: db, id: id)
        }
    }

    public func conversationSessionIDs(agent: String, project: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM remote_claude_jobs WHERE agent = ? AND working_directory = ? AND session_id IS NOT NULL AND prompt != 'Usage'",
                                arguments: [agent, project])
        }
    }

    public func retiredConversationSessionIDs(agent: String, project: String) async throws -> Set<String> {
        try await dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT session_id FROM remote_retired_conversations WHERE agent = ? AND project = ?",
                arguments: [agent, project]
            ))
        }
    }

    public func deferBusyConversation(id: UUID, until: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE remote_claude_jobs SET status = 'queued', started_at = NULL, not_before = ?, error_message = ? WHERE id = ? AND status = 'running'",
                           arguments: [until.timeIntervalSince1970, RemoteConversationError.busy.localizedDescription, id.uuidString])
        }
    }

    public func markCodexMessageQueued(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE remote_claude_jobs SET message_queued_at = ? WHERE id = ? AND status = 'running' AND agent = 'codex' AND message_queued_at IS NULL",
                arguments: [at.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    public func markCodexConversationRotated(
        jobID: UUID,
        project: String,
        retiredSessionID: String,
        successorSessionID: String,
        at: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE remote_claude_jobs SET session_id = ? WHERE id = ? AND status = 'running' AND agent = 'codex'",
                arguments: [successorSessionID, jobID.uuidString]
            )
            guard db.changesCount == 1 else { throw ApprovalPersistenceError.corruptRecord }
            try db.execute(
                sql: """
                INSERT INTO remote_retired_conversations (agent, project, session_id, successor_session_id, retired_at)
                VALUES ('codex', ?, ?, ?, ?)
                ON CONFLICT(agent, session_id) DO UPDATE SET
                    project = excluded.project,
                    successor_session_id = excluded.successor_session_id,
                    retired_at = excluded.retired_at
                """,
                arguments: [project, retiredSessionID, successorSessionID, at.timeIntervalSince1970]
            )
        }
    }

    public func recentClaudeJobs(limit: Int) async throws -> [RemoteClaudeJob] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM remote_claude_jobs
                WHERE history_hidden_at IS NULL
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try rows.map(Self.decodeClaudeJob)
        }
    }

    public func hideFinishedClaudeJobs(agent: String, at: Date) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET history_hidden_at = ?
                WHERE agent = ?
                  AND history_hidden_at IS NULL
                  AND status IN ('completed', 'failed', 'cancelled')
                """,
                arguments: [at.timeIntervalSince1970, agent]
            )
            return db.changesCount
        }
    }

    public func requestClaudeJobCancellation(id: UUID, at: Date) async throws -> RemoteClaudeJob {
        try await dbQueue.write { db in
            guard let current = try Self.fetchClaudeJob(db: db, id: id) else {
                throw ApprovalPersistenceError.notFound
            }
            guard current.status == .queued || current.status == .running else {
                if current.status == .cancelled { return current }
                throw RemoteClaudeJobError.notCancellable
            }
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, error_message = ?, completed_at = ?, not_before = NULL
                WHERE id = ? AND status IN (?, ?)
                """,
                arguments: [
                    RemoteClaudeJobStatus.cancelled.rawValue,
                    "Stopped by user.",
                    at.timeIntervalSince1970,
                    id.uuidString,
                    RemoteClaudeJobStatus.queued.rawValue,
                    RemoteClaudeJobStatus.running.rawValue,
                ]
            )
            guard let updated = try Self.fetchClaudeJob(db: db, id: id) else {
                throw ApprovalPersistenceError.corruptRecord
            }
            return updated
        }
    }

    public func cancelClaudeJob(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, error_message = ?, completed_at = ?, not_before = NULL
                WHERE id = ? AND status IN (?, ?)
                """,
                arguments: [
                    RemoteClaudeJobStatus.cancelled.rawValue,
                    "Stopped by user.",
                    at.timeIntervalSince1970,
                    id.uuidString,
                    RemoteClaudeJobStatus.queued.rawValue,
                    RemoteClaudeJobStatus.running.rawValue,
                ]
            )
        }
    }

    public func requeueInterruptedClaudeJobs() async throws {
        try await dbQueue.write { db in
            // A queued Codex message has a durable provider-side identity in its prompt and
            // must only resume result collection. An older exec task may already have changed
            // files, so never replay one that was interrupted before the queue receipt existed.
            try db.execute(sql: "UPDATE remote_claude_jobs SET status = 'queued', started_at = NULL WHERE status = 'running' AND agent = 'codex' AND message_queued_at IS NOT NULL")
            try db.execute(sql: "UPDATE remote_claude_jobs SET status = 'failed', error_message = 'Interrupted by server restart; inspect changes before retrying.' WHERE status = 'running' AND agent = 'codex' AND message_queued_at IS NULL")
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, started_at = NULL
                WHERE status = ? AND agent = 'claude'
                """,
                arguments: [
                    RemoteClaudeJobStatus.queued.rawValue,
                    RemoteClaudeJobStatus.running.rawValue,
                ]
            )
        }
    }

    public func claimNextClaudeJob(startedAt: Date) async throws -> RemoteClaudeJob? {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM remote_claude_jobs
                WHERE status = ? AND (not_before IS NULL OR not_before <= ?)
                ORDER BY created_at ASC
                LIMIT 1
                """,
                arguments: [RemoteClaudeJobStatus.queued.rawValue, startedAt.timeIntervalSince1970]
            ) else {
                return nil
            }
            let idString: String = row["id"]
            guard let id = UUID(uuidString: idString) else {
                throw ApprovalPersistenceError.corruptRecord
            }
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, started_at = ?
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    RemoteClaudeJobStatus.running.rawValue,
                    startedAt.timeIntervalSince1970,
                    id.uuidString,
                    RemoteClaudeJobStatus.queued.rawValue,
                ]
            )
            guard db.changesCount == 1 else { return nil }
            return try Self.fetchClaudeJob(db: db, id: id)
        }
    }

    public func completeClaudeJob(
        id: UUID,
        result: RemoteClaudeJobResult,
        completedAt: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, response = ?, error_message = NULL, session_id = ?, completed_at = ?
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    RemoteClaudeJobStatus.completed.rawValue,
                    result.response,
                    result.sessionID,
                    completedAt.timeIntervalSince1970,
                    id.uuidString,
                    RemoteClaudeJobStatus.running.rawValue,
                ]
            )
        }
    }

    public func failClaudeJob(id: UUID, message: String, completedAt: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE remote_claude_jobs
                SET status = ?, error_message = ?, completed_at = ?
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    RemoteClaudeJobStatus.failed.rawValue,
                    message,
                    completedAt.timeIntervalSince1970,
                    id.uuidString,
                    RemoteClaudeJobStatus.running.rawValue,
                ]
            )
        }
    }

    public func upsertPushSubscription(
        endpoint: String,
        p256dh: String,
        auth: String,
        applicationServerKey: String?,
        deviceLabel: String?,
        now: Date
    ) async throws -> RemotePushSubscription {
        try await dbQueue.write { db in
            let id = UUID()
            let vapidKeyFingerprint = applicationServerKey.map(Self.vapidKeyFingerprint)
            try db.execute(
                sql: """
                INSERT INTO remote_push_subscriptions (
                    id, endpoint, p256dh, auth, application_server_key,
                    vapid_key_fingerprint, device_label,
                    active, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(endpoint) DO UPDATE SET
                    p256dh = excluded.p256dh,
                    auth = excluded.auth,
                    application_server_key = excluded.application_server_key,
                    vapid_key_fingerprint = excluded.vapid_key_fingerprint,
                    device_label = excluded.device_label,
                    active = 1,
                    updated_at = excluded.updated_at,
                    last_error = NULL
                """,
                arguments: [
                    id.uuidString,
                    endpoint,
                    p256dh,
                    auth,
                    applicationServerKey,
                    vapidKeyFingerprint,
                    deviceLabel,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM remote_push_subscriptions WHERE endpoint = ?",
                arguments: [endpoint]
            ) else {
                throw ApprovalPersistenceError.corruptRecord
            }
            return try Self.decodePushSubscription(row)
        }
    }

    public func deactivatePushSubscription(endpoint: String, now: Date) async throws {
        try await dbQueue.write { db in
            let eventIDs = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT d.event_id
                FROM remote_push_deliveries d
                JOIN remote_push_subscriptions s ON s.id = d.subscription_id
                WHERE s.endpoint = ?
                  AND d.status IN ('pending', 'retry', 'leased')
                """,
                arguments: [endpoint]
            )
            try db.execute(
                sql: """
                UPDATE remote_push_subscriptions
                SET active = 0, updated_at = ?
                WHERE endpoint = ?
                """,
                arguments: [now.timeIntervalSince1970, endpoint]
            )
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'failed', lease_until = NULL, last_error = 'subscription disabled'
                WHERE subscription_id IN (
                    SELECT id FROM remote_push_subscriptions WHERE endpoint = ?
                )
                  AND status IN ('pending', 'retry', 'leased')
                """,
                arguments: [endpoint]
            )
            for eventID in eventIDs {
                try Self.completeOutboxIfTerminal(db: db, eventID: eventID, now: now)
            }
        }
    }

    public func activePushSubscriptions() async throws -> [RemotePushSubscription] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM remote_push_subscriptions
                WHERE active = 1
                ORDER BY created_at ASC
                """
            ).map(Self.decodePushSubscription)
        }
    }

    public func enqueueTestPush(now: Date) async throws -> UUID {
        try await dbQueue.write { db in
            let id = UUID()
            try db.execute(
                sql: """
                INSERT INTO remote_push_outbox (
                    id, event_key, kind, approval_id, created_at
                ) VALUES (?, ?, ?, NULL, ?)
                """,
                arguments: [
                    id.uuidString,
                    "test:\(id.uuidString.lowercased())",
                    RemotePushEventKind.test.rawValue,
                    now.timeIntervalSince1970,
                ]
            )
            return id
        }
    }

    public func claimNextPushDelivery(
        now: Date,
        leaseDuration: TimeInterval
    ) async throws -> RemotePushDeliveryClaim? {
        try await dbQueue.write { db in
            let staleApprovalArguments: StatementArguments = [
                RemotePushEventKind.approvalCreated.rawValue,
                ApprovalStatus.pending.rawValue,
                now.timeIntervalSince1970,
            ]
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'failed', lease_until = NULL,
                    last_error = 'approval is no longer pending'
                WHERE status IN ('pending', 'retry', 'leased')
                  AND event_id IN (
                    SELECT e.id
                    FROM remote_push_outbox e
                    JOIN approvals a ON a.id = e.approval_id
                    WHERE e.kind = ? AND (a.status <> ? OR a.expires_at <= ?)
                  )
                """,
                arguments: staleApprovalArguments
            )
            try db.execute(
                sql: """
                UPDATE remote_push_outbox
                SET materialized_at = COALESCE(materialized_at, ?),
                    completed_at = COALESCE(completed_at, ?)
                WHERE kind = ?
                  AND id IN (
                    SELECT e.id
                    FROM remote_push_outbox e
                    JOIN approvals a ON a.id = e.approval_id
                    WHERE e.kind = ? AND (a.status <> ? OR a.expires_at <= ?)
                  )
                """,
                arguments: [
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    RemotePushEventKind.approvalCreated.rawValue,
                    RemotePushEventKind.approvalCreated.rawValue,
                    ApprovalStatus.pending.rawValue,
                    now.timeIntervalSince1970,
                ]
            )
            if let event = try Row.fetchOne(
                db,
                sql: """
                SELECT id FROM remote_push_outbox
                WHERE materialized_at IS NULL AND completed_at IS NULL
                ORDER BY created_at ASC
                LIMIT 1
                """
            ) {
                let eventID: String = event["id"]
                let subscriptionRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id FROM remote_push_subscriptions WHERE active = 1"
                )
                for subscriptionRow in subscriptionRows {
                    let subscriptionID: String = subscriptionRow["id"]
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO remote_push_deliveries (
                            id, event_id, subscription_id, status, attempt_count,
                            next_attempt_at, created_at
                        ) VALUES (?, ?, ?, 'pending', 0, ?, ?)
                        """,
                        arguments: [
                            UUID().uuidString,
                            eventID,
                            subscriptionID,
                            now.timeIntervalSince1970,
                            now.timeIntervalSince1970,
                        ]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE remote_push_outbox
                    SET materialized_at = ?, completed_at = CASE
                        WHEN NOT EXISTS (
                            SELECT 1 FROM remote_push_deliveries WHERE event_id = ?
                        ) THEN ? ELSE completed_at END
                    WHERE id = ?
                    """,
                    arguments: [
                        now.timeIntervalSince1970,
                        eventID,
                        now.timeIntervalSince1970,
                        eventID,
                    ]
                )
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    d.id AS delivery_id,
                    d.attempt_count,
                    e.id AS event_id,
                    e.kind,
                    e.approval_id,
                    s.*
                FROM remote_push_deliveries d
                JOIN remote_push_outbox e ON e.id = d.event_id
                JOIN remote_push_subscriptions s ON s.id = d.subscription_id
                WHERE s.active = 1
                  AND e.completed_at IS NULL
                  AND d.next_attempt_at <= ?
                  AND (
                    d.status IN ('pending', 'retry')
                    OR (d.status = 'leased' AND d.lease_until <= ?)
                  )
                ORDER BY e.created_at ASC, d.created_at ASC
                LIMIT 1
                """,
                arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970]
            ) else {
                return nil
            }

            let deliveryIDString: String = row["delivery_id"]
            let eventIDString: String = row["event_id"]
            let eventKindString: String = row["kind"]
            let approvalIDString: String? = row["approval_id"]
            guard let deliveryID = UUID(uuidString: deliveryIDString),
                  let eventID = UUID(uuidString: eventIDString),
                  let eventKind = RemotePushEventKind(rawValue: eventKindString)
            else {
                throw ApprovalPersistenceError.corruptRecord
            }
            let attemptCount: Int = row["attempt_count"]
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'leased', attempt_count = attempt_count + 1, lease_until = ?
                WHERE id = ?
                """,
                arguments: [
                    now.addingTimeInterval(leaseDuration).timeIntervalSince1970,
                    deliveryIDString,
                ]
            )

            let approvalID = approvalIDString.flatMap(UUID.init(uuidString:))
            let destination: String
            let title: String
            let body: String
            let tag: String
            switch eventKind {
            case .approvalCreated:
                guard let approvalID else { throw ApprovalPersistenceError.corruptRecord }
                destination = "/approvals?approval=\(approvalID.uuidString.lowercased())"
                title = "Remote"
                body = "A new approval is waiting."
                tag = "remote-approval-\(approvalID.uuidString.lowercased())"
            case .test:
                destination = "/approvals"
                title = "Remote"
                body = "Notifications are working."
                tag = "remote-test-\(eventID.uuidString.lowercased())"
            }

            return RemotePushDeliveryClaim(
                deliveryID: deliveryID,
                subscription: try Self.decodePushSubscription(row),
                notification: RemotePushNotification(
                    eventID: eventID,
                    eventKind: eventKind,
                    approvalID: approvalID,
                    destination: destination,
                    title: title,
                    body: body,
                    tag: tag
                ),
                attemptCount: attemptCount + 1
            )
        }
    }

    public func completePushDelivery(id: UUID, now: Date) async throws {
        try await dbQueue.write { db in
            guard let delivery = try Row.fetchOne(
                db,
                sql: "SELECT event_id, subscription_id FROM remote_push_deliveries WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }
            let eventID: String = delivery["event_id"]
            let subscriptionID: String = delivery["subscription_id"]
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'delivered', lease_until = NULL, last_error = NULL, delivered_at = ?
                WHERE id = ?
                """,
                arguments: [now.timeIntervalSince1970, id.uuidString]
            )
            try db.execute(
                sql: """
                UPDATE remote_push_subscriptions
                SET last_success_at = ?, last_error = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    subscriptionID,
                ]
            )
            try Self.completeOutboxIfTerminal(db: db, eventID: eventID, now: now)
        }
    }

    public func retryPushDelivery(
        id: UUID,
        now: Date,
        nextAttemptAt: Date,
        error: String?
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'retry', lease_until = NULL, next_attempt_at = ?, last_error = ?
                WHERE id = ?
                """,
                arguments: [nextAttemptAt.timeIntervalSince1970, error, id.uuidString]
            )
        }
    }

    public func failPushDelivery(
        id: UUID,
        now: Date,
        error: String?,
        deactivateSubscription: Bool
    ) async throws {
        try await dbQueue.write { db in
            guard let delivery = try Row.fetchOne(
                db,
                sql: "SELECT event_id, subscription_id FROM remote_push_deliveries WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }
            let eventID: String = delivery["event_id"]
            let subscriptionID: String = delivery["subscription_id"]
            try db.execute(
                sql: """
                UPDATE remote_push_deliveries
                SET status = 'failed', lease_until = NULL, last_error = ?
                WHERE id = ?
                """,
                arguments: [error, id.uuidString]
            )
            try db.execute(
                sql: """
                UPDATE remote_push_subscriptions
                SET active = CASE WHEN ? THEN 0 ELSE active END,
                    last_error = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [
                    deactivateSubscription,
                    error,
                    now.timeIntervalSince1970,
                    subscriptionID,
                ]
            )
            try Self.completeOutboxIfTerminal(db: db, eventID: eventID, now: now)
        }
    }

    private static func completeOutboxIfTerminal(
        db: Database,
        eventID: String,
        now: Date
    ) throws {
        try db.execute(
            sql: """
            UPDATE remote_push_outbox
            SET completed_at = ?
            WHERE id = ?
              AND NOT EXISTS (
                SELECT 1 FROM remote_push_deliveries
                WHERE event_id = ? AND status IN ('pending', 'retry', 'leased')
              )
            """,
            arguments: [now.timeIntervalSince1970, eventID, eventID]
        )
    }

    private static func decodePushSubscription(_ row: Row) throws -> RemotePushSubscription {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw ApprovalPersistenceError.corruptRecord
        }
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        let active: Bool = row["active"]
        return RemotePushSubscription(
            id: id,
            endpoint: row["endpoint"],
            p256dh: row["p256dh"],
            auth: row["auth"],
            applicationServerKey: row["application_server_key"],
            vapidKeyFingerprint: row["vapid_key_fingerprint"],
            deviceLabel: row["device_label"],
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            active: active
        )
    }

    private static func vapidKeyFingerprint(_ publicKey: String) -> String {
        SHA256.hash(data: Data(publicKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createApprovals") { db in
            try db.create(table: "approvals", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("question", .text).notNull()
                table.column("options_json", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("response", .text)
                table.column("created_at", .double).notNull()
                table.column("expires_at", .double).notNull().indexed()
                table.column("answered_at", .double)
            }
        }
        migrator.registerMigration("addApprovalKindsAndResponses") { db in
            try db.alter(table: "approvals") { table in
                table.add(
                    column: "kind",
                    .text
                ).notNull().defaults(to: ApprovalKind.singleSelect.rawValue)
                table.add(column: "responses_json", .text)
            }
        }
        migrator.registerMigration("addApprovalQuestions") { db in
            try db.alter(table: "approvals") { table in
                table.add(column: "questions_json", .text)
            }
        }
        migrator.registerMigration("createRemoteClaudeJobs") { db in
            try db.create(table: "remote_claude_jobs", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("prompt", .text).notNull()
                table.column("working_directory", .text).notNull()
                table.column("status", .text).notNull().indexed()
                table.column("response", .text)
                table.column("error_message", .text)
                table.column("session_id", .text)
                table.column("created_at", .double).notNull().indexed()
                table.column("started_at", .double)
                table.column("completed_at", .double)
            }
        }
        migrator.registerMigration("createRemotePushOutbox") { db in
            try db.create(table: "remote_push_subscriptions", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("endpoint", .text).notNull().unique()
                table.column("p256dh", .text).notNull()
                table.column("auth", .text).notNull()
                table.column("application_server_key", .text)
                table.column("vapid_key_fingerprint", .text)
                table.column("device_label", .text)
                table.column("active", .boolean).notNull().defaults(to: true).indexed()
                table.column("created_at", .double).notNull().indexed()
                table.column("updated_at", .double).notNull()
                table.column("last_success_at", .double)
                table.column("last_error", .text)
            }
            try db.create(table: "remote_push_outbox", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("event_key", .text).notNull().unique()
                table.column("kind", .text).notNull()
                table.column("approval_id", .text)
                    .references("approvals", column: "id", onDelete: .cascade)
                table.column("created_at", .double).notNull().indexed()
                table.column("materialized_at", .double)
                table.column("completed_at", .double)
            }
            try db.create(table: "remote_push_deliveries", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("event_id", .text).notNull()
                    .references("remote_push_outbox", column: "id", onDelete: .cascade)
                table.column("subscription_id", .text).notNull()
                    .references("remote_push_subscriptions", column: "id", onDelete: .cascade)
                table.column("status", .text).notNull().indexed()
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("next_attempt_at", .double).notNull().indexed()
                table.column("lease_until", .double).indexed()
                table.column("last_error", .text)
                table.column("delivered_at", .double)
                table.column("created_at", .double).notNull()
                table.uniqueKey(["event_id", "subscription_id"])
            }
        }
        migrator.registerMigration("addRemoteAgentContext") { db in
            try db.alter(table: "approvals") { table in
                table.add(column: "source_json", .text)
            }
            try db.create(table: "remote_agent_modes") { table in
                table.column("agent", .text).primaryKey()
                table.column("enabled", .boolean).notNull()
            }
            try db.alter(table: "remote_claude_jobs") { table in
                table.add(column: "agent", .text).notNull().defaults(to: "claude")
            }
        }
        migrator.registerMigration("addRemoteConversationRetry") { db in
            try db.alter(table: "remote_claude_jobs") { table in
                table.add(column: "not_before", .double)
            }
        }
        migrator.registerMigration("addCodexQueuedMessageReceipt") { db in
            try db.alter(table: "remote_claude_jobs") { table in
                table.add(column: "message_queued_at", .double)
            }
        }
        migrator.registerMigration("addRetiredRemoteConversations") { db in
            try db.create(table: "remote_retired_conversations") { table in
                table.column("agent", .text).notNull()
                table.column("project", .text).notNull().indexed()
                table.column("session_id", .text).notNull()
                table.column("successor_session_id", .text).notNull()
                table.column("retired_at", .double).notNull()
                table.primaryKey(["agent", "session_id"])
            }
        }
        migrator.registerMigration("addRemoteJobHistoryVisibility") { db in
            try db.alter(table: "remote_claude_jobs") { table in
                table.add(column: "history_hidden_at", .double)
            }
        }
        return migrator
    }

    private static func expirePendingApprovals(db: Database, now: Date) throws {
        try db.execute(
            sql: """
            UPDATE approvals
            SET status = ?
            WHERE status = ? AND expires_at <= ?
            """,
            arguments: [
                ApprovalStatus.expired.rawValue,
                ApprovalStatus.pending.rawValue,
                now.timeIntervalSince1970
            ]
        )
    }

    private static func fetchApproval(db: Database, id: UUID) throws -> Approval? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM approvals WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            return nil
        }
        return try decodeApproval(row)
    }

    private static func fetchClaudeJob(db: Database, id: UUID) throws -> RemoteClaudeJob? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM remote_claude_jobs WHERE id = ?",
            arguments: [id.uuidString]
        ) else {
            return nil
        }
        return try decodeClaudeJob(row)
    }

    private static func decodeClaudeJob(_ row: Row) throws -> RemoteClaudeJob {
        let idString: String = row["id"]
        let statusString: String = row["status"]
        guard let id = UUID(uuidString: idString),
              let status = RemoteClaudeJobStatus(rawValue: statusString)
        else {
            throw ApprovalPersistenceError.corruptRecord
        }
        let startedAt: Double? = row["started_at"]
        let completedAt: Double? = row["completed_at"]
        let messageQueuedAt: Double? = row["message_queued_at"]
        return RemoteClaudeJob(
            id: id,
            prompt: row["prompt"],
            workingDirectory: row["working_directory"],
            status: status,
            response: row["response"],
            errorMessage: row["error_message"],
            sessionID: row["session_id"],
            messageQueuedAt: messageQueuedAt.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
            completedAt: completedAt.map(Date.init(timeIntervalSince1970:)),
            agent: row["agent"]
        )
    }

    private static func decodeApproval(_ row: Row) throws -> Approval {
        let idString: String = row["id"]
        let statusString: String = row["status"]
        let kindString: String = row["kind"]
        let optionsJSON: String = row["options_json"]
        guard let id = UUID(uuidString: idString),
              let status = ApprovalStatus(rawValue: statusString),
              let kind = ApprovalKind(rawValue: kindString)
        else {
            throw ApprovalPersistenceError.corruptRecord
        }

        let response: String? = row["response"]
        let responsesJSON: String? = row["responses_json"]
        let responses = try responsesJSON.map(decodeOptions) ?? response.map { [$0] } ?? []
        let questionsJSON: String? = row["questions_json"]
        let questions = try questionsJSON.map {
            try decode([ApprovalQuestion].self, from: $0)
        } ?? [
            ApprovalQuestion(
                id: "answer",
                question: row["question"],
                kind: kind,
                options: try decodeOptions(optionsJSON),
                responses: responses
            )
        ]
        let answeredAtInterval: Double? = row["answered_at"]
        return Approval(
            id: id,
            questions: questions,
            status: status,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
            answeredAt: answeredAtInterval.map(Date.init(timeIntervalSince1970:)),
            source: try (row["source_json"] as String?).map {
                try decode(RemoteRequestSource.self, from: $0)
            }
        )
    }

    private static func encodeOptions(_ options: [String]) throws -> String {
        let data = try JSONEncoder().encode(options)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ApprovalPersistenceError.invalidOptionsEncoding
        }
        return json
    }

    private static func decodeOptions(_ json: String) throws -> [String] {
        try decode([String].self, from: json)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ApprovalPersistenceError.invalidOptionsEncoding
        }
        return json
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw ApprovalPersistenceError.invalidOptionsEncoding
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func applying(
        answers: [ApprovalAnswer],
        to questions: [ApprovalQuestion]
    ) throws -> [ApprovalQuestion] {
        var answersByID: [String: [String]] = [:]
        for answer in answers {
            guard answersByID.updateValue(answer.responses, forKey: answer.id) == nil else {
                throw ApprovalError.invalidResponse
            }
        }
        guard Set(answersByID.keys) == Set(questions.map(\.id)) else {
            throw ApprovalError.invalidResponse
        }
        return try questions.map { question in
            guard let responses = answersByID[question.id] else {
                throw ApprovalError.invalidResponse
            }
            let normalizedResponses: [String]
            if question.kind == .text,
               questions.count > 1,
               responses == [""] {
                normalizedResponses = []
            } else {
                normalizedResponses = responses
            }
            try validate(
                responses: normalizedResponses,
                for: question,
                textRequired: questions.count == 1
            )
            return ApprovalQuestion(
                id: question.id,
                question: question.question,
                kind: question.kind,
                options: question.options,
                responses: normalizedResponses
            )
        }
    }

    private static func validate(
        responses: [String],
        for question: ApprovalQuestion,
        textRequired: Bool
    ) throws {
        switch question.kind {
        case .singleSelect:
            guard responses.count == 1,
                  question.options.contains(responses[0])
            else {
                throw ApprovalError.invalidResponse
            }
        case .multiSelect:
            guard !responses.isEmpty,
                  responses.count <= question.options.count,
                  Set(responses).count == responses.count,
                  responses.allSatisfy(question.options.contains)
            else {
                throw ApprovalError.invalidResponse
            }
        case .text:
            if !textRequired, responses.isEmpty {
                return
            }
            guard responses.count == 1 else { throw ApprovalError.invalidResponse }
            guard !responses[0].isEmpty else { throw ApprovalError.emptyResponse }
            guard responses[0].count <= 4_000 else { throw ApprovalError.responseTooLong }
        }
    }
}

private enum ApprovalPersistenceError: Error {
    case notFound
    case corruptRecord
    case invalidOptionsEncoding
}
