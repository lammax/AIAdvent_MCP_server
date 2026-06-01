import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

// MARK: - Models

struct VisionDetectedObject: Codable, Equatable {
    let id: UUID?
    let label: String
    let confidence: Float
    let boundingBox: VisionBoundingBox?
}

struct VisionBoundingBox: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct VisionScene: Codable, Equatable {
    let id: UUID?
    let createdAt: Date?
    let objects: [VisionDetectedObject]
    let userNote: String?
}

struct VisionAskRequest: Content, Codable, Equatable {
    let question: String
    let scene: VisionScene
}

struct VisionAskResponse: Content, Codable, Equatable {
    let answer: String
    let highlightLabel: String?
}

// MARK: - Reasoning

struct VisionReasoningService: Sendable {
    let ollamaClient: OllamaVisionClient?

    func ask(_ request: VisionAskRequest) async -> VisionAskResponse {
        let prompt = VisionPromptBuilder().buildPrompt(
            question: request.question,
            scene: request.scene
        )

        if let ollamaClient {
            do {
                return try await ollamaClient.ask(prompt: prompt)
            } catch {
                // Keep the mobile demo usable when Ollama is offline or returns malformed JSON.
            }
        }

        return deterministicResponse(for: request)
    }

    private func deterministicResponse(for request: VisionAskRequest) -> VisionAskResponse {
        let normalizedQuestion = request.question.lowercased()
        let objects = request.scene.objects.sorted { $0.confidence > $1.confidence }
        let matchedObject = objects.first { object in
            normalizedQuestion.contains(object.label.lowercased())
        } ?? objects.first

        guard let matchedObject else {
            return VisionAskResponse(
                answer: "I do not see enough objects in the scanned scene yet.",
                highlightLabel: nil
            )
        }

        return VisionAskResponse(
            answer: "The most relevant object appears to be \(matchedObject.label) with \(Int(matchedObject.confidence * 100))% confidence.",
            highlightLabel: matchedObject.label
        )
    }
}

struct VisionPromptBuilder {
    func buildPrompt(question: String, scene: VisionScene) -> String {
        let objectLines = scene.objects
            .enumerated()
            .map { index, object in
                "\(index + 1). \(object.label), confidence \(formattedConfidence(object.confidence)), position: \(positionDescription(for: object.boundingBox))"
            }
            .joined(separator: "\n")

        return """
        You are AIChallenge Vision Assistant.

        User question:
        \(question)

        Detected objects:
        \(objectLines.isEmpty ? "No objects detected." : objectLines)

        Return strict JSON only:
        {
          "answer": "...",
          "highlightLabel": "object label or null"
        }
        """
    }

    private func formattedConfidence(_ confidence: Float) -> String {
        String(format: "%.2f", confidence)
    }

    private func positionDescription(for boundingBox: VisionBoundingBox?) -> String {
        guard let boundingBox else {
            return "unknown"
        }

        let centerX = boundingBox.x + boundingBox.width / 2
        let centerY = boundingBox.y + boundingBox.height / 2

        let horizontal: String
        switch centerX {
        case ..<0.33:
            horizontal = "left"
        case 0.33..<0.66:
            horizontal = "center"
        default:
            horizontal = "right"
        }

        let vertical: String
        switch centerY {
        case ..<0.33:
            vertical = "top"
        case 0.33..<0.66:
            vertical = "middle"
        default:
            vertical = "bottom"
        }

        return "\(horizontal)-\(vertical)"
    }
}

// MARK: - Ollama

struct OllamaVisionClient: Sendable {
    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let format: String
    }

    struct ChatResponse: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let baseURL: URL
    let model: String

    func ask(prompt: String) async throws -> VisionAskResponse {
        let endpoint = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: "Return strict JSON only. Do not include Markdown fences or explanatory prose."
                ),
                .init(role: "user", content: prompt)
            ],
            stream: false,
            format: "json"
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw Abort(.badGateway, reason: "Ollama returned an invalid response.")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = try normalizedJSON(from: chatResponse.message.content)
        let jsonData = Data(content.utf8)
        return try JSONDecoder().decode(VisionAskResponse.self, from: jsonData)
    }

    private func normalizedJSON(from content: String) throws -> String {
        let trimmedContent = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedContent.hasPrefix("{"), trimmedContent.hasSuffix("}") {
            return trimmedContent
        }

        guard let startIndex = trimmedContent.firstIndex(of: "{"),
              let endIndex = trimmedContent.lastIndex(of: "}") else {
            throw Abort(.badGateway, reason: "Ollama did not return JSON.")
        }

        return String(trimmedContent[startIndex...endIndex])
    }
}

// MARK: - MCP

func makeVisionMCPServer(reasoningService: VisionReasoningService) async -> MCP.Server {
    let server = Server(
        name: "vision-backend-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "vision_ask",
                    description: "Answer a question about a detected AR scene. The scene_json argument must match the /vision/ask request scene shape.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "question": .object([
                                "type": .string("string")
                            ]),
                            "scene_json": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("question"),
                            .string("scene_json")
                        ])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "vision_ask" else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let question = try requiredString("question", from: params.arguments)
            let sceneJSON = try requiredString("scene_json", from: params.arguments)
            let scene = try JSONDecoder().decode(VisionScene.self, from: Data(sceneJSON.utf8))
            let response = await reasoningService.ask(VisionAskRequest(question: question, scene: scene))
            return try jsonToolResult(response)
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
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
    guard let value = arguments?[key]?.stringValue, !value.isEmpty else {
        throw Abort(.badRequest, reason: "Missing parameter: \(key)")
    }

    return value
}

// MARK: - Runtime

struct VisionBackendRuntimeConfiguration {
    let host: String
    let port: Int
    let ollamaBaseURL: URL?
    let ollamaModel: String?

    static func make() -> VisionBackendRuntimeConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["VISION_BACKEND_HOST"] ?? "0.0.0.0"
        let port = Int(environment["VISION_BACKEND_PORT"] ?? "") ?? 3006
        let ollamaBaseURL = URL(
            string: environment["VISION_OLLAMA_BASE_URL"] ?? "http://127.0.0.1:11434"
        )
        let rawOllamaModel = environment["VISION_OLLAMA_MODEL"] ?? environment["OLLAMA_MODEL"] ?? "llama3:latest"
        let ollamaModel = rawOllamaModel.isEmpty ? nil : rawOllamaModel

        return VisionBackendRuntimeConfiguration(
            host: host,
            port: port,
            ollamaBaseURL: ollamaBaseURL,
            ollamaModel: ollamaModel
        )
    }
}

@main
enum VisionBackendServer {
    static func main() async throws {
        let configuration = VisionBackendRuntimeConfiguration.make()
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = configuration.host
        app.http.server.configuration.port = configuration.port

        let ollamaClient: OllamaVisionClient?
        if let ollamaBaseURL = configuration.ollamaBaseURL,
           let ollamaModel = configuration.ollamaModel {
            ollamaClient = OllamaVisionClient(
                baseURL: ollamaBaseURL,
                model: ollamaModel
            )
        } else {
            ollamaClient = nil
        }

        let reasoningService = VisionReasoningService(ollamaClient: ollamaClient)
        let mcpServer = await makeVisionMCPServer(reasoningService: reasoningService)
        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in
            "OK"
        }

        app.post("vision", "ask") { req async throws -> VisionAskResponse in
            let request = try req.content.decode(VisionAskRequest.self)
            return await reasoningService.ask(request)
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
