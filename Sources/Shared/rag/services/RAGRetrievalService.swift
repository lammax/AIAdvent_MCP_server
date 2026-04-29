import Foundation

public protocol RAGRetrievalServiceProtocol: Sendable {
    func invalidateCache() async

    func retrieve(
        question: String,
        strategy: RAGChunkingStrategy,
        limit: Int
    ) async throws -> [RAGRetrievedChunk]

    func retrieve(
        originalQuestion: String,
        searchQuery: String,
        strategy: RAGChunkingStrategy,
        settings: RAGRetrievalSettings
    ) async throws -> RAGRetrievalResult
}

public actor RAGRetrievalService: RAGRetrievalServiceProtocol {
    private let embeddingService: EmbeddingServiceProtocol
    private let repository: RAGIndexRepositoryProtocol
    private let relevanceFilteringService: RAGRelevanceFilteringServiceProtocol
    private var cachedChunksByStrategy: [RAGChunkingStrategy: [RAGStoredChunk]] = [:]

    public init(
        embeddingService: EmbeddingServiceProtocol = LocalHashedEmbeddingService(),
        repository: RAGIndexRepositoryProtocol? = nil,
        relevanceFilteringService: RAGRelevanceFilteringServiceProtocol = RAGRelevanceFilteringService()
    ) throws {
        self.embeddingService = embeddingService
        self.repository = try repository ?? RAGIndexRepository()
        self.relevanceFilteringService = relevanceFilteringService
    }

    public func invalidateCache() {
        cachedChunksByStrategy.removeAll()
    }

    public func retrieve(
        question: String,
        strategy: RAGChunkingStrategy,
        limit: Int = 5
    ) async throws -> [RAGRetrievedChunk] {
        guard limit > 0 else { return [] }

        let questionEmbedding = try await embeddingService.embed([question]).first ?? []
        guard !questionEmbedding.isEmpty else { return [] }

        let chunks = try await cachedChunks(strategy: strategy)
        return Self.topMatches(
            in: chunks,
            questionEmbedding: questionEmbedding,
            limit: limit
        )
    }

    public func retrieve(
        originalQuestion: String,
        searchQuery: String,
        strategy: RAGChunkingStrategy,
        settings: RAGRetrievalSettings
    ) async throws -> RAGRetrievalResult {
        let safeBeforeLimit = max(settings.topKBeforeFiltering, 0)
        guard safeBeforeLimit > 0 else {
            return RAGRetrievalResult(
                originalQuestion: originalQuestion,
                searchQuery: searchQuery,
                candidatesBeforeFiltering: [],
                chunksAfterFiltering: []
            )
        }

        let candidates = try await retrieve(
            question: searchQuery,
            strategy: strategy,
            limit: safeBeforeLimit
        )
        let filtered = try await relevanceFilteringService.filter(
            chunks: candidates,
            question: searchQuery,
            settings: settings
        )

        return RAGRetrievalResult(
            originalQuestion: originalQuestion,
            searchQuery: searchQuery,
            candidatesBeforeFiltering: candidates,
            chunksAfterFiltering: filtered
        )
    }

    private func cachedChunks(strategy: RAGChunkingStrategy) async throws -> [RAGStoredChunk] {
        if let chunks = cachedChunksByStrategy[strategy] {
            return chunks
        }

        let fetched = try await repository.fetchChunks(strategy: strategy)
        cachedChunksByStrategy[strategy] = fetched
        return fetched
    }

    private static func topMatches(
        in chunks: [RAGStoredChunk],
        questionEmbedding: [Float],
        limit: Int
    ) -> [RAGRetrievedChunk] {
        var top: [RAGRetrievedChunk] = []

        for chunk in chunks {
            let score = cosineSimilarity(questionEmbedding, chunk.embedding)
            guard score.isFinite else { continue }

            let match = RAGRetrievedChunk(chunk: chunk, score: score)

            if let insertionIndex = top.firstIndex(where: { score > $0.score }) {
                top.insert(match, at: insertionIndex)
            } else if top.count < limit {
                top.append(match)
            }

            if top.count > limit {
                top.removeLast()
            }
        }

        return top
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return -.infinity
        }

        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0

        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])

            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }

        guard lhsNorm > 0, rhsNorm > 0 else {
            return -.infinity
        }

        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
