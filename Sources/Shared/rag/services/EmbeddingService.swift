import Foundation

public protocol EmbeddingServiceProtocol: Sendable {
    var model: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public struct LocalHashedEmbeddingService: EmbeddingServiceProtocol {
    public let model: String = "local-hash-v1"
    private let dimensions: Int

    public init(dimensions: Int = 384) {
        self.dimensions = dimensions
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map(makeEmbedding)
    }

    private func makeEmbedding(for text: String) -> [Float] {
        let terms = makeTerms(from: text)
        guard !terms.isEmpty else {
            return Array(repeating: 0, count: dimensions)
        }

        var vector = Array(repeating: Float(0), count: dimensions)

        for term in terms {
            let index = Int(stableHash(term) % UInt64(dimensions))
            let signSeed = stableHash(term + "#sign")
            let sign: Float = (signSeed & 1) == 0 ? 1 : -1
            let weight = sqrt(Float(max(1, term.count)))
            vector[index] += sign * weight
        }

        let norm = sqrt(vector.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func makeTerms(from text: String) -> [String] {
        let lowercased = text.lowercased()
        let pieces = lowercased.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let tokens = pieces.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        var terms = tokens
        for index in tokens.indices.dropLast() {
            terms.append(tokens[index] + "_" + tokens[index + 1])
        }

        return terms
    }

    private func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        return hash
    }
}
