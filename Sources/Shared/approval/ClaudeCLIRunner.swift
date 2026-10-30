import Foundation

public struct ClaudeCLIRunner: RemoteClaudeJobRunning, Sendable {
    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func run(job: RemoteClaudeJob) async throws -> RemoteClaudeJobResult {
        let executablePath = self.executablePath
        return try await Task.detached {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: job.workingDirectory,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw RemoteClaudeJobError.invalidWorkingDirectory
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.currentDirectoryURL = URL(fileURLWithPath: job.workingDirectory)
            process.arguments = [
                "--print",
                "--output-format", "json",
                "--permission-mode", "bypassPermissions",
                "--dangerously-skip-permissions",
                "--permission-prompts", "none",
                "--no-chrome",
                "--name", "Remote-\(job.id.uuidString)",
                job.prompt,
            ]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let rawOutput = String(data: outputData, encoding: .utf8) ?? ""
            let trimmedOutput = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                let message = trimmedOutput.isEmpty
                    ? "Claude exited with status \(process.terminationStatus)."
                    : String(trimmedOutput.prefix(20_000))
                throw RemoteClaudeJobError.processFailed(message)
            }

            if let data = trimmedOutput.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(ClaudeCLIEnvelope.self, from: data),
               let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines),
               !result.isEmpty {
                return RemoteClaudeJobResult(response: result, sessionID: envelope.sessionID)
            }

            guard !trimmedOutput.isEmpty else {
                throw RemoteClaudeJobError.processFailed("Claude returned an empty response.")
            }
            return RemoteClaudeJobResult(
                response: String(trimmedOutput.prefix(200_000)),
                sessionID: nil
            )
        }.value
    }
}

private struct ClaudeCLIEnvelope: Decodable {
    let result: String?
    let sessionID: String?

    private enum CodingKeys: String, CodingKey {
        case result
        case sessionID = "session_id"
    }
}
