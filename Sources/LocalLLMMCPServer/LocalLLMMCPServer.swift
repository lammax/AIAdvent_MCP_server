import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

// MARK: - Configuration

struct LocalLLMConfiguration: Sendable {
    let host: String
    let port: Int
    let upstreamBaseURL: URL
    let apiKey: String
    let modelAlias: String
    let contextSize: Int
    let maxGeneratedTokens: Int

    static func load(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalLLMConfiguration {
        let host = stringValue("LOCAL_LLM_MCP_HOST", in: environment, defaultValue: "127.0.0.1")
        let port = intValue("LOCAL_LLM_MCP_PORT", in: environment, defaultValue: 3007)
        let upstreamBaseURL = URL(string: stringValue("LOCAL_LLM_BASE_URL", in: environment, defaultValue: "http://127.0.0.1:8080/v1"))!
        let apiKey = stringValue("LOCAL_LLM_API_KEY", in: environment, defaultValue: "change-me")
        let modelAlias = stringValue("LOCAL_LLM_MODEL_ALIAS", in: environment, defaultValue: "local-private")
        let contextSize = intValue("LOCAL_LLM_CONTEXT_TOKENS", in: environment, defaultValue: 16_384)
        let maxGeneratedTokens = intValue("LOCAL_LLM_MAX_OUTPUT_TOKENS", in: environment, defaultValue: 2_048)

        return LocalLLMConfiguration(
            host: host,
            port: port,
            upstreamBaseURL: upstreamBaseURL,
            apiKey: apiKey,
            modelAlias: modelAlias,
            contextSize: contextSize,
            maxGeneratedTokens: maxGeneratedTokens
        )
    }

    private static func stringValue(_ key: String, in environment: [String: String], defaultValue: String) -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return defaultValue
        }
        return value
    }

    private static func intValue(_ key: String, in environment: [String: String], defaultValue: Int) -> Int {
        guard let rawValue = environment[key], let value = Int(rawValue) else {
            return defaultValue
        }
        return value
    }
}

// MARK: - Models

struct LocalLLMModelSummary: Encodable {
    let id: String
    let displayName: String
    let provider: String
    let contextWindowTokens: Int
    let maxOutputTokens: Int
    let supportsStreaming: Bool
}

struct LocalLLMGenerateResult: Encodable {
    let model: String
    let content: String
    let finishReason: String?
    let usage: LocalLLMUsage?
}

struct LocalLLMHealthResult: Encodable {
    let reachable: Bool
    let baseURL: String
    let model: String
    let error: String?
}

struct LocalLLMUsage: Codable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

// MARK: - OpenAI-compatible client

struct LocalLLMClient: Sendable {
    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        let max_tokens: Int?
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
        let usage: LocalLLMUsage?
    }

    let configuration: LocalLLMConfiguration

    func generate(messages: [ProviderLikeMessage], model: String?, temperature: Double?, maxTokens: Int?) async throws -> LocalLLMGenerateResult {
        let requestModel = model?.isEmpty == false ? model! : configuration.modelAlias
        let endpoint = configuration.upstreamBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: requestModel,
            messages: messages.map { .init(role: $0.role, content: $0.content) },
            stream: false,
            temperature: temperature,
            max_tokens: maxTokens ?? configuration.maxGeneratedTokens
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalLLMError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LocalLLMError.httpStatus(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw LocalLLMError.emptyResponse
        }

        return LocalLLMGenerateResult(
            model: requestModel,
            content: choice.message.content,
            finishReason: choice.finish_reason,
            usage: decoded.usage
        )
    }

    func health() async -> LocalLLMHealthResult {
        do {
            _ = try await generate(
                messages: [.init(role: "user", content: "Return the single word OK.")],
                model: configuration.modelAlias,
                temperature: 0,
                maxTokens: 8
            )
            return LocalLLMHealthResult(
                reachable: true,
                baseURL: configuration.upstreamBaseURL.absoluteString,
                model: configuration.modelAlias,
                error: nil
            )
        } catch {
            return LocalLLMHealthResult(
                reachable: false,
                baseURL: configuration.upstreamBaseURL.absoluteString,
                model: configuration.modelAlias,
                error: error.localizedDescription
            )
        }
    }
}

struct ProviderLikeMessage: Codable, Equatable {
    let role: String
    let content: String
}

enum LocalLLMError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse
    case missingMessages

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Local LLM returned an invalid HTTP response."
        case .httpStatus(let status, let body):
            return "Local LLM request failed with HTTP \(status): \(body)"
        case .emptyResponse:
            return "Local LLM returned no choices."
        case .missingMessages:
            return "Missing messages."
        }
    }
}

// MARK: - MCP server factory

func makeLocalLLMMCPServer(client: LocalLLMClient, configuration: LocalLLMConfiguration) async -> MCP.Server {
    let server = Server(
        name: "local-llm-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "local_llm_list_models",
                    description: "List local LLM models exposed by the configured OpenAI-compatible local endpoint.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),
                Tool(
                    name: "local_llm_describe_model",
                    description: "Describe the configured local LLM model capabilities.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "model": .object([
                                "type": .string("string"),
                                "description": .string("Optional model id. Defaults to the configured local model alias.")
                            ])
                        ])
                    ])
                ),
                Tool(
                    name: "local_llm_generate",
                    description: "Generate text with the configured local OpenAI-compatible LLM endpoint.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "messages": .object([
                                "type": .string("array"),
                                "items": .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "role": .object(["type": .string("string")]),
                                        "content": .object(["type": .string("string")])
                                    ]),
                                    "required": .array([.string("role"), .string("content")])
                                ])
                            ]),
                            "model": .object([
                                "type": .string("string")
                            ]),
                            "temperature": .object([
                                "type": .string("number")
                            ]),
                            "max_tokens": .object([
                                "type": .string("integer")
                            ])
                        ]),
                        "required": .array([.string("messages")])
                    ])
                ),
                Tool(
                    name: "local_llm_health",
                    description: "Check whether the configured local LLM endpoint can answer a tiny request.",
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
            case "local_llm_list_models":
                return try jsonToolResult([
                    LocalLLMModelSummary(
                        id: configuration.modelAlias,
                        displayName: "Local LLM",
                        provider: "llama.cpp-openai-compatible",
                        contextWindowTokens: configuration.contextSize,
                        maxOutputTokens: configuration.maxGeneratedTokens,
                        supportsStreaming: false
                    )
                ])

            case "local_llm_describe_model":
                return try jsonToolResult(LocalLLMModelSummary(
                    id: stringValue("model", from: params.arguments) ?? configuration.modelAlias,
                    displayName: "Local LLM",
                    provider: "llama.cpp-openai-compatible",
                    contextWindowTokens: configuration.contextSize,
                    maxOutputTokens: configuration.maxGeneratedTokens,
                    supportsStreaming: false
                ))

            case "local_llm_generate":
                let messages = try messagesValue("messages", from: params.arguments)
                let result = try await client.generate(
                    messages: messages,
                    model: stringValue("model", from: params.arguments),
                    temperature: doubleValue("temperature", from: params.arguments),
                    maxTokens: intValue("max_tokens", from: params.arguments)
                )
                return try jsonToolResult(result)

            case "local_llm_health":
                return try jsonToolResult(await client.health())

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

private func messagesValue(_ key: String, from arguments: [String: Value]?) throws -> [ProviderLikeMessage] {
    guard let values = arguments?[key]?.arrayValue, !values.isEmpty else {
        throw LocalLLMError.missingMessages
    }

    return values.compactMap { value in
        guard
            let object = value.objectValue,
            let role = object["role"]?.stringValue,
            let content = object["content"]?.stringValue
        else {
            return nil
        }
        return ProviderLikeMessage(role: role, content: content)
    }
}

private func stringValue(_ key: String, from arguments: [String: Value]?) -> String? {
    guard let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func intValue(_ key: String, from arguments: [String: Value]?) -> Int? {
    arguments?[key]?.intValue
}

private func doubleValue(_ key: String, from arguments: [String: Value]?) -> Double? {
    arguments?[key]?.doubleValue
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

// MARK: - Vapor <-> MCP bridge

@main
enum LocalLLMMCPServer {
    static func main() async throws {
        let configuration = LocalLLMConfiguration.load()
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = configuration.host
        app.http.server.configuration.port = configuration.port

        let client = LocalLLMClient(configuration: configuration)
        let mcpServer = await makeLocalLLMMCPServer(client: client, configuration: configuration)
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
