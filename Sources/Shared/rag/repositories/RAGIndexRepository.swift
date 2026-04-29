import Foundation
import GRDB

public protocol RAGIndexRepositoryProtocol: Sendable {
    var databasePath: String { get }

    func replace(strategy: RAGChunkingStrategy, chunks: [RAGEmbeddedChunk]) async throws
    func append(chunks: [RAGEmbeddedChunk]) async throws
    func fetchChunks(strategy: RAGChunkingStrategy) async throws -> [RAGStoredChunk]
    func deleteAll() async throws
}

public final class RAGIndexRepository: RAGIndexRepositoryProtocol, @unchecked Sendable {
    private let database: MCPDatabase

    public init(database: MCPDatabase? = nil) throws {
        self.database = try database ?? MCPDatabase()
    }

    public var databasePath: String {
        database.displayPath
    }

    public func replace(strategy: RAGChunkingStrategy, chunks: [RAGEmbeddedChunk]) async throws {
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM rag_chunks WHERE strategy = ?",
                arguments: [strategy.rawValue]
            )

            try Self.insert(chunks: chunks, into: db)
        }
    }

    public func append(chunks: [RAGEmbeddedChunk]) async throws {
        try await database.dbQueue.write { db in
            try Self.insert(chunks: chunks, into: db)
        }
    }

    public func fetchChunks(strategy: RAGChunkingStrategy) async throws -> [RAGStoredChunk] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, source, title, section, chunk_id, strategy, content,
                       token_count, start_offset, end_offset, embedding, embedding_model
                FROM rag_chunks
                WHERE strategy = ?
                """,
                arguments: [strategy.rawValue]
            )

            return rows.compactMap { row in
                guard
                    let id = UUID(uuidString: row["id"]),
                    let strategy = RAGChunkingStrategy(rawValue: row["strategy"])
                else {
                    return nil
                }

                let embeddingData: Data = row["embedding"]
                return RAGStoredChunk(
                    id: id,
                    source: row["source"],
                    title: row["title"],
                    section: row["section"],
                    chunkId: row["chunk_id"],
                    strategy: strategy,
                    content: row["content"],
                    tokenCount: row["token_count"],
                    startOffset: row["start_offset"],
                    endOffset: row["end_offset"],
                    embedding: Self.vector(from: embeddingData),
                    embeddingModel: row["embedding_model"]
                )
            }
        }
    }

    public func deleteAll() async throws {
        try await database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM rag_chunks")
        }
    }

    private static func insert(chunks: [RAGEmbeddedChunk], into db: Database) throws {
        for item in chunks {
            try db.execute(
                sql: """
                INSERT INTO rag_chunks (
                    id, strategy, source, title, section, chunk_id,
                    content, token_count, start_offset, end_offset,
                    embedding, embedding_dim, embedding_model, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    item.chunk.id.uuidString,
                    item.chunk.strategy.rawValue,
                    item.chunk.source,
                    item.chunk.title,
                    item.chunk.section,
                    item.chunk.chunkId,
                    item.chunk.content,
                    item.chunk.tokenCount,
                    item.chunk.startOffset,
                    item.chunk.endOffset,
                    Self.data(from: item.embedding),
                    item.embedding.count,
                    item.model,
                    Date().timeIntervalSince1970
                ]
            )
        }
    }

    private static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func vector(from data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.stride) else {
            return []
        }

        var vector = Array(
            repeating: Float.zero,
            count: data.count / MemoryLayout<Float>.stride
        )

        _ = vector.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }

        return vector
    }
}
