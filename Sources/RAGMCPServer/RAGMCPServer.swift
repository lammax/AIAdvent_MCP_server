import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

func makeRAGMCPServer() async -> MCP.Server {
    let server = Server(
        name: "rag-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "rag_index_zip",
                    description: "Build a local RAG index from a zip archive.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "zip_path": .object([
                                "type": .string("string"),
                                "description": .string("Absolute path to a .zip archive.")
                            ]),
                            "strategy": .object([
                                "type": .string("string"),
                                "enum": .array([.string("fixedTokens"), .string("structure")])
                            ]),
                            "replace_existing": .object([
                                "type": .string("boolean")
                            ]),
                            "allowed_extensions": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ]),
                            "chunk_size": .object([
                                "type": .string("integer")
                            ]),
                            "overlap": .object([
                                "type": .string("integer")
                            ]),
                            "max_characters": .object([
                                "type": .string("integer")
                            ])
                        ]),
                        "required": .array([.string("zip_path")])
                    ])
                ),
                Tool(
                    name: "rag_answer",
                    description: "Return an extractive answer from the local RAG index with sources and quotes.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "question": .object([
                                "type": .string("string")
                            ]),
                            "search_query": .object([
                                "type": .string("string"),
                                "description": .string("Optional retrieval query. Defaults to question.")
                            ]),
                            "strategy": .object([
                                "type": .string("string"),
                                "enum": .array([.string("fixedTokens"), .string("structure")])
                            ]),
                            "retrieval_mode": .object([
                                "type": .string("string"),
                                "enum": .array([.string("basic"), .string("enhanced")])
                            ]),
                            "top_k_before_filtering": .object([
                                "type": .string("integer")
                            ]),
                            "top_k_after_filtering": .object([
                                "type": .string("integer")
                            ]),
                            "similarity_threshold": .object([
                                "type": .string("number")
                            ]),
                            "relevance_filter_mode": .object([
                                "type": .string("string"),
                                "enum": .array([.string("disabled"), .string("similarityThreshold"), .string("heuristic")])
                            ]),
                            "include_chunks": .object([
                                "type": .string("boolean")
                            ]),
                            "max_quote_characters": .object([
                                "type": .string("integer")
                            ])
                        ]),
                        "required": .array([.string("question")])
                    ])
                ),
                Tool(
                    name: "rag_clear_index",
                    description: "Delete all stored chunks from the local RAG index database.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "rag_index_zip":
                let options = try makeIndexingOptions(from: params.arguments)
                let zipPath = try requiredString("zip_path", from: params.arguments)
                let service = try DocumentIndexingService()
                let summary = try await service.index(
                    zipURL: URL(fileURLWithPath: NSString(string: zipPath).expandingTildeInPath),
                    options: options
                )

                return try jsonToolResult(summary)

            case "rag_answer":
                let request = try makeAnswerRequest(from: params.arguments)
                let service = try RAGAnswerService()
                let run = try await service.answer(
                    question: request.question,
                    searchQuery: request.searchQuery,
                    retrievalMode: request.retrievalMode,
                    strategy: request.strategy,
                    settings: request.settings,
                    includeChunks: request.includeChunks,
                    maxQuoteCharacters: request.maxQuoteCharacters
                )

                return try jsonToolResult(run)

            case "rag_clear_index":
                let repository = try RAGIndexRepository()
                try await repository.deleteAll()

                return try jsonToolResult(RAGClearIndexResult(
                    deleted: true,
                    databasePath: repository.databasePath
                ))

            default:
                return .init(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

private struct AnswerRequest {
    let question: String
    let searchQuery: String?
    let strategy: RAGChunkingStrategy
    let retrievalMode: RAGRetrievalMode
    let settings: RAGRetrievalSettings
    let includeChunks: Bool
    let maxQuoteCharacters: Int
}

private struct RAGClearIndexResult: Encodable {
    let deleted: Bool
    let databasePath: String
}

private func makeIndexingOptions(from arguments: [String: Value]?) throws -> RAGIndexingOptions {
    let strategy = try optionalStrategy(from: arguments) ?? .fixedTokens
    return RAGIndexingOptions(
        strategy: strategy,
        replaceExisting: boolValue("replace_existing", from: arguments) ?? true,
        allowedExtensions: stringArrayValue("allowed_extensions", from: arguments) ?? ["swift", "md", "txt", "json"],
        chunkSize: intValue("chunk_size", from: arguments) ?? 500,
        overlap: intValue("overlap", from: arguments) ?? 50,
        maxCharacters: intValue("max_characters", from: arguments) ?? 1_200
    )
}

private func makeAnswerRequest(from arguments: [String: Value]?) throws -> AnswerRequest {
    let question = try requiredString("question", from: arguments)
    let strategy = try optionalStrategy(from: arguments) ?? .fixedTokens
    let retrievalMode = try optionalRetrievalMode(from: arguments) ?? .enhanced
    let topKAfter = intValue("top_k_after_filtering", from: arguments) ?? 5
    let topKBeforeDefault = retrievalMode == .basic ? topKAfter : 12
    let settings = RAGRetrievalSettings(
        topKBeforeFiltering: intValue("top_k_before_filtering", from: arguments) ?? topKBeforeDefault,
        topKAfterFiltering: topKAfter,
        similarityThreshold: doubleValue("similarity_threshold", from: arguments) ?? 0.25,
        relevanceFilterMode: try optionalRelevanceFilterMode(from: arguments) ?? .similarityThreshold
    )

    return AnswerRequest(
        question: question,
        searchQuery: stringValue("search_query", from: arguments),
        strategy: strategy,
        retrievalMode: retrievalMode,
        settings: settings,
        includeChunks: boolValue("include_chunks", from: arguments) ?? false,
        maxQuoteCharacters: intValue("max_quote_characters", from: arguments) ?? 240
    )
}

private func jsonToolResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return .init(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: false
    )
}

private func requiredString(_ key: String, from arguments: [String: Value]?) throws -> String {
    guard let value = stringValue(key, from: arguments), !value.isEmpty else {
        throw RAGToolError.missingParameter(key)
    }

    return value
}

private func optionalStrategy(from arguments: [String: Value]?) throws -> RAGChunkingStrategy? {
    guard let raw = stringValue("strategy", from: arguments) else {
        return nil
    }

    guard let strategy = RAGChunkingStrategy(rawValue: raw) else {
        throw RAGToolError.invalidParameter("strategy", raw)
    }

    return strategy
}

private func optionalRetrievalMode(from arguments: [String: Value]?) throws -> RAGRetrievalMode? {
    guard let raw = stringValue("retrieval_mode", from: arguments) else {
        return nil
    }

    guard let mode = RAGRetrievalMode(rawValue: raw) else {
        throw RAGToolError.invalidParameter("retrieval_mode", raw)
    }

    return mode
}

private func optionalRelevanceFilterMode(from arguments: [String: Value]?) throws -> RAGRelevanceFilterMode? {
    guard let raw = stringValue("relevance_filter_mode", from: arguments) else {
        return nil
    }

    guard let mode = RAGRelevanceFilterMode(rawValue: raw) else {
        throw RAGToolError.invalidParameter("relevance_filter_mode", raw)
    }

    return mode
}

private func stringValue(_ key: String, from arguments: [String: Value]?) -> String? {
    arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func intValue(_ key: String, from arguments: [String: Value]?) -> Int? {
    if let int = arguments?[key]?.intValue {
        return int
    }

    if let double = arguments?[key]?.doubleValue {
        return Int(double)
    }

    if let string = arguments?[key]?.stringValue {
        return Int(string)
    }

    return nil
}

private func doubleValue(_ key: String, from arguments: [String: Value]?) -> Double? {
    if let double = arguments?[key]?.doubleValue {
        return double
    }

    if let int = arguments?[key]?.intValue {
        return Double(int)
    }

    if let string = arguments?[key]?.stringValue {
        return Double(string)
    }

    return nil
}

private func boolValue(_ key: String, from arguments: [String: Value]?) -> Bool? {
    if let bool = arguments?[key]?.boolValue {
        return bool
    }

    if let string = arguments?[key]?.stringValue?.lowercased() {
        switch string {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    return nil
}

private func stringArrayValue(_ key: String, from arguments: [String: Value]?) -> [String]? {
    arguments?[key]?.arrayValue?.compactMap { $0.stringValue }
}

private enum RAGToolError: LocalizedError {
    case missingParameter(String)
    case invalidParameter(String, String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "Missing parameter: \(name)"
        case .invalidParameter(let name, let value):
            return "Invalid parameter \(name): \(value)"
        }
    }
}

@main
enum RAGMCPServer {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3003

        let mcpServer = await makeRAGMCPServer()
        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in
            "OK"
        }

        app.on(.POST, "mcp") { req async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "POST",
                headers: mcpHeaders(from: req.headers),
                body: Data(buffer: req.body.data ?? ByteBuffer())
            )

            let httpResponse = await transport.handleRequest(httpRequest)
            return vaporResponse(from: httpResponse)
        }

        try await app.execute()
    }
}
