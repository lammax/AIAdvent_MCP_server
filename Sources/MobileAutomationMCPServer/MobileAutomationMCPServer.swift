import Foundation
import Vapor
import MCP
import Shared
import System
internal import NIOFoundationCompat

private enum MobileAutomationError: LocalizedError {
    case executableNotFound(String)
    case invalidArgumentsConfiguration
    case upstreamStartupTimedOut
    case upstreamUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            "Claude in Mobile MCP executable was not found or is not executable: \(path)"
        case .invalidArgumentsConfiguration:
            "CLAUDE_IN_MOBILE_MCP_ARGUMENTS_JSON must be a JSON array of strings."
        case .upstreamStartupTimedOut:
            "Claude in Mobile MCP did not complete its MCP handshake within 10 seconds."
        case .upstreamUnavailable:
            "Claude in Mobile MCP process is unavailable."
        }
    }
}

private actor ClaudeInMobileMCPBridge {
    private var client: MCP.Client?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?

    deinit {
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func listTools() async throws -> [MCP.Tool] {
        let client = try await connectedClient()
        return try await client.listTools().tools
    }

    func callTool(
        name: String,
        arguments: [String: Value]?
    ) async throws -> CallTool.Result {
        let client = try await connectedClient()
        let result = try await client.callTool(name: name, arguments: arguments)
        return .init(content: result.content, isError: result.isError)
    }

    private func connectedClient() async throws -> MCP.Client {
        if let client, process?.isRunning == true {
            return client
        }

        await disconnect()

        let configuration = try Self.configuration()
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw MobileAutomationError.executableNotFound(configuration.executableURL.path)
        }

        let serverInput = Pipe()
        let serverOutput = Pipe()
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]) { current, _ in current }
        process.standardInput = serverInput
        process.standardOutput = serverOutput
        process.standardError = FileHandle.standardError
        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: serverOutput.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: serverInput.fileHandleForWriting.fileDescriptor)
        )
        let client = MCP.Client(
            name: "workharness-mobile-automation-bridge",
            version: "1.0.0"
        )

        self.process = process
        self.inputPipe = serverInput
        self.outputPipe = serverOutput

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await client.connect(transport: transport)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw MobileAutomationError.upstreamStartupTimedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await disconnect()
            throw error
        }

        guard process.isRunning else {
            await disconnect()
            throw MobileAutomationError.upstreamUnavailable
        }

        self.client = client
        return client
    }

    private func disconnect() async {
        if let client {
            await client.disconnect()
        }
        if process?.isRunning == true {
            process?.terminate()
        }
        client = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
    }

    private static func configuration() throws -> (
        executableURL: URL,
        arguments: [String]
    ) {
        let environment = ProcessInfo.processInfo.environment
        let executablePath = environment["CLAUDE_IN_MOBILE_MCP_COMMAND"]
            ?? defaultNPXPath()
        let arguments: [String]

        if let rawArguments = environment["CLAUDE_IN_MOBILE_MCP_ARGUMENTS_JSON"] {
            guard let data = rawArguments.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                throw MobileAutomationError.invalidArgumentsConfiguration
            }
            arguments = decoded
        } else {
            // `--offline` guarantees the bridge never installs a package as a hidden side effect.
            arguments = ["--offline", "claude-in-mobile"]
        }

        return (URL(fileURLWithPath: executablePath), arguments)
    }

    private static func defaultNPXPath() -> String {
        [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx"
        ].first(where: FileManager.default.isExecutableFile(atPath:))
            ?? "/opt/homebrew/bin/npx"
    }
}

private func makeMobileAutomationMCPServer(
    bridge: ClaudeInMobileMCPBridge
) async -> MCP.Server {
    let server = Server(
        name: "mobile-automation-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        do {
            return .init(tools: try await bridge.listTools())
        } catch {
            return .init(tools: [])
        }
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            return try await bridge.callTool(
                name: params.name,
                arguments: params.arguments
            )
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

@main
enum MobileAutomationMCPServer {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)

        let app = try await Application.make(environment)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3009

        let bridge = ClaudeInMobileMCPBridge()
        let mcpServer = await makeMobileAutomationMCPServer(bridge: bridge)
        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in "OK" }
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
