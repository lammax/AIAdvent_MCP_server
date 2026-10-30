import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

private struct ApprovalToolOutput: Codable, Sendable {
    let requestId: UUID
    let status: ApprovalStatus
    let response: String?
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
                description: "Ask the user to choose one of a bounded set of options. Waits for a remote human decision and never invents a choice.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "question": .object([
                            "type": .string("string"),
                            "description": .string("The decision the user needs to make.")
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "minItems": .int(2),
                            "maxItems": .int(12)
                        ])
                    ]),
                    "required": .array([.string("question"), .string("options")]),
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
        guard let question = params.arguments?["question"]?.stringValue,
              let rawOptions = params.arguments?["options"]?.arrayValue
        else {
            return .init(
                content: [.text(text: "Missing question or options.", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let options = rawOptions.compactMap(\.stringValue)
        guard options.count == rawOptions.count else {
            return .init(
                content: [.text(text: "Every option must be a string.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let approval = try await service.createAndWait(question: question, options: options)
            let output = ApprovalToolOutput(
                requestId: approval.id,
                status: approval.status,
                response: approval.response
            )
            return try .init(
                content: [
                    .text(
                        text: "User selected: \(approval.response ?? "")",
                        annotations: nil,
                        _meta: nil
                    )
                ],
                structuredContent: output,
                isError: false
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

        app.sessions.use(.memory)
        app.sessions.configuration = .init(cookieName: "remote-session") { sessionID in
            HTTPCookies.Value(
                string: sessionID.string,
                expires: Date(timeIntervalSinceNow: 60 * 60 * 24),
                maxAge: 60 * 60 * 24,
                domain: nil,
                path: "/",
                isSecure: false,
                isHTTPOnly: true,
                sameSite: .strict
            )
        }
        app.middleware.use(app.sessions.middleware)

        let repository = try SQLiteApprovalRepository(path: configuration.databasePath)
        let service = ApprovalService(repository: repository, timeout: configuration.timeout)
        let authorization = ApprovalHTTPAuthorization(token: configuration.token)
        configureApprovalHTTPRoutes(app: app, service: service, authorization: authorization)

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
