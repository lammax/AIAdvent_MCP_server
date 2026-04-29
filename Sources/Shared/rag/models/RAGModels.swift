import Foundation

public enum RAGChunkingStrategy: String, Codable, CaseIterable, Sendable {
    case fixedTokens
    case structure
}

public enum RAGRetrievalMode: String, Codable, CaseIterable, Sendable {
    case basic
    case enhanced
}

public enum RAGRelevanceFilterMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case similarityThreshold
    case heuristic
}

public struct RAGIndexingOptions: Codable, Sendable {
    public let strategy: RAGChunkingStrategy
    public let replaceExisting: Bool
    public let allowedExtensions: [String]
    public let chunkSize: Int
    public let overlap: Int
    public let maxCharacters: Int

    public init(
        strategy: RAGChunkingStrategy = .fixedTokens,
        replaceExisting: Bool = true,
        allowedExtensions: [String] = ["swift", "md", "txt", "json"],
        chunkSize: Int = 500,
        overlap: Int = 50,
        maxCharacters: Int = 1_200
    ) {
        self.strategy = strategy
        self.replaceExisting = replaceExisting
        self.allowedExtensions = allowedExtensions
        self.chunkSize = chunkSize
        self.overlap = overlap
        self.maxCharacters = maxCharacters
    }
}

public struct RAGRetrievalSettings: Codable, Equatable, Sendable {
    public let topKBeforeFiltering: Int
    public let topKAfterFiltering: Int
    public let similarityThreshold: Double
    public let relevanceFilterMode: RAGRelevanceFilterMode

    public init(
        topKBeforeFiltering: Int = 12,
        topKAfterFiltering: Int = 5,
        similarityThreshold: Double = 0.25,
        relevanceFilterMode: RAGRelevanceFilterMode = .similarityThreshold
    ) {
        self.topKBeforeFiltering = topKBeforeFiltering
        self.topKAfterFiltering = topKAfterFiltering
        self.similarityThreshold = similarityThreshold
        self.relevanceFilterMode = relevanceFilterMode
    }
}

public struct RAGSourceDocument: Hashable, Sendable {
    public let url: URL
    public let title: String
    public let content: String

    public init(url: URL, title: String, content: String) {
        self.url = url
        self.title = title
        self.content = content
    }
}

public struct RAGChunk: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let source: String
    public let title: String
    public let section: String
    public let chunkId: Int
    public let strategy: RAGChunkingStrategy
    public let content: String
    public let tokenCount: Int
    public let startOffset: Int
    public let endOffset: Int

    public init(
        id: UUID = UUID(),
        source: String,
        title: String,
        section: String,
        chunkId: Int,
        strategy: RAGChunkingStrategy,
        content: String,
        tokenCount: Int,
        startOffset: Int,
        endOffset: Int
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.section = section
        self.chunkId = chunkId
        self.strategy = strategy
        self.content = content
        self.tokenCount = tokenCount
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct RAGEmbeddedChunk: Sendable {
    public let chunk: RAGChunk
    public let embedding: [Float]
    public let model: String

    public init(chunk: RAGChunk, embedding: [Float], model: String) {
        self.chunk = chunk
        self.embedding = embedding
        self.model = model
    }
}

public struct RAGStoredChunk: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let source: String
    public let title: String
    public let section: String
    public let chunkId: Int
    public let strategy: RAGChunkingStrategy
    public let content: String
    public let tokenCount: Int
    public let startOffset: Int
    public let endOffset: Int
    public let embedding: [Float]
    public let embeddingModel: String

    public init(
        id: UUID,
        source: String,
        title: String,
        section: String,
        chunkId: Int,
        strategy: RAGChunkingStrategy,
        content: String,
        tokenCount: Int,
        startOffset: Int,
        endOffset: Int,
        embedding: [Float],
        embeddingModel: String
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.section = section
        self.chunkId = chunkId
        self.strategy = strategy
        self.content = content
        self.tokenCount = tokenCount
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }
}

public struct RAGRetrievedChunk: Identifiable, Hashable, Sendable {
    public let chunk: RAGStoredChunk
    public let score: Double
    public let relevanceScore: Double
    public let relevanceReason: String

    public init(
        chunk: RAGStoredChunk,
        score: Double,
        relevanceScore: Double? = nil,
        relevanceReason: String = "cosine similarity"
    ) {
        self.chunk = chunk
        self.score = score
        self.relevanceScore = relevanceScore ?? score
        self.relevanceReason = relevanceReason
    }

    public var id: UUID { chunk.id }
}

public struct RAGRetrievalResult: Sendable {
    public let originalQuestion: String
    public let searchQuery: String
    public let candidatesBeforeFiltering: [RAGRetrievedChunk]
    public let chunksAfterFiltering: [RAGRetrievedChunk]

    public init(
        originalQuestion: String,
        searchQuery: String,
        candidatesBeforeFiltering: [RAGRetrievedChunk],
        chunksAfterFiltering: [RAGRetrievedChunk]
    ) {
        self.originalQuestion = originalQuestion
        self.searchQuery = searchQuery
        self.candidatesBeforeFiltering = candidatesBeforeFiltering
        self.chunksAfterFiltering = chunksAfterFiltering
    }
}

public struct RAGIndexingSummary: Codable, Sendable {
    public let strategy: RAGChunkingStrategy
    public let documentCount: Int
    public let chunkCount: Int
    public let averageTokens: Double
    public let minTokens: Int
    public let maxTokens: Int
    public let embeddingModel: String
    public let databasePath: String
    public let duration: TimeInterval

    public init(
        strategy: RAGChunkingStrategy,
        documentCount: Int,
        chunkCount: Int,
        averageTokens: Double,
        minTokens: Int,
        maxTokens: Int,
        embeddingModel: String,
        databasePath: String,
        duration: TimeInterval
    ) {
        self.strategy = strategy
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.averageTokens = averageTokens
        self.minTokens = minTokens
        self.maxTokens = maxTokens
        self.embeddingModel = embeddingModel
        self.databasePath = databasePath
        self.duration = duration
    }
}

public struct RAGAnswerContract: Codable, Equatable, Sendable {
    public let answer: String
    public let sources: [RAGAnswerSource]
    public let quotes: [RAGAnswerQuote]
    public let isUnknown: Bool
    public let clarificationRequest: String?

    public init(
        answer: String,
        sources: [RAGAnswerSource],
        quotes: [RAGAnswerQuote],
        isUnknown: Bool,
        clarificationRequest: String?
    ) {
        self.answer = answer
        self.sources = sources
        self.quotes = quotes
        self.isUnknown = isUnknown
        self.clarificationRequest = clarificationRequest
    }

    enum CodingKeys: String, CodingKey {
        case answer
        case sources
        case quotes
        case isUnknown = "is_unknown"
        case clarificationRequest = "clarification_request"
    }
}

public struct RAGAnswerSource: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let section: String?
    public let chunkID: Int

    public init(source: String, section: String?, chunkID: Int) {
        self.source = source
        self.section = section
        self.chunkID = chunkID
    }

    enum CodingKeys: String, CodingKey {
        case source
        case section
        case chunkID = "chunk_id"
    }
}

public struct RAGAnswerQuote: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let section: String?
    public let chunkID: Int
    public let text: String

    public init(source: String, section: String?, chunkID: Int, text: String) {
        self.source = source
        self.section = section
        self.chunkID = chunkID
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case source
        case section
        case chunkID = "chunk_id"
        case text
    }
}

public struct RAGAnswerValidationResult: Codable, Equatable, Sendable {
    public let hasSources: Bool
    public let hasQuotes: Bool
    public let sourcesMatchChunks: Bool
    public let quotesMatchChunks: Bool
    public let answerSupportedByQuotes: Bool
    public let notes: [String]

    public init(
        hasSources: Bool,
        hasQuotes: Bool,
        sourcesMatchChunks: Bool,
        quotesMatchChunks: Bool,
        answerSupportedByQuotes: Bool,
        notes: [String]
    ) {
        self.hasSources = hasSources
        self.hasQuotes = hasQuotes
        self.sourcesMatchChunks = sourcesMatchChunks
        self.quotesMatchChunks = quotesMatchChunks
        self.answerSupportedByQuotes = answerSupportedByQuotes
        self.notes = notes
    }

    public var isValid: Bool {
        hasSources &&
        hasQuotes &&
        sourcesMatchChunks &&
        quotesMatchChunks &&
        answerSupportedByQuotes
    }
}
