import Foundation

public protocol RAGAnswerValidationServiceProtocol: Sendable {
    func validate(
        answer: RAGAnswerContract,
        retrievedChunks: [RAGRetrievedChunk]
    ) -> RAGAnswerValidationResult
}

public final class RAGAnswerValidationService: RAGAnswerValidationServiceProtocol, @unchecked Sendable {
    public init() {}

    public func validate(
        answer: RAGAnswerContract,
        retrievedChunks: [RAGRetrievedChunk]
    ) -> RAGAnswerValidationResult {
        if answer.isUnknown {
            return RAGAnswerValidationResult(
                hasSources: !answer.sources.isEmpty,
                hasQuotes: !answer.quotes.isEmpty,
                sourcesMatchChunks: true,
                quotesMatchChunks: true,
                answerSupportedByQuotes: true,
                notes: ["Unknown answer is allowed to omit sources and quotes."]
            )
        }

        var notes: [String] = []
        let hasSources = !answer.sources.isEmpty
        let hasQuotes = !answer.quotes.isEmpty

        if !hasSources {
            notes.append("Answer has no sources.")
        }

        if !hasQuotes {
            notes.append("Answer has no quotes.")
        }

        let sourcesMatchChunks = answer.sources.allSatisfy { source in
            containsChunk(
                source: source.source,
                section: source.section,
                chunkID: source.chunkID,
                in: retrievedChunks
            )
        }

        if !sourcesMatchChunks {
            notes.append("At least one source does not match retrieved chunks.")
        }

        let quotesMatchChunks = answer.quotes.allSatisfy { quote in
            guard let chunk = matchingChunk(
                source: quote.source,
                section: quote.section,
                chunkID: quote.chunkID,
                in: retrievedChunks
            ) else {
                return false
            }

            return normalized(chunk.chunk.content).contains(normalized(quote.text))
        }

        if !quotesMatchChunks {
            notes.append("At least one quote is not a verbatim fragment of its retrieved chunk.")
        }

        let answerSupportedByQuotes = hasQuotes && isAnswerSupportedByQuotes(
            answer: answer.answer,
            quotes: answer.quotes.map(\.text)
        )

        if !answerSupportedByQuotes {
            notes.append("Answer terms are weakly supported by the provided quotes.")
        }

        return RAGAnswerValidationResult(
            hasSources: hasSources,
            hasQuotes: hasQuotes,
            sourcesMatchChunks: sourcesMatchChunks,
            quotesMatchChunks: quotesMatchChunks,
            answerSupportedByQuotes: answerSupportedByQuotes,
            notes: notes
        )
    }

    private func containsChunk(
        source: String,
        section: String?,
        chunkID: Int,
        in chunks: [RAGRetrievedChunk]
    ) -> Bool {
        matchingChunk(source: source, section: section, chunkID: chunkID, in: chunks) != nil
    }

    private func matchingChunk(
        source: String,
        section: String?,
        chunkID: Int,
        in chunks: [RAGRetrievedChunk]
    ) -> RAGRetrievedChunk? {
        chunks.first { candidate in
            candidate.chunk.chunkId == chunkID &&
            sourceMatches(source, candidate: candidate.chunk) &&
            sectionMatches(section, candidate: candidate.chunk.section)
        }
    }

    private func sourceMatches(_ source: String, candidate: RAGStoredChunk) -> Bool {
        source == candidate.title || source == candidate.source
    }

    private func sectionMatches(_ section: String?, candidate: String) -> Bool {
        guard let section, !section.isEmpty else {
            return true
        }

        return section == candidate
    }

    private func isAnswerSupportedByQuotes(answer: String, quotes: [String]) -> Bool {
        let answerTerms = significantTerms(in: answer)
        guard !answerTerms.isEmpty else {
            return true
        }

        let quoteTerms = significantTerms(in: quotes.joined(separator: " "))
        guard !quoteTerms.isEmpty else {
            return false
        }

        let overlap = answerTerms.intersection(quoteTerms)
        let ratio = Double(overlap.count) / Double(answerTerms.count)
        return ratio >= 0.25 || overlap.count >= min(3, answerTerms.count)
    }

    private func significantTerms(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "about", "after", "again", "also", "and", "are", "because", "been",
            "before", "being", "does", "for", "from", "has", "have", "how",
            "into", "its", "not", "that", "the", "their", "then", "there",
            "this", "to", "uses", "was", "what", "when", "where", "which",
            "with", "что", "это", "как", "для", "или", "где", "при", "его"
        ]

        return Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && !stopWords.contains($0) }
        )
    }

    private func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct RAGAnswerRun: Codable, Sendable {
    public let contract: RAGAnswerContract
    public let validation: RAGAnswerValidationResult
    public let retrieval: RAGAnswerRetrievalSummary
    public let chunks: [RAGAnswerChunk]?

    public init(
        contract: RAGAnswerContract,
        validation: RAGAnswerValidationResult,
        retrieval: RAGAnswerRetrievalSummary,
        chunks: [RAGAnswerChunk]?
    ) {
        self.contract = contract
        self.validation = validation
        self.retrieval = retrieval
        self.chunks = chunks
    }
}

public struct RAGAnswerRetrievalSummary: Codable, Sendable {
    public let originalQuestion: String
    public let searchQuery: String
    public let candidatesBeforeFiltering: Int
    public let chunksAfterFiltering: Int
    public let bestScore: Double?

    public init(
        originalQuestion: String,
        searchQuery: String,
        candidatesBeforeFiltering: Int,
        chunksAfterFiltering: Int,
        bestScore: Double?
    ) {
        self.originalQuestion = originalQuestion
        self.searchQuery = searchQuery
        self.candidatesBeforeFiltering = candidatesBeforeFiltering
        self.chunksAfterFiltering = chunksAfterFiltering
        self.bestScore = bestScore
    }
}

public struct RAGAnswerChunk: Codable, Sendable {
    public let source: String
    public let title: String
    public let section: String
    public let chunkID: Int
    public let score: Double
    public let relevanceScore: Double
    public let relevanceReason: String
    public let content: String

    public init(chunk: RAGRetrievedChunk) {
        self.source = chunk.chunk.source
        self.title = chunk.chunk.title
        self.section = chunk.chunk.section
        self.chunkID = chunk.chunk.chunkId
        self.score = chunk.score
        self.relevanceScore = chunk.relevanceScore
        self.relevanceReason = chunk.relevanceReason
        self.content = chunk.chunk.content
    }

    enum CodingKeys: String, CodingKey {
        case source
        case title
        case section
        case chunkID = "chunk_id"
        case score
        case relevanceScore = "relevance_score"
        case relevanceReason = "relevance_reason"
        case content
    }
}

public final class RAGAnswerService: @unchecked Sendable {
    private let retrievalService: RAGRetrievalServiceProtocol
    private let validationService: RAGAnswerValidationServiceProtocol

    public init(
        retrievalService: RAGRetrievalServiceProtocol? = nil,
        validationService: RAGAnswerValidationServiceProtocol = RAGAnswerValidationService()
    ) throws {
        self.retrievalService = try retrievalService ?? RAGRetrievalService()
        self.validationService = validationService
    }

    public func answer(
        question: String,
        searchQuery: String?,
        retrievalMode: RAGRetrievalMode,
        strategy: RAGChunkingStrategy,
        settings: RAGRetrievalSettings,
        includeChunks: Bool,
        maxQuoteCharacters: Int
    ) async throws -> RAGAnswerRun {
        let query = normalizedSearchQuery(searchQuery) ?? question
        let retrievalResult: RAGRetrievalResult
        switch retrievalMode {
        case .basic:
            let chunks = try await retrievalService.retrieve(
                question: query,
                strategy: strategy,
                limit: settings.topKAfterFiltering
            )
            retrievalResult = RAGRetrievalResult(
                originalQuestion: question,
                searchQuery: query,
                candidatesBeforeFiltering: chunks,
                chunksAfterFiltering: chunks
            )
        case .enhanced:
            retrievalResult = try await retrievalService.retrieve(
                originalQuestion: question,
                searchQuery: query,
                strategy: strategy,
                settings: settings
            )
        }
        let sources = retrievalResult.chunksAfterFiltering
        let contract = makeContract(
            from: sources,
            bestScore: sources.map(\.relevanceScore).max(),
            threshold: settings.similarityThreshold,
            maxQuoteCharacters: maxQuoteCharacters
        )
        let validation = validationService.validate(answer: contract, retrievedChunks: sources)

        return RAGAnswerRun(
            contract: contract,
            validation: validation,
            retrieval: RAGAnswerRetrievalSummary(
                originalQuestion: retrievalResult.originalQuestion,
                searchQuery: retrievalResult.searchQuery,
                candidatesBeforeFiltering: retrievalResult.candidatesBeforeFiltering.count,
                chunksAfterFiltering: retrievalResult.chunksAfterFiltering.count,
                bestScore: sources.map(\.relevanceScore).max()
            ),
            chunks: includeChunks ? sources.map(RAGAnswerChunk.init) : nil
        )
    }

    private func makeContract(
        from sources: [RAGRetrievedChunk],
        bestScore: Double?,
        threshold: Double,
        maxQuoteCharacters: Int
    ) -> RAGAnswerContract {
        guard let bestScore, bestScore >= threshold, !sources.isEmpty else {
            return RAGAnswerContract(
                answer: "Не знаю. В найденном контексте недостаточно релевантной информации, чтобы ответить уверенно.",
                sources: [],
                quotes: [],
                isUnknown: true,
                clarificationRequest: "Уточните вопрос или добавьте более релевантные документы в RAG индекс."
            )
        }

        let sourceItems = sources.map {
            RAGAnswerSource(
                source: $0.chunk.title,
                section: $0.chunk.section,
                chunkID: $0.chunk.chunkId
            )
        }
        let quoteItems = sources.prefix(3).map {
            RAGAnswerQuote(
                source: $0.chunk.title,
                section: $0.chunk.section,
                chunkID: $0.chunk.chunkId,
                text: makeQuoteSnippet(from: $0.chunk.content, maxCharacters: maxQuoteCharacters)
            )
        }
        let titles = sourceItems
            .map { "\($0.source), section: \($0.section ?? "-"), chunk_id: \($0.chunkID)" }
            .joined(separator: "; ")

        return RAGAnswerContract(
            answer: "Найдены релевантные фрагменты локального RAG индекса: \(titles).",
            sources: sourceItems,
            quotes: quoteItems,
            isUnknown: false,
            clarificationRequest: nil
        )
    }

    private func normalizedSearchQuery(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeQuoteSnippet(from text: String, maxCharacters: Int) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let safeLimit = max(1, maxCharacters)
        guard normalized.count > safeLimit else {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: safeLimit)
        return String(normalized[..<endIndex])
    }
}
