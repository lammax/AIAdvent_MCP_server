import Foundation
import Vapor
import MCP
import Shared
import System
internal import NIOFoundationCompat

private enum MobileAutomationError: LocalizedError {
    case executableNotFound(String)
    case invalidImageData
    case invalidArgumentsConfiguration
    case invalidProjectRoot(String)
    case upstreamStartupTimedOut
    case upstreamUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            "Claude in Mobile MCP executable was not found or is not executable: \(path)"
        case .invalidImageData:
            "Claude in Mobile returned invalid base64 image data."
        case .invalidArgumentsConfiguration:
            "CLAUDE_IN_MOBILE_MCP_ARGUMENTS_JSON must be a JSON array of strings."
        case .invalidProjectRoot(let path):
            "The WorkHarness project root is not a directory: \(path)"
        case .upstreamStartupTimedOut:
            "Claude in Mobile MCP did not complete its MCP handshake within 10 seconds."
        case .upstreamUnavailable:
            "Claude in Mobile MCP process is unavailable."
        }
    }
}

private enum DiagnosticStatus: String, Codable {
    case ready
    case warning
    case unavailable
}

private struct DiagnosticCheck: Codable {
    let id: String
    let title: String
    let status: DiagnosticStatus
    let message: String
    let remediation: String?
}

private struct DiagnosticReport: Codable {
    let checkedAt: Date
    let checks: [DiagnosticCheck]
}

private struct WorkHarnessArtifactMarker: Codable {
    struct Artifact: Codable {
        let name: String
        let kind: String
        let path: String
        let mimeType: String
    }

    let workharnessArtifact: Artifact
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

    func diagnostics(webDriverAgent: WebDriverAgentReport) async -> DiagnosticReport {
        await Self.makeDiagnostics(webDriverAgent: webDriverAgent)
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
        if let executablePath = environment["CLAUDE_IN_MOBILE_MCP_COMMAND"] {
            let arguments: [String]
            if let rawArguments = environment["CLAUDE_IN_MOBILE_MCP_ARGUMENTS_JSON"] {
                guard let data = rawArguments.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                    throw MobileAutomationError.invalidArgumentsConfiguration
                }
                arguments = decoded
            } else {
                arguments = []
            }
            return (URL(fileURLWithPath: executablePath), arguments)
        }

        if let executablePath = installedClaudeInMobilePath() {
            return (URL(fileURLWithPath: executablePath), [])
        }

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

        return (URL(fileURLWithPath: defaultNPXPath()), arguments)
    }

    private static func defaultNPXPath() -> String {
        [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            "/usr/bin/npx"
        ].first(where: FileManager.default.isExecutableFile(atPath:))
            ?? "/opt/homebrew/bin/npx"
    }

    private static func makeDiagnostics(
        webDriverAgent: WebDriverAgentReport
    ) async -> DiagnosticReport {
        let configuration = try? configuration()
        let commandPath = configuration?.executableURL.path ?? defaultNPXPath()
        let commandAvailable = FileManager.default.isExecutableFile(atPath: commandPath)
        let installedPackagePath = installedClaudeInMobilePath()
        let packageAvailable = installedPackagePath != nil
            || cachedClaudeInMobilePackageAvailable()

        let xcode = await runCommand("/usr/bin/xcodebuild", ["-version"])
        let simctl = await runCommand(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "booted", "--json"]
        )
        let simulatorBooted = simctl.exitCode == 0
            && simctl.output.replacingOccurrences(of: " ", with: "").contains(#""state":"Booted""#)
        let appiumPath = executablePath(candidates: [
            "/opt/homebrew/bin/appium",
            "/usr/local/bin/appium",
            "/usr/bin/appium"
        ])
        let wdaPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent",
                isDirectory: true
            ).path
        let wdaAvailable = FileManager.default.fileExists(atPath: wdaPath)

        return DiagnosticReport(
            checkedAt: Date(),
            checks: [
                DiagnosticCheck(
                    id: "bridgeCommand",
                    title: "MCP bridge command",
                    status: commandAvailable ? .ready : .unavailable,
                    message: commandAvailable ? commandPath : "Executable not found at \(commandPath).",
                    remediation: commandAvailable ? nil : "Install Node.js/npm or configure CLAUDE_IN_MOBILE_MCP_COMMAND."
                ),
                DiagnosticCheck(
                    id: "claudeInMobile",
                    title: "Claude in Mobile",
                    status: packageAvailable ? .ready : .unavailable,
                    message: installedPackagePath
                        ?? (packageAvailable
                            ? "Package is available in the local npm cache."
                            : "Claude in Mobile is not installed."),
                    remediation: packageAvailable
                        ? nil
                        : "Install Claude in Mobile explicitly before running smoke tests."
                ),
                DiagnosticCheck(
                    id: "xcode",
                    title: "Xcode",
                    status: xcode.exitCode == 0 ? .ready : .unavailable,
                    message: xcode.exitCode == 0
                        ? xcode.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        : xcode.error,
                    remediation: xcode.exitCode == 0 ? nil : "Install/select Xcode and accept its license."
                ),
                DiagnosticCheck(
                    id: "simulator",
                    title: "iOS Simulator",
                    status: simulatorBooted ? .ready : .warning,
                    message: simulatorBooted ? "A booted iOS Simulator is available." : "No booted iOS Simulator was found.",
                    remediation: simulatorBooted ? nil : "Start the simulator selected by the Testing target before a smoke run."
                ),
                DiagnosticCheck(
                    id: "appium",
                    title: "Appium",
                    status: appiumPath == nil ? .warning : .ready,
                    message: appiumPath ?? "Appium executable was not found.",
                    remediation: appiumPath == nil ? "Install Appium when full iOS UI inspection is required." : nil
                ),
                DiagnosticCheck(
                    id: "webDriverAgent",
                    title: "WebDriverAgent",
                    status: (webDriverAgent.isPrepared || webDriverAgent.isRunning)
                        ? .ready
                        : (wdaAvailable ? .warning : .unavailable),
                    message: wdaAvailable
                        ? webDriverAgent.message
                        : "Appium WebDriverAgent was not found.",
                    remediation: (webDriverAgent.isPrepared || webDriverAgent.isRunning)
                        ? nil
                        : (wdaAvailable
                            ? "Call workharness_wda with action prepare before UI inspection."
                            : "Install the Appium xcuitest driver before running smoke tests.")
                )
            ]
        )
    }

    private static func executablePath(candidates: [String]) -> String? {
        candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func installedClaudeInMobilePath() -> String? {
        executablePath(candidates: [
            "/opt/homebrew/bin/claude-in-mobile",
            "/usr/local/bin/claude-in-mobile",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude-in-mobile")
                .path
        ])
    }

    private static func cachedClaudeInMobilePackageAvailable() -> Bool {
        let npxDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: npxDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        for case let fileURL as URL in enumerator
        where fileURL.lastPathComponent == "package.json"
            && fileURL.deletingLastPathComponent().lastPathComponent == "claude-in-mobile" {
            return true
        }
        return false
    }

    private static func runCommand(
        _ executablePath: String,
        _ arguments: [String]
    ) async -> (exitCode: Int32, output: String, error: String) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return (-1, "", "Executable not found: \(executablePath)")
        }
        return await Task.detached {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MobileAutomationDiagnostics-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let outputURL = temporaryDirectory.appendingPathComponent("stdout")
            let errorURL = temporaryDirectory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            do {
                let output = try FileHandle(forWritingTo: outputURL)
                let error = try FileHandle(forWritingTo: errorURL)
                defer {
                    try? output.close()
                    try? error.close()
                }
                process.standardOutput = output
                process.standardError = error
                try process.run()
                process.waitUntilExit()
                try output.synchronize()
                try error.synchronize()
                return (
                    process.terminationStatus,
                    String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self),
                    String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
                )
            } catch {
                return (-1, "", error.localizedDescription)
            }
        }.value
    }
}

private func makeMobileAutomationMCPServer(
    bridge: ClaudeInMobileMCPBridge,
    webDriverAgent: WebDriverAgentController
) async -> MCP.Server {
    let server = Server(
        name: "mobile-automation-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        let healthTool = Tool(
            name: "workharness_health",
            description: "Check Claude in Mobile, Xcode, Simulator, Appium, and WebDriverAgent availability.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        )
        let webDriverAgentTool = Tool(
            name: "workharness_wda",
            description: "Boot the target simulator and build-prepare WebDriverAgent for Claude in Mobile.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("prepare"),
                            .string("status")
                        ])
                    ]),
                    "simulator_id": .object([
                        "type": .string("string")
                    ])
                ]),
                "required": .array([.string("action")])
            ])
        )
        let actionSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action")])
        ])
        let proxiedTools = ["device", "app", "screen", "ui", "input"].map {
            Tool(
                name: $0,
                description: "Proxied Claude in Mobile \($0) meta-tool.",
                inputSchema: actionSchema
            )
        }
        return .init(tools: [healthTool, webDriverAgentTool] + proxiedTools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            if params.name == "workharness_health" {
                let wdaReport = await webDriverAgent.status()
                let report = await bridge.diagnostics(webDriverAgent: wdaReport)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let json = String(decoding: try encoder.encode(report), as: UTF8.self)
                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            }
            if params.name == "workharness_wda" {
                guard let action = params.arguments?["action"]?.stringValue else {
                    throw MobileAutomationError.invalidArgumentsConfiguration
                }
                let report: WebDriverAgentReport
                switch action {
                case "prepare":
                    report = try await webDriverAgent.prepare(
                        requestedSimulatorID: params.arguments?["simulator_id"]?.stringValue
                    )
                case "status":
                    report = await webDriverAgent.status()
                default:
                    throw MobileAutomationError.invalidArgumentsConfiguration
                }
                let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            }
            var upstreamArguments = params.arguments ?? [:]
            let projectRootPath = upstreamArguments.removeValue(forKey: "project_root")?.stringValue
            let artifactName = upstreamArguments.removeValue(forKey: "artifactName")?.stringValue
            let result = try await bridge.callTool(
                name: params.name,
                arguments: upstreamArguments
            )
            return try persistImageArtifacts(
                from: result,
                projectRootPath: projectRootPath,
                artifactName: artifactName
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

private func persistImageArtifacts(
    from result: CallTool.Result,
    projectRootPath: String?,
    artifactName: String?
) throws -> CallTool.Result {
    guard let projectRootPath else {
        return result
    }

    let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw MobileAutomationError.invalidProjectRoot(projectRootPath)
    }

    var content = result.content
    for item in result.content {
        guard case let .image(data, mimeType, _, _) = item else {
            continue
        }
        guard let imageData = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            throw MobileAutomationError.invalidImageData
        }

        let artifactsDirectory = projectRoot
            .appendingPathComponent(".workharness/testing/reports/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactsDirectory,
            withIntermediateDirectories: true
        )
        let requestedName = artifactName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artifactLabel = requestedName.flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Mobile screenshot"
        let fileName = requestedName.flatMap {
            $0.isEmpty ? nil : safeArtifactName($0)
        }
            .map { "\($0)-\(UUID().uuidString.lowercased())" }
            ?? UUID().uuidString
        let artifactURL = artifactsDirectory
            .appendingPathComponent(fileName)
            .appendingPathExtension(fileExtension(for: mimeType))
        try imageData.write(to: artifactURL, options: .atomic)

        let marker = WorkHarnessArtifactMarker(
            workharnessArtifact: .init(
                name: artifactLabel,
                kind: "screenshot",
                path: artifactURL.path,
                mimeType: mimeType
            )
        )
        let markerJSON = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
        content.append(.text(text: markerJSON, annotations: nil, _meta: nil))
    }
    return .init(content: content, isError: result.isError)
}

private func safeArtifactName(_ value: String) -> String? {
    let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
            return Character(String(scalar))
        }
        return "-"
    }
    let normalized = String(scalars)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(80))
}

private func fileExtension(for mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/jpeg":
        "jpg"
    case "image/webp":
        "webp"
    case "image/heic", "image/heif":
        "heic"
    default:
        "png"
    }
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
        let webDriverAgent = WebDriverAgentController()
        let mcpServer = await makeMobileAutomationMCPServer(
            bridge: bridge,
            webDriverAgent: webDriverAgent
        )
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
