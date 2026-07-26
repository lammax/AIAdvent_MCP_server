import Foundation

enum WebDriverAgentError: LocalizedError {
    case noBootedSimulator
    case notInstalled(String)
    case preparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBootedSimulator:
            "No iOS Simulator is available for WebDriverAgent."
        case .notInstalled(let path):
            "WebDriverAgent was not found at \(path). Install the Appium xcuitest driver."
        case .preparationFailed(let details):
            "WebDriverAgent preparation failed. \(details)"
        }
    }
}

struct WebDriverAgentReport: Codable {
    let isPrepared: Bool
    let isRunning: Bool
    let managedByServer: Bool
    let simulatorID: String?
    let endpoint: String
    let message: String
    let logPath: String?
}

actor WebDriverAgentController {
    private struct SimulatorList: Decodable {
        struct Device: Decodable {
            let state: String
            let udid: String
            let isAvailable: Bool
        }

        let devices: [String: [Device]]
    }

    private static let endpoint = URL(string: "http://127.0.0.1:8100/status")!

    private var preparedSimulatorID: String?
    private var logURL: URL?

    func status() async -> WebDriverAgentReport {
        let running = await Self.isServerReady()
        return WebDriverAgentReport(
            isPrepared: preparedSimulatorID != nil,
            isRunning: running,
            managedByServer: false,
            simulatorID: preparedSimulatorID,
            endpoint: Self.endpoint.absoluteString,
            message: running
                ? "WebDriverAgent is running under Claude in Mobile."
                : (preparedSimulatorID == nil
                    ? "WebDriverAgent is installed but not prepared."
                    : "WebDriverAgent is prepared; Claude in Mobile will start it on first UI action."),
            logPath: logURL?.path
        )
    }

    func prepare(requestedSimulatorID: String?) async throws -> WebDriverAgentReport {
        let simulatorID: String
        if let requestedSimulatorID {
            simulatorID = requestedSimulatorID
        } else {
            simulatorID = try await Self.availableSimulatorID()
        }
        let directory = Self.webDriverAgentDirectory()
        let project = directory.appendingPathComponent("WebDriverAgent.xcodeproj")
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw WebDriverAgentError.notInstalled(directory.path)
        }

        try await Self.bootSimulator(simulatorID)

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workharness-wda-prepare-\(UUID().uuidString.lowercased()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "build-for-testing",
            "-project", project.lastPathComponent,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "platform=iOS Simulator,id=\(simulatorID)"
        ]
        process.currentDirectoryURL = directory
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        await Task.detached {
            process.waitUntilExit()
        }.value
        try? logHandle.synchronize()

        guard process.terminationStatus == 0 else {
            throw WebDriverAgentError.preparationFailed(Self.logTail(at: logURL))
        }

        preparedSimulatorID = simulatorID
        self.logURL = logURL
        return await status()
    }

    private static func availableSimulatorID() async throws -> String {
        let result = await runCommand(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "available", "--json"]
        )
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimulatorList.self, from: data),
              let simulator = list.devices.values
                .flatMap({ $0 })
                .first(where: { $0.isAvailable }) else {
            throw WebDriverAgentError.noBootedSimulator
        }
        return simulator.udid
    }

    private static func bootSimulator(_ simulatorID: String) async throws {
        let boot = await runCommand(
            "/usr/bin/xcrun",
            ["simctl", "boot", simulatorID]
        )
        guard boot.exitCode == 0 || boot.output.contains("current state: Booted") else {
            throw WebDriverAgentError.preparationFailed(boot.output)
        }
        let bootStatus = await runCommand(
            "/usr/bin/xcrun",
            ["simctl", "bootstatus", simulatorID, "-b"]
        )
        guard bootStatus.exitCode == 0 else {
            throw WebDriverAgentError.preparationFailed(bootStatus.output)
        }
    }

    private static func isServerReady() async -> Bool {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    private static func webDriverAgentDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent",
                isDirectory: true
            )
    }

    private static func logTail(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "No WebDriverAgent build output was captured."
        }
        return String(decoding: data.suffix(8_192), as: UTF8.self)
    }

    private static func runCommand(
        _ executablePath: String,
        _ arguments: [String]
    ) async -> (exitCode: Int32, output: String) {
        await Task.detached {
            let outputPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }
}
