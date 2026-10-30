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
        let responsesJSON = try Self.encodeOptions(approval.responses)
        let questionsJSON = try Self.encode(approval.questions)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO approvals (
                    id, question, kind, options_json, status, response, responses_json, questions_json,
                    created_at, expires_at, answered_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            try validate(responses: responses, for: question)
            return ApprovalQuestion(
                id: question.id,
                question: question.question,
                kind: question.kind,
                options: question.options,
                responses: responses
            )
        }
    }

    private static func validate(responses: [String], for question: ApprovalQuestion) throws {
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
            guard responses.count == 1 else { throw ApprovalError.invalidResponse }
            guard !responses[0].isEmpty else { throw ApprovalError.emptyResponse }
            guard responses[0].count <= 4_000 else { throw ApprovalError.responseTooLong }
        }
    }
}

private enum ApprovalPersistenceError: Error {
    case corruptRecord
    case invalidOptionsEncoding
}
