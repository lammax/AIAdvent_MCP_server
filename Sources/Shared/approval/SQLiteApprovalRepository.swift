import Foundation
import GRDB

public actor SQLiteApprovalRepository: ApprovalRepository {
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

    public func create(_ approval: Approval) async throws {
        let optionsJSON = try Self.encodeOptions(approval.options)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO approvals (
                    id, question, options_json, status, response,
                    created_at, expires_at, answered_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    approval.id.uuidString,
                    approval.question,
                    optionsJSON,
                    approval.status.rawValue,
                    approval.response,
                    approval.createdAt.timeIntervalSince1970,
                    approval.expiresAt.timeIntervalSince1970,
                    approval.answeredAt?.timeIntervalSince1970
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

    public func respond(id: UUID, response: String, now: Date) async throws -> Approval {
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

            guard existing.options.contains(response) else {
                throw ApprovalError.invalidResponse
            }

            try db.execute(
                sql: """
                UPDATE approvals
                SET status = ?, response = ?, answered_at = ?
                WHERE id = ? AND status = ? AND expires_at > ?
                """,
                arguments: [
                    ApprovalStatus.answered.rawValue,
                    response,
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

    private static func decodeApproval(_ row: Row) throws -> Approval {
        let idString: String = row["id"]
        let statusString: String = row["status"]
        let optionsJSON: String = row["options_json"]
        guard let id = UUID(uuidString: idString),
              let status = ApprovalStatus(rawValue: statusString)
        else {
            throw ApprovalPersistenceError.corruptRecord
        }

        let response: String? = row["response"]
        let answeredAtInterval: Double? = row["answered_at"]
        return Approval(
            id: id,
            question: row["question"],
            options: try decodeOptions(optionsJSON),
            status: status,
            response: response,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
            answeredAt: answeredAtInterval.map(Date.init(timeIntervalSince1970:))
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
        guard let data = json.data(using: .utf8) else {
            throw ApprovalPersistenceError.invalidOptionsEncoding
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
}

private enum ApprovalPersistenceError: Error {
    case corruptRecord
    case invalidOptionsEncoding
}
