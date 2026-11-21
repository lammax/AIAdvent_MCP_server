import Foundation
import GRDB

/// Adds scope-aware claiming on top of `RemoteClaudeJobRepository`, so an
/// independently-schedulable lane (see `RemoteClaudeJobScope`) can be claimed without
/// racing unrelated agent/project/session combinations. Intentionally separate from
/// `SQLiteApprovalRepository`: EnergyBot's bridge gets its own job table and its own
/// migrator, so nothing here can change behavior for the existing Remote approval
/// system, which keeps using `SQLiteApprovalRepository` untouched.
public protocol AgentBridgeJobRepository: RemoteClaudeJobRepository {
    func claimNextClaudeJob(startedAt: Date, scopedTo scope: RemoteClaudeJobScope) async throws -> RemoteClaudeJob?
    func distinctQueuedJobScopes() async throws -> [RemoteClaudeJobScope]
}

/// Scopes job claiming to one independently-schedulable lane. Codex serializes at the
/// project level (ignores the thread) because two concurrent `codex queue` invocations
/// in the same working directory can race on the same checkout; Claude serializes per
/// session, since each session is an independent CLI process with its own `--resume`.
public struct RemoteClaudeJobScope: Hashable, Sendable {
    public let agent: String
    public let project: String
    public let sessionKey: String

    public init(agent: String, project: String, sessionKey: String) {
        self.agent = agent
        self.project = project
        self.sessionKey = sessionKey
    }

    public init(job: RemoteClaudeJob) {
        self.init(
            agent: job.agent,
            project: job.workingDirectory,
            sessionKey: job.agent == "codex" ? "" : (job.sessionID ?? "")
        )
    }
}

private enum AgentBridgeJobPersistenceError: Error {
    case corruptRecord
}

public actor SQLiteAgentBridgeJobRepository: AgentBridgeJobRepository {
    private let dbQueue: DatabaseQueue
    public let path: String

    public init(path: String) throws {
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

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createAgentBridgeJobs") { db in
            try db.create(table: "agent_bridge_jobs", ifNotExists: true) { table in
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
                table.column("agent", .text).notNull().defaults(to: "claude")
                table.column("not_before", .double)
                table.column("message_queued_at", .double)
                table.column("history_hidden_at", .double)
                table.column("idempotency_key", .text)
                table.column("force_rotation", .boolean).notNull().defaults(to: false)
                table.column("automatic_rotation", .boolean).notNull().defaults(to: true)
                table.column("rotation_only", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "idx_agent_bridge_jobs_idempotency",
                on: "agent_bridge_jobs",
                columns: ["agent", "idempotency_key"],
                options: .ifNotExists
            )
            try db.create(table: "agent_bridge_retired_conversations", ifNotExists: true) { table in
                table.column("agent", .text).notNull()
                table.column("project", .text).notNull().indexed()
                table.column("session_id", .text).notNull()
                table.column("successor_session_id", .text).notNull()
                table.column("retired_at", .double).notNull()
                table.primaryKey(["agent", "session_id"])
            }
        }
        return migrator
    }

    public func createClaudeJob(_ job: RemoteClaudeJob) async throws {
        try await insertClaudeJob(job)
    }

    public func createWebJob(_ job: RemoteClaudeJob, remoteEnabled: Bool) async throws {
        try await insertClaudeJob(job)
    }

    private func insertClaudeJob(_ job: RemoteClaudeJob) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_bridge_jobs (
                    id, prompt, working_directory, status, response, error_message, session_id,
                    created_at, started_at, completed_at, agent, idempotency_key,
                    force_rotation, automatic_rotation, rotation_only
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    job.idempotencyKey,
                    job.forceRotation,
                    job.automaticRotation,
                    job.rotationOnly,
                ]
            )
        }
    }

    public func claudeJob(agent: String, idempotencyKey: String) async throws -> RemoteClaudeJob? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_bridge_jobs WHERE agent = ? AND idempotency_key = ?",
                arguments: [agent, idempotencyKey]
            ) else { return nil }
            return try Self.decodeClaudeJob(row)
        }
    }

    public func claudeJob(id: UUID) async throws -> RemoteClaudeJob? {
        try await dbQueue.read { db in try Self.fetchClaudeJob(db: db, id: id) }
    }

    public func conversationSessionIDs(agent: String, project: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT session_id FROM agent_bridge_jobs WHERE agent = ? AND working_directory = ? AND session_id IS NOT NULL AND prompt != 'Usage'",
                arguments: [agent, project]
            )
        }
    }

    public func retiredConversationSessionIDs(agent: String, project: String) async throws -> Set<String> {
        try await dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT session_id FROM agent_bridge_retired_conversations WHERE agent = ? AND project = ?",
                arguments: [agent, project]
            ))
        }
    }

    public func deferBusyConversation(id: UUID, until: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agent_bridge_jobs SET status = 'queued', started_at = NULL, not_before = ?, error_message = ? WHERE id = ? AND status = 'running'",
                arguments: [until.timeIntervalSince1970, RemoteConversationError.busy.localizedDescription, id.uuidString]
            )
        }
    }

    public func markCodexMessageQueued(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agent_bridge_jobs SET message_queued_at = ? WHERE id = ? AND status = 'running' AND agent = 'codex' AND message_queued_at IS NULL",
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
                sql: "UPDATE agent_bridge_jobs SET session_id = ? WHERE id = ? AND status = 'running' AND agent = 'codex'",
                arguments: [successorSessionID, jobID.uuidString]
            )
            guard db.changesCount == 1 else { throw AgentBridgeJobPersistenceError.corruptRecord }
            try db.execute(
                sql: """
                INSERT INTO agent_bridge_retired_conversations (agent, project, session_id, successor_session_id, retired_at)
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
                SELECT * FROM agent_bridge_jobs
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
                UPDATE agent_bridge_jobs
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
                throw AgentBridgeJobPersistenceError.corruptRecord
            }
            guard current.status == .queued || current.status == .running else {
                if current.status == .cancelled { return current }
                throw RemoteClaudeJobError.notCancellable
            }
            try db.execute(
                sql: """
                UPDATE agent_bridge_jobs
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
                throw AgentBridgeJobPersistenceError.corruptRecord
            }
            return updated
        }
    }

    public func cancelClaudeJob(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agent_bridge_jobs
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
            try db.execute(sql: "UPDATE agent_bridge_jobs SET status = 'queued', started_at = NULL WHERE status = 'running' AND agent = 'codex' AND message_queued_at IS NOT NULL")
            try db.execute(sql: "UPDATE agent_bridge_jobs SET status = 'failed', error_message = 'Interrupted by server restart; inspect changes before retrying.' WHERE status = 'running' AND agent = 'codex' AND message_queued_at IS NULL")
            try db.execute(
                sql: """
                UPDATE agent_bridge_jobs
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
                SELECT * FROM agent_bridge_jobs
                WHERE status = ? AND (not_before IS NULL OR not_before <= ?)
                ORDER BY created_at ASC
                LIMIT 1
                """,
                arguments: [RemoteClaudeJobStatus.queued.rawValue, startedAt.timeIntervalSince1970]
            ) else { return nil }
            return try Self.claim(db: db, row: row, startedAt: startedAt)
        }
    }

    public func claimNextClaudeJob(startedAt: Date, scopedTo scope: RemoteClaudeJobScope) async throws -> RemoteClaudeJob? {
        try await dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM agent_bridge_jobs
                WHERE status = ? AND (not_before IS NULL OR not_before <= ?)
                  AND agent = ? AND working_directory = ?
                  AND (agent = 'codex' OR COALESCE(session_id, '') = ?)
                ORDER BY created_at ASC
                LIMIT 1
                """,
                arguments: [
                    RemoteClaudeJobStatus.queued.rawValue, startedAt.timeIntervalSince1970,
                    scope.agent, scope.project, scope.sessionKey,
                ]
            ) else { return nil }
            return try Self.claim(db: db, row: row, startedAt: startedAt)
        }
    }

    private static func claim(db: Database, row: Row, startedAt: Date) throws -> RemoteClaudeJob? {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw AgentBridgeJobPersistenceError.corruptRecord
        }
        try db.execute(
            sql: "UPDATE agent_bridge_jobs SET status = ?, started_at = ? WHERE id = ? AND status = ?",
            arguments: [
                RemoteClaudeJobStatus.running.rawValue,
                startedAt.timeIntervalSince1970,
                id.uuidString,
                RemoteClaudeJobStatus.queued.rawValue,
            ]
        )
        guard db.changesCount == 1 else { return nil }
        return try fetchClaudeJob(db: db, id: id)
    }

    public func distinctQueuedJobScopes() async throws -> [RemoteClaudeJobScope] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT agent, working_directory,
                    CASE WHEN agent = 'codex' THEN '' ELSE COALESCE(session_id, '') END AS session_key
                FROM agent_bridge_jobs
                WHERE status = ?
                """,
                arguments: [RemoteClaudeJobStatus.queued.rawValue]
            )
            return rows.map {
                RemoteClaudeJobScope(agent: $0["agent"], project: $0["working_directory"], sessionKey: $0["session_key"])
            }
        }
    }

    public func completeClaudeJob(id: UUID, result: RemoteClaudeJobResult, completedAt: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agent_bridge_jobs
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
                UPDATE agent_bridge_jobs
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

    private static func fetchClaudeJob(db: Database, id: UUID) throws -> RemoteClaudeJob? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM agent_bridge_jobs WHERE id = ?",
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
            throw AgentBridgeJobPersistenceError.corruptRecord
        }
        let startedAt: Double? = row["started_at"]
        let completedAt: Double? = row["completed_at"]
        let messageQueuedAt: Double? = row["message_queued_at"]
        let forceRotation: Bool = row["force_rotation"]
        let automaticRotation: Bool = row["automatic_rotation"]
        let rotationOnly: Bool = row["rotation_only"]
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
            agent: row["agent"],
            idempotencyKey: row["idempotency_key"],
            forceRotation: forceRotation,
            automaticRotation: automaticRotation,
            rotationOnly: rotationOnly
        )
    }
}
