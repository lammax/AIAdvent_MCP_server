import Foundation
import GRDB

public final class MCPDatabase: @unchecked Sendable {
    public let dbQueue: DatabaseQueue
    public let path: String
    public let displayPath: String

    public init(path: String = MCPDatabase.defaultRAGDatabasePath()) throws {
        self.path = path
        self.displayPath = MCPDatabase.displayPath(for: path)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }

    public static func defaultRAGDatabasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["MCP_RAG_DB_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: override).expandingTildeInPath
        }

        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return projectRoot
            .appendingPathComponent(".mcp_server", isDirectory: true)
            .appendingPathComponent("rag.sqlite")
            .path
    }

    public static func displayPath(for path: String) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let rootPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
            .path
        let standardizedPath = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .path

        guard standardizedPath == rootPath || standardizedPath.hasPrefix(rootPath + "/") else {
            return URL(fileURLWithPath: standardizedPath).lastPathComponent
        }

        let relative = String(standardizedPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : relative
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createRAGChunks") { db in
            try db.create(table: "rag_chunks", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("strategy", .text).notNull().indexed()
                table.column("source", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("section", .text).notNull()
                table.column("chunk_id", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("token_count", .integer).notNull()
                table.column("start_offset", .integer).notNull()
                table.column("end_offset", .integer).notNull()
                table.column("embedding", .blob).notNull()
                table.column("embedding_dim", .integer).notNull()
                table.column("embedding_model", .text).notNull()
                table.column("created_at", .double).notNull()
            }

            try db.create(
                index: "idx_rag_chunks_strategy_source",
                on: "rag_chunks",
                columns: ["strategy", "source"],
                ifNotExists: true
            )
        }

        return migrator
    }
}
