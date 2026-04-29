import Foundation

public protocol RAGRelevanceFilteringServiceProtocol: Sendable {
    func filter(
        chunks: [RAGRetrievedChunk],
        question: String,
        settings: RAGRetrievalSettings
    ) async throws -> [RAGRetrievedChunk]
}

public final class RAGRelevanceFilteringService: RAGRelevanceFilteringServiceProtocol, @unchecked Sendable {
    public init() {}

    public func filter(
        chunks: [RAGRetrievedChunk],
        question: String,
        settings: RAGRetrievalSettings
    ) async throws -> [RAGRetrievedChunk] {
        guard settings.topKAfterFiltering > 0 else { return [] }

        let thresholded = chunks.filter { chunk in
            switch settings.relevanceFilterMode {
            case .disabled:
                return true
            case .similarityThreshold, .heuristic:
                return chunk.score >= settings.similarityThreshold
            }
        }

        let scored = thresholded.map { chunk in
            switch settings.relevanceFilterMode {
            case .disabled:
                return RAGRetrievedChunk(
                    chunk: chunk.chunk,
                    score: chunk.score,
                    relevanceScore: chunk.score,
                    relevanceReason: "kept without filtering"
                )
            case .similarityThreshold:
                return RAGRetrievedChunk(
                    chunk: chunk.chunk,
                    score: chunk.score,
                    relevanceScore: chunk.score,
                    relevanceReason: "score >= \(String(format: "%.2f", settings.similarityThreshold))"
                )
            case .heuristic:
                let heuristic = heuristicScore(for: chunk, question: question)
                return RAGRetrievedChunk(
                    chunk: chunk.chunk,
                    score: chunk.score,
                    relevanceScore: chunk.score + heuristic.value,
                    relevanceReason: heuristic.reason
                )
            }
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.relevanceScore == rhs.relevanceScore {
                    return lhs.score > rhs.score
                }

                return lhs.relevanceScore > rhs.relevanceScore
            }
            .prefix(settings.topKAfterFiltering)
            .map { $0 }
    }

    private func heuristicScore(
        for chunk: RAGRetrievedChunk,
        question: String
    ) -> (value: Double, reason: String) {
        let questionTerms = significantTerms(in: question)
        let contentTerms = significantTerms(in: chunk.chunk.content)
        let metadataTerms = significantTerms(in: "\(chunk.chunk.title) \(chunk.chunk.section)")

        let contentOverlap = questionTerms.intersection(contentTerms).count
        let metadataOverlap = questionTerms.intersection(metadataTerms).count

        var score = 0.0
        var reasons: [String] = ["score >= threshold"]

        if contentOverlap > 0 {
            let boost = min(Double(contentOverlap) * 0.03, 0.15)
            score += boost
            reasons.append("content overlap +\(String(format: "%.2f", boost))")
        }

        if metadataOverlap > 0 {
            let boost = min(Double(metadataOverlap) * 0.04, 0.12)
            score += boost
            reasons.append("metadata overlap +\(String(format: "%.2f", boost))")
        }

        if chunk.chunk.tokenCount < 20 {
            score -= 0.10
            reasons.append("short chunk -0.10")
        }

        return (score, reasons.joined(separator: ", "))
    }

    private func significantTerms(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "what", "when",
            "where", "which", "how", "are", "was", "were", "will", "can", "could",
            "should", "would", "into", "about", "after", "before", "using", "use",
            "что", "это", "как", "для", "или", "где", "при", "его", "она"
        ]

        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                word.count >= 3 && !stopWords.contains(word)
            }

        return Set(words)
    }
}
