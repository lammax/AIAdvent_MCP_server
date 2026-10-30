import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

private struct ApprovalToolOutput: Codable, Sendable {
    let requestId: UUID
    let status: ApprovalStatus
    let answers: [ApprovalToolAnswer]
    let response: String?
    let responses: [String]
}

private struct ApprovalToolAnswer: Codable, Sendable {
    let id: String
    let type: ApprovalKind
    let response: String?
    let responses: [String]
}

private enum ToolInputError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

private func parseQuestions(arguments: [String: MCP.Value]?) throws -> [ApprovalQuestion] {
    if let questionsValue = arguments?["questions"] {
        guard let values = questionsValue.arrayValue else {
            throw ToolInputError.invalid("Questions must be an array.")
        }
        return try values.map { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let question = object["question"]?.stringValue,
                  let rawType = object["type"]?.stringValue,
                  let kind = ApprovalKind(rawValue: rawType)
            else {
                throw ToolInputError.invalid(
                    "Every question requires string id, question, and valid type fields."
                )
            }
            return ApprovalQuestion(
                id: id,
                question: question,
                kind: kind,
                options: try parseOptions(object["options"])
            )
        }
    }

    guard let question = arguments?["question"]?.stringValue else {
        throw ToolInputError.invalid("Provide questions or the legacy question field.")
    }
    let rawMode = arguments?["mode"]?.stringValue ?? ApprovalKind.singleSelect.rawValue
    guard let kind = ApprovalKind(rawValue: rawMode) else {
        throw ToolInputError.invalid("Unknown answer mode: \(rawMode)")
    }
    return [
        ApprovalQuestion(
            id: "answer",
            question: question,
            kind: kind,
            options: try parseOptions(arguments?["options"])
        )
    ]
}

private func parseOptions(_ value: MCP.Value?) throws -> [String] {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue else {
        throw ToolInputError.invalid("Options must be an array of strings.")
    }
    let options = rawOptions.compactMap(\.stringValue)
    guard options.count == rawOptions.count else {
        throw ToolInputError.invalid("Every option must be a string.")
    }
    return options
}

private func httpAuthority(host: String, port: Int) -> String {
    let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return "\(formattedHost):\(port)"
}

private func makeRemoteMCPServer(service: ApprovalService) async -> MCP.Server {
    let server = Server(
        name: "remote-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "ask_user",
                description: "Ask one or more questions in a single remote request. Each question can be single-select, multi-select, or free text. Waits for the human response and never invents an answer. Prefer the questions array; legacy question/mode/options fields remain supported.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "questions": .object([
                            "type": .string("array"),
                            "minItems": .int(1),
                            "maxItems": .int(12),
                            "description": .string("Questions shown together and submitted in one response."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object([
                                        "type": .string("string"),
                                        "description": .string("Unique stable ID used to match the answer.")
                                    ]),
                                    "question": .object([
                                        "type": .string("string")
                                    ]),
                                    "type": .object([
                                        "type": .string("string"),
                                        "enum": .array([
                                            .string(ApprovalKind.singleSelect.rawValue),
                                            .string(ApprovalKind.multiSelect.rawValue),
                                            .string(ApprovalKind.text.rawValue)
                                        ])
                                    ]),
                                    "options": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("string")]),
                                        "maxItems": .int(12),
                                        "description": .string("Required for selection types; omit for text.")
                                    ])
                                ]),
                                "required": .array([
                                    .string("id"), .string("question"), .string("type")
                                ]),
                                "additionalProperties": .bool(false)
                            ])
                        ]),
                        "question": .object([
                            "type": .string("string"),
                            "description": .string("Legacy single-question form.")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string(ApprovalKind.singleSelect.rawValue),
                                .string(ApprovalKind.multiSelect.rawValue),
                                .string(ApprovalKind.text.rawValue)
                            ]),
                            "default": .string(ApprovalKind.singleSelect.rawValue),
                            "description": .string("Answer type. Omit for a single selection.")
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "maxItems": .int(12),
                            "description": .string("Required for selection modes (2-12 unique options); omit for text mode.")
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "ask_user" else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let approval = try await service.createAndWait(
                questions: try parseQuestions(arguments: params.arguments)
            )
            let answers = approval.questions.map {
                ApprovalToolAnswer(
                    id: $0.id,
                    type: $0.kind,
                    response: $0.response,
                    responses: $0.responses
                )
            }
            let output = ApprovalToolOutput(
                requestId: approval.id,
                status: approval.status,
                answers: answers,
                response: approval.response,
                responses: approval.responses
            )
            let summary = answers.map {
                "\($0.id): \($0.responses.joined(separator: ", "))"
            }.joined(separator: "\n")
            return try .init(
                content: [
                    .text(
                        text: summary,
                        annotations: nil,
                        _meta: nil
                    )
                ],
                structuredContent: output,
                isError: false
            )
        } catch let error as ToolInputError {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch let error as ApprovalError {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch is CancellationError {
            return .init(
                content: [.text(text: "Approval request was cancelled.", annotations: nil, _meta: nil)],
                isError: true
            )
        } catch {
            return .init(
                content: [.text(text: "Approval request failed.", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

@main
enum RemoteMCPServer {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().contains("--stdio") {
            try await runStdioServer()
            return
        }

        let configuration = try RemoteConfiguration.load()

        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = configuration.host
        app.http.server.configuration.port = configuration.port

        let repository = try SQLiteApprovalRepository(path: configuration.databasePath)
        let service = ApprovalService(repository: repository, timeout: configuration.timeout)
        let claudeService = RemoteClaudeJobService(
            repository: repository,
            runner: ClaudeCLIRunner(executablePath: configuration.claudeExecutablePath),
            workingDirectory: configuration.claudeWorkingDirectory
        )
        try await claudeService.start()
        let authorization = ApprovalHTTPAuthorization(token: configuration.token)
        configureApprovalHTTPRoutes(
            app: app,
            service: service,
            authorization: authorization,
            claudeService: claudeService
        )

        let mcpServer = await makeRemoteMCPServer(service: service)
        let authority = httpAuthority(host: configuration.host, port: configuration.port)
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator(
                    allowedHosts: [authority],
                    allowedOrigins: ["http://\(authority)"]
                ),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
        try await mcpServer.start(transport: transport)

        app.on(.POST, "mcp") { request async throws -> Vapor.Response in
            guard authorization.isBearerAuthorized(request) else {
                throw Abort(.unauthorized, reason: "Bearer authorization is required.")
            }
            let httpRequest = HTTPRequest(
                method: "POST",
                headers: mcpHeaders(from: request.headers),
                body: Data(buffer: request.body.data ?? ByteBuffer())
            )
            return vaporResponse(from: await transport.handleRequest(httpRequest))
        }

        try await app.execute()
    }

    private static func runStdioServer() async throws {
        let configuration = try RemoteServiceConfiguration.load()
        let repository = try SQLiteApprovalRepository(path: configuration.databasePath)
        let service = ApprovalService(repository: repository, timeout: configuration.timeout)
        let server = await makeRemoteMCPServer(service: service)
        let transport = StdioTransport()

        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
