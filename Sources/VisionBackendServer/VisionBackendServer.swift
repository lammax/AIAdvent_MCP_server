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

struct VisionReasoningResult: Sendable {
    let response: VisionAskResponse
    let source: String
    let model: String?
}

// MARK: - Reasoning

struct VisionReasoningService: Sendable {
    let ollamaClient: OllamaVisionClient?

    func ask(_ request: VisionAskRequest) async -> VisionReasoningResult {
        let prompt = VisionPromptBuilder().buildPrompt(
            question: request.question,
            scene: request.scene
        )

        if let ollamaClient {
            do {
                return VisionReasoningResult(
                    response: try await ollamaClient.ask(prompt: prompt),
                    source: "ollama",
                    model: ollamaClient.model
                )
            } catch {
                // Keep the mobile demo usable when Ollama is offline or returns malformed JSON.
            }
        }

        return VisionReasoningResult(
            response: deterministicResponse(for: request),
            source: "deterministic-fallback",
            model: nil
        )
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
                "\(index + 1). label: \(object.label), human name: \(humanName(for: object.label)), confidence: \(formattedConfidence(object.confidence)), position: \(positionDescription(for: object.boundingBox))"
            }
            .joined(separator: "\n")

        return """
        You are AIChallenge Vision Assistant.
        You answer questions about objects detected by an iPhone AR camera.

        User question:
        \(question)

        Detected objects:
        \(objectLines.isEmpty ? "No objects detected." : objectLines)

        Rules:
        - Return strict JSON only. No Markdown. No extra prose.
        - The answer must be a short, useful human sentence.
        - Answer in the same language as the user question.
        - Do not put only the object label in "answer".
        - Use a neutral assistant voice. Do not claim ownership of objects.
        - If the user says "my" or "мой", refer to the object neutrally by its name instead of saying "my".
        - Prefer wording like "The laptop appears..." or "Ноутбук находится..." instead of "my laptop" or "мой ноутбук".
        - If the user asks for an object that matches a detected label or human name, explain where it appears using the position.
        - "highlightLabel" must be exactly one detected object label, or null if there is no relevant object.
        - Use labels exactly as shown in Detected objects. For example, use "tvmonitor", not "monitor", for highlightLabel.

        JSON schema:
        {
          "answer": "Brief human answer.",
          "highlightLabel": "exact detected label or null"
        }
        """
    }

    private func formattedConfidence(_ confidence: Float) -> String {
        String(format: "%.2f", confidence)
    }

    private func humanName(for label: String) -> String {
        switch label.lowercased() {
        case "tvmonitor":
            return "monitor, screen, display, монитор, экран"
        case "cell phone":
            return "phone, smartphone, телефон"
        case "keyboard":
            return "keyboard, клавиатура"
        case "mouse":
            return "mouse, мышь"
        case "laptop":
            return "laptop, notebook, ноутбук"
        default:
            return label
        }
    }

    private func positionDescription(for boundingBox: VisionBoundingBox?) -> String {
        guard let boundingBox else {
            return "unknown"
        }

        let centerX = boundingBox.x + boundingBox.width / 2
        let centerY = boundingBox.y + boundingBox.height / 2

        let horizontal: String
        let russianHorizontal: String
        switch centerX {
        case ..<0.33:
            horizontal = "left"
            russianHorizontal = "левой"
        case 0.33..<0.66:
            horizontal = "center"
            russianHorizontal = "центральной"
        default:
            horizontal = "right"
            russianHorizontal = "правой"
        }

        let vertical: String
        let russianVertical: String
        switch centerY {
        case ..<0.33:
            vertical = "upper"
            russianVertical = "верхней"
        case 0.33..<0.66:
            vertical = "middle"
            russianVertical = "средней"
        default:
            vertical = "lower"
            russianVertical = "нижней"
        }

        return "\(vertical) \(horizontal) of the camera view / в \(russianVertical) \(russianHorizontal) части кадра"
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
            let result = await reasoningService.ask(VisionAskRequest(question: question, scene: scene))
            return try jsonToolResult(result.response)
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

private func prettyJSONString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    guard let data = try? encoder.encode(value),
          let json = String(data: data, encoding: .utf8) else {
        return "<failed to encode JSON>"
    }

    return json
}

private func requestBodyString(from request: Vapor.Request) -> String {
    guard let body = request.body.data else {
        return "<empty body>"
    }

    let data = Data(buffer: body)
    return String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
}

private func sceneSummary(_ scene: VisionScene) -> String {
    let objects = scene.objects
        .map { object in
            "\(object.label)(\(Int(object.confidence * 100))%, \(positionDescription(for: object.boundingBox)))"
        }
        .joined(separator: ", ")

    return objects.isEmpty ? "objects: none" : "objects: \(objects)"
}

private func positionDescription(for boundingBox: VisionBoundingBox?) -> String {
    guard let boundingBox else {
        return "unknown"
    }

    return "x:\(String(format: "%.2f", boundingBox.x)) y:\(String(format: "%.2f", boundingBox.y)) w:\(String(format: "%.2f", boundingBox.width)) h:\(String(format: "%.2f", boundingBox.height))"
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
            let startedAt = Date()
            let rawRequestBody = requestBodyString(from: req)
            req.logger.info("Vision request body:\n\(rawRequestBody)")

            let request: VisionAskRequest
            do {
                request = try req.content.decode(VisionAskRequest.self)
            } catch {
                req.logger.warning("Vision request decode failed: \(error.localizedDescription)")
                throw error
            }

            req.logger.info("Vision question: \(request.question)")
            req.logger.info("Vision scene summary: \(sceneSummary(request.scene))")

            let result = await reasoningService.ask(request)
            let elapsed = Date().timeIntervalSince(startedAt)
            let modelDescription = result.model.map { " \($0)" } ?? ""

            req.logger.info("Vision reasoning source: \(result.source)\(modelDescription), duration: \(String(format: "%.2fs", elapsed))")
            req.logger.info("Vision response body:\n\(prettyJSONString(result.response))")
            return result.response
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
