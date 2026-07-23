import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

private struct CommandResult: Codable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private enum DeveloperToolsError: LocalizedError {
    case missingParameter(String)
    case invalidProjectRoot(String)
    case unterminatedQuotedArgument
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            "Missing parameter: \(name)"
        case .invalidProjectRoot(let path):
            "Invalid project root: \(path)"
        case .unterminatedQuotedArgument:
            "Git arguments contain an unterminated quote."
        case .unsupportedPlatform:
            "Developer tools are available only on macOS."
        }
    }
}

private func makeDeveloperToolsMCPServer() async -> MCP.Server {
    let server = Server(
        name: "developer-tools-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "workspace_run_shell",
                description: "Run a shell command in an explicitly provided local project root.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to run.")
                        ]),
                        "project_root": .object([
                            "type": .string("string"),
                            "description": .string("Absolute local project root used as the working directory.")
                        ])
                    ]),
                    "required": .array([.string("command"), .string("project_root")])
                ])
            ),
            Tool(
                name: "workspace_run_git",
                description: "Run git with parsed arguments in an explicitly provided local project root.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "arguments": .object([
                            "type": .string("string"),
                            "description": .string("Git arguments, excluding the git executable.")
                        ]),
                        "project_root": .object([
                            "type": .string("string"),
                            "description": .string("Absolute local project root used as the working directory.")
                        ])
                    ]),
                    "required": .array([.string("arguments"), .string("project_root")])
                ])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            let projectRoot = try requiredProjectRoot(from: params.arguments)
            let result: CommandResult

            switch params.name {
            case "workspace_run_shell":
                result = try await runCommand(
                    executableURL: URL(fileURLWithPath: "/bin/bash"),
                    arguments: ["-lc", try requiredString("command", from: params.arguments)],
                    projectRoot: projectRoot
                )
            case "workspace_run_git":
                result = try await runCommand(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: try parseArguments(requiredString("arguments", from: params.arguments)),
                    projectRoot: projectRoot
                )
            default:
                return .init(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            return try commandToolResult(result)
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

private func requiredString(_ key: String, from arguments: [String: Value]?) throws -> String {
    guard let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        throw DeveloperToolsError.missingParameter(key)
    }
    return value
}

private func requiredProjectRoot(from arguments: [String: Value]?) throws -> URL {
    let path = try requiredString("project_root", from: arguments)
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard url.path == path || url.path == URL(fileURLWithPath: path).standardizedFileURL.path,
          FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw DeveloperToolsError.invalidProjectRoot(path)
    }
    return url
}

private func parseArguments(_ input: String) throws -> [String] {
    var arguments: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false

    for character in input {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character.isWhitespace {
            if !current.isEmpty {
                arguments.append(current)
                current = ""
            }
        } else {
            current.append(character)
        }
    }

    guard quote == nil else {
        throw DeveloperToolsError.unterminatedQuotedArgument
    }
    if escaped {
        current.append("\\")
    }
    if !current.isEmpty {
        arguments.append(current)
    }
    return arguments
}

private func runCommand(
    executableURL: URL,
    arguments: [String],
    projectRoot: URL
) async throws -> CommandResult {
    #if os(macOS)
    try await Task.detached {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperToolsMCPServer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = projectRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]) { current, _ in current }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()
        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }.value
    #else
    throw DeveloperToolsError.unsupportedPlatform
    #endif
}

private func commandToolResult(_ result: CommandResult) throws -> CallTool.Result {
    let data = try JSONEncoder().encode(result)
    let json = String(decoding: data, as: UTF8.self)
    return .init(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: result.exitCode != 0
    )
}

@main
enum DeveloperToolsMCPServer {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)

        let app = try await Application.make(environment)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3008

        let mcpServer = await makeDeveloperToolsMCPServer()
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
