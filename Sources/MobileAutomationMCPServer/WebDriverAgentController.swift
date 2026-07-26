import Foundation

enum WebDriverAgentError: LocalizedError {
    case noBootedSimulator
    case notInstalled(String)
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBootedSimulator:
            "No booted iOS Simulator is available for WebDriverAgent."
        case .notInstalled(let path):
            "WebDriverAgent was not found at \(path). Install the Appium xcuitest driver."
        case .startupFailed(let details):
            "WebDriverAgent failed to start. \(details)"
        }
    }
}

struct WebDriverAgentReport: Codable {
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
    private static let startupTimeout = Duration.seconds(180)

    private var process: Process?
    private var logHandle: FileHandle?
    private var logURL: URL?
    private var simulatorID: String?

    deinit {
        if process?.isRunning == true {
            process?.interrupt()
        }
        try? logHandle?.close()
    }

    func status() async -> WebDriverAgentReport {
        let running = await Self.isServerReady()
        return WebDriverAgentReport(
            isRunning: running,
            managedByServer: running && process?.isRunning == true,
            simulatorID: simulatorID,
            endpoint: Self.endpoint.absoluteString,
            message: running
                ? "WebDriverAgent is accepting requests."
                : "WebDriverAgent is not accepting requests.",
            logPath: logURL?.path
        )
    }

    func ensureRunning(requestedSimulatorID: String?) async throws -> WebDriverAgentReport {
        if await Self.isServerReady() {
            return await status()
        }

        if process?.isRunning == true {
            return try await waitUntilReady()
        }
        cleanupManagedProcess()

        let simulatorID: String
        if let requestedSimulatorID {
            simulatorID = requestedSimulatorID
        } else {
            simulatorID = try await Self.bootedSimulatorID()
        }
        let directory = Self.webDriverAgentDirectory()
        let project = directory.appendingPathComponent("WebDriverAgent.xcodeproj")
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw WebDriverAgentError.notInstalled(directory.path)
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workharness-wda-\(UUID().uuidString.lowercased()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "test",
            "-project", project.lastPathComponent,
            "-scheme", "WebDriverAgentRunner",
            "-destination", "platform=iOS Simulator,id=\(simulatorID)"
        ]
        process.currentDirectoryURL = directory
        process.standardOutput = logHandle
        process.standardError = logHandle

        self.process = process
        self.logHandle = logHandle
        self.logURL = logURL
        self.simulatorID = simulatorID

        do {
            try process.run()
            return try await waitUntilReady()
        } catch {
            let details = logTail()
            cleanupManagedProcess()
            if let webDriverAgentError = error as? WebDriverAgentError {
                throw webDriverAgentError
            }
            throw WebDriverAgentError.startupFailed(
                [error.localizedDescription, details].filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
    }

    func stop() async -> WebDriverAgentReport {
        if process?.isRunning == true, let simulatorID {
            _ = await Self.runCommand(
                "/usr/bin/xcrun",
                [
                    "simctl", "terminate", simulatorID,
                    "com.facebook.WebDriverAgentRunner.xctrunner"
                ]
            )
            process?.interrupt()
            for _ in 0..<10 where process?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process?.isRunning == true {
                process?.terminate()
            }
        }
        cleanupManagedProcess()
        return await status()
    }

    private func waitUntilReady() async throws -> WebDriverAgentReport {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.startupTimeout)
        while clock.now < deadline {
            if await Self.isServerReady() {
                return await status()
            }
            if process?.isRunning != true {
                throw WebDriverAgentError.startupFailed(logTail())
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw WebDriverAgentError.startupFailed(
            "Startup timed out after 180 seconds.\n\(logTail())"
        )
    }

    private func cleanupManagedProcess() {
        try? logHandle?.close()
        logHandle = nil
        process = nil
        simulatorID = nil
    }

    private func logTail() -> String {
        guard let logURL,
              let data = try? Data(contentsOf: logURL),
              !data.isEmpty else {
            return "No WebDriverAgent log output was captured."
        }
        return String(decoding: data.suffix(8_192), as: UTF8.self)
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

    private static func bootedSimulatorID() async throws -> String {
        let result = await runCommand(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "booted", "--json"]
        )
        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimulatorList.self, from: data),
              let simulator = list.devices.values
                .flatMap({ $0 })
                .first(where: { $0.state == "Booted" && $0.isAvailable }) else {
            throw WebDriverAgentError.noBootedSimulator
        }
        return simulator.udid
    }

    private static func webDriverAgentDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent",
                isDirectory: true
            )
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
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            } catch {
                return (-1, "")
            }
        }.value
    }
}
