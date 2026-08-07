//
// LLMGatewayMCPServer.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

private struct GatewayConfiguration: Sendable {
    let host: String
    let port: Int
    let rateLimitPerMinute: Int
    let auditLogURL: URL
    let upstream: LLMHTTPUpstreamConfiguration
    let costEstimator: LLMCostEstimator

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> GatewayConfiguration {
        let openAIInput = decimal("LLM_GATEWAY_OPENAI_INPUT_USD_PER_MILLION", environment: environment, fallback: 1)
        let openAIOutput = decimal("LLM_GATEWAY_OPENAI_OUTPUT_USD_PER_MILLION", environment: environment, fallback: 3)
        let anthropicInput = decimal("LLM_GATEWAY_ANTHROPIC_INPUT_USD_PER_MILLION", environment: environment, fallback: 3)
        let anthropicOutput = decimal("LLM_GATEWAY_ANTHROPIC_OUTPUT_USD_PER_MILLION", environment: environment, fallback: 15)
        return GatewayConfiguration(
            host: value("LLM_GATEWAY_HOST", environment: environment, fallback: "127.0.0.1"),
            port: Int(value("LLM_GATEWAY_PORT", environment: environment, fallback: "3013")) ?? 3013,
            rateLimitPerMinute: Int(value("LLM_GATEWAY_RATE_LIMIT_PER_MINUTE", environment: environment, fallback: "30")) ?? 30,
            auditLogURL: URL(fileURLWithPath: value(
                "LLM_GATEWAY_AUDIT_LOG",
                environment: environment,
                fallback: ".mcp_server/llm-gateway-audit.jsonl"
            )),
            upstream: LLMHTTPUpstreamConfiguration(
                openAIBaseURL: URL(string: value("OPENAI_BASE_URL", environment: environment, fallback: "https://api.openai.com/v1"))!,
                openAIAPIKey: environment["OPENAI_API_KEY"],
                anthropicBaseURL: URL(string: value("ANTHROPIC_BASE_URL", environment: environment, fallback: "https://api.anthropic.com/v1"))!,
                anthropicAPIKey: environment["ANTHROPIC_API_KEY"]
            ),
            costEstimator: LLMCostEstimator(
                prices: [
                    LLMModelPrice(modelPrefix: "gpt-", inputUSDPerMillionTokens: openAIInput, outputUSDPerMillionTokens: openAIOutput),
                    LLMModelPrice(modelPrefix: "o", inputUSDPerMillionTokens: openAIInput, outputUSDPerMillionTokens: openAIOutput),
                    LLMModelPrice(modelPrefix: "claude-", inputUSDPerMillionTokens: anthropicInput, outputUSDPerMillionTokens: anthropicOutput)
                ],
                fallback: LLMModelPrice(modelPrefix: "", inputUSDPerMillionTokens: openAIInput, outputUSDPerMillionTokens: openAIOutput)
            )
        )
    }

    private static func value(_ key: String, environment: [String: String], fallback: String) -> String {
        guard let candidate = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
            return fallback
        }
        return candidate
    }

    private static func decimal(_ key: String, environment: [String: String], fallback: Decimal) -> Decimal {
        guard let raw = environment[key], let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            return fallback
        }
        return value
    }
}

private enum GatewayServerError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        }
    }
}

private func makeGatewayMCPServer(service: LLMGatewayService) async -> MCP.Server {
    let server = Server(
        name: "llm-gateway-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "llm_gateway_generate",
                description: "Generate through the audited OpenAI/Anthropic gateway with input/output guards, rate limiting, token usage, and estimated cost.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "provider": .object(["type": .string("string"), "enum": .array([.string("openai"), .string("anthropic")])]),
                        "model": .object(["type": .string("string")]),
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
                        "guard_mode": .object(["type": .string("string"), "enum": .array([.string("block"), .string("mask")])]),
                        "temperature": .object(["type": .string("number")]),
                        "max_tokens": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("provider"), .string("model"), .string("messages")])
                ])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "llm_gateway_generate" else {
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
        do {
            let request = try gatewayRequest(arguments: params.arguments)
            let response = try await service.process(request, clientId: "mcp")
            return try jsonToolResult(response)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }
    return server
}

private func gatewayRequest(arguments: [String: Value]?) throws -> LLMGatewayRequest {
    guard let providerValue = arguments?["provider"]?.stringValue,
          let provider = LLMGatewayProvider(rawValue: providerValue),
          let model = arguments?["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !model.isEmpty,
          let rawMessages = arguments?["messages"]?.arrayValue else {
        throw GatewayServerError.invalidRequest("provider, model, and messages are required.")
    }
    let messages = rawMessages.compactMap { value -> LLMGatewayMessage? in
        guard let object = value.objectValue,
              let role = object["role"]?.stringValue,
              let content = object["content"]?.stringValue else { return nil }
        return LLMGatewayMessage(role: role, content: content)
    }
    guard !messages.isEmpty else { throw GatewayServerError.invalidRequest("messages must not be empty.") }
    let mode = arguments?["guard_mode"]?.stringValue.flatMap(LLMGatewayGuardMode.init(rawValue:)) ?? .block
    return LLMGatewayRequest(
        provider: provider,
        model: model,
        messages: messages,
        guardMode: mode,
        temperature: arguments?["temperature"]?.doubleValue,
        maxTokens: arguments?["max_tokens"]?.intValue
    )
}

private func jsonToolResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return .init(
        content: [.text(text: String(data: data, encoding: .utf8) ?? "{}", annotations: nil, _meta: nil)],
        isError: false
    )
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus) throws -> Vapor.Response {
    let data = try JSONEncoder().encode(value)
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return Response(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: .init(buffer: buffer)
    )
}

private struct ErrorResponse: Encodable {
    let warning: String
}

@main
enum LLMGatewayMCPServer {
    static func main() async throws {
        let configuration = GatewayConfiguration.load()
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        defer { Task { try? await app.asyncShutdown() } }

        app.http.server.configuration.hostname = configuration.host
        app.http.server.configuration.port = configuration.port

        let auditLogger = try LLMGatewayJSONLAuditLogger(fileURL: configuration.auditLogURL)
        let service = LLMGatewayService(
            upstream: LLMHTTPUpstream(configuration: configuration.upstream),
            auditLogger: auditLogger,
            rateLimiter: LLMRateLimiter(limit: configuration.rateLimitPerMinute),
            costEstimator: configuration.costEstimator
        )
        let mcpServer = await makeGatewayMCPServer(service: service)
        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in "OK" }

        app.on(.POST, "v1", "chat", "completions") { request async throws -> Vapor.Response in
            do {
                let data = Data(buffer: request.body.data ?? ByteBuffer())
                let gatewayRequest = try JSONDecoder().decode(LLMGatewayRequest.self, from: data)
                guard !gatewayRequest.messages.isEmpty, !gatewayRequest.model.isEmpty else {
                    throw GatewayServerError.invalidRequest("model and messages must not be empty.")
                }
                let clientId = request.remoteAddress?.ipAddress ?? "unknown"
                let response = try await service.process(gatewayRequest, clientId: clientId)
                let status: HTTPResponseStatus = switch response.status {
                case .completed: .ok
                case .blocked: .unprocessableEntity
                case .rateLimited: .tooManyRequests
                }
                return try jsonResponse(response, status: status)
            } catch let error as GatewayServerError {
                return try jsonResponse(ErrorResponse(warning: error.localizedDescription), status: .badRequest)
            } catch let error as DecodingError {
                return try jsonResponse(ErrorResponse(warning: "Invalid gateway request: \(error.localizedDescription)"), status: .badRequest)
            } catch {
                return try jsonResponse(ErrorResponse(warning: error.localizedDescription), status: .badGateway)
            }
        }

        app.on(.POST, "mcp") { request async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "POST",
                headers: mcpHeaders(from: request.headers),
                body: Data(buffer: request.body.data ?? ByteBuffer())
            )
            return vaporResponse(from: await transport.handleRequest(httpRequest))
        }

        try await app.execute()
    }
}
