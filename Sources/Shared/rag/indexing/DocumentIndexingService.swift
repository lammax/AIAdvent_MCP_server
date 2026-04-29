import Foundation

public protocol DocumentIndexingServiceProtocol: Sendable {
    func index(zipURL: URL, options: RAGIndexingOptions) async throws -> RAGIndexingSummary
}

public final class DocumentIndexingService: DocumentIndexingServiceProtocol, @unchecked Sendable {
    private let embeddingService: EmbeddingServiceProtocol
    private let repository: RAGIndexRepositoryProtocol
    private let zipExtractor: ZipDocumentExtractorProtocol

    public init(
        embeddingService: EmbeddingServiceProtocol = LocalHashedEmbeddingService(),
        repository: RAGIndexRepositoryProtocol? = nil,
        zipExtractor: ZipDocumentExtractorProtocol = ZipDocumentExtractor()
    ) throws {
        self.embeddingService = embeddingService
        self.repository = try repository ?? RAGIndexRepository()
        self.zipExtractor = zipExtractor
    }

    public func index(zipURL: URL, options: RAGIndexingOptions) async throws -> RAGIndexingSummary {
        let startedAt = Date()
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw RAGIndexingError.fileNotFound(zipURL.path)
        }

        guard zipURL.pathExtension.lowercased() == "zip" else {
            throw RAGIndexingError.unsupportedArchive(zipURL.path)
        }

        let extractedDirectory = try zipExtractor.extract(zipURL)
        let documents = try loadDocumentsFromDirectory(
            extractedDirectory,
            allowedExtensions: options.allowedExtensions
        )

        let chunker: RAGChunker = switch options.strategy {
        case .fixedTokens:
            FixedTokenChunker(
                chunkSize: options.chunkSize,
                overlap: options.overlap,
                maxCharacters: options.maxCharacters
            )
        case .structure:
            StructureChunker(
                chunkSize: options.chunkSize,
                overlap: options.overlap,
                maxCharacters: options.maxCharacters
            )
        }

        let chunks = chunker.makeChunks(from: documents)
        let embeddings = try await embeddingService.embed(chunks.map(\.content))
        let embedded = zip(chunks, embeddings).map {
            RAGEmbeddedChunk(
                chunk: $0.0,
                embedding: $0.1,
                model: embeddingService.model
            )
        }

        if options.replaceExisting {
            try await repository.replace(strategy: options.strategy, chunks: embedded)
        } else {
            try await repository.append(chunks: embedded)
        }

        let counts = chunks.map(\.tokenCount)
        return RAGIndexingSummary(
            strategy: options.strategy,
            documentCount: documents.count,
            chunkCount: chunks.count,
            averageTokens: counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count),
            minTokens: counts.min() ?? 0,
            maxTokens: counts.max() ?? 0,
            embeddingModel: embeddingService.model,
            databasePath: repository.databasePath,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func loadDocumentsFromDirectory(
        _ directoryURL: URL,
        allowedExtensions: [String]
    ) throws -> [RAGSourceDocument] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let allowed = Set(allowedExtensions.map { $0.lowercased() })
        var documents: [RAGSourceDocument] = []

        for case let fileURL as URL in enumerator {
            if try isDirectory(fileURL) || shouldSkip(fileURL) {
                continue
            }

            guard allowed.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            documents.append(
                RAGSourceDocument(
                    url: fileURL,
                    title: fileURL.lastPathComponent,
                    content: try String(contentsOf: fileURL, encoding: .utf8)
                )
            )
        }

        return documents
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private func shouldSkip(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent

        return url.pathComponents.contains("__MACOSX")
            || fileName == ".DS_Store"
            || fileName.hasPrefix("._")
    }
}

public enum RAGIndexingError: LocalizedError {
    case fileNotFound(String)
    case unsupportedArchive(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Zip file not found: \(path)"
        case .unsupportedArchive(let path):
            return "Expected a .zip archive: \(path)"
        }
    }
}
