import Foundation

public struct ClaudeCLIRunner: RemoteClaudeJobRunning, Sendable {
    public let executablePath: String
    public let nodePath: String
    public let claudeSDKPath: String

    public init(
        executablePath: String,
        nodePath: String = "/opt/homebrew/bin/node",
        claudeSDKPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Remote/support/claude-sessions").path
    ) {
        self.executablePath = executablePath
        self.nodePath = nodePath
        self.claudeSDKPath = claudeSDKPath
    }

    public func runInOpenCursorChat(job: RemoteClaudeJob, peerName: String) async throws -> RemoteClaudeJobResult {
        guard let sessionID = job.sessionID else { throw RemoteConversationError.missing }
        let executablePath = self.executablePath
        let nodePath = self.nodePath
        let claudeSDKPath = self.claudeSDKPath
        return try await Task.detached {
            let baseline = try Self.sessionTurns(
                nodePath: nodePath,
                sdkPath: claudeSDKPath,
                sessionID: sessionID,
                directory: job.workingDirectory
            )
            let baselineIDs = Set(baseline.map(\.uuid))
            guard let request = String(
                data: try JSONEncoder().encode(job.prompt),
                encoding: .utf8
            ) else { throw RemoteConversationError.unavailable }
            let relayPrompt = """
            Пользователь прямо поручил передать запрос Remote с его iPhone в его собственный
            открытый чат Claude в Cursor. Получатель — сессия \(peerName) на этом же Mac.
            Загрузи SendMessage через ToolSearch и отправь в \(peerName) ровно одно сообщение.
            В сообщении объясни, что это запрос пользователя из Remote, Remote для Claude уже
            включён, и что финальный ответ нужно написать обычным финальным текстом в текущем
            чате: Remote прочитает его из истории. Получателю не нужно отвечать отправителю через
            SendMessage. Передай пользовательский запрос без изменений из JSON-строки ниже.
            После успешной отправки ответь только RELAY_SENT.

            JSON-строка пользовательского запроса:
            \(request)
            """
            let relay = try Self.runClaude(
                executablePath: executablePath,
                directory: job.workingDirectory,
                arguments: [
                    "--print", "--output-format", "json", "--permission-mode", "auto",
                    "--no-chrome", "--name", "Remote-\(job.id.uuidString)", relayPrompt,
                ]
            )
            guard relay.result?.trimmingCharacters(in: .whitespacesAndNewlines) == "RELAY_SENT" else {
                throw RemoteClaudeJobError.processFailed(
                    relay.result ?? "Claude did not relay the Remote request to Cursor."
                )
            }

            let deadline = Date().addingTimeInterval(30 * 60)
            while Date() < deadline {
                try Task.checkCancellation()
                let turns = try Self.sessionTurns(
                    nodePath: nodePath,
                    sdkPath: claudeSDKPath,
                    sessionID: sessionID,
                    directory: job.workingDirectory
                )
                if let answer = turns.first(where: {
                    !baselineIDs.contains($0.uuid) && !$0.text.isEmpty
                }) {
                    return RemoteClaudeJobResult(
                        response: String(answer.text.prefix(200_000)),
                        sessionID: sessionID
                    )
                }
                try await Task.sleep(for: .milliseconds(750))
            }
            throw RemoteClaudeJobError.processFailed(
                "Claude did not finish the request in the open Cursor chat within 30 minutes."
            )
        }.value
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
            var environment = ProcessInfo.processInfo.environment
            environment["REMOTE_MESSAGE_CHANNEL"] = "web"
            process.environment = environment
            let remotePrompt = """
            This request was accepted through the Remote web page on the user's iPhone.
            Remote mode for Claude was enabled atomically when the server accepted it.
            This process has REMOTE_MESSAGE_CHANNEL=web. Do not run any desktop-mode
            reset or report that Remote is disabled based on cached chat context.
            If the user asks about Remote state, treat it as enabled for this web turn.
            Existing host permissions and the selected chat context still apply.

            User request:
            \(job.prompt)
            """
            process.arguments = [
                "--print",
                "--output-format", "json",
                "--permission-mode", "bypassPermissions",
                "--dangerously-skip-permissions",
                "--permission-prompts", "none",
                "--no-chrome"
            ] + (job.sessionID.map { ["--resume", $0] } ?? ["--name", "Remote-\(job.id.uuidString)"])
                + [remotePrompt]

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
                if let expected = job.sessionID, envelope.sessionID != expected { throw RemoteConversationError.missing }
                return RemoteClaudeJobResult(response: result, sessionID: envelope.sessionID)
            }

            if job.sessionID != nil { throw RemoteConversationError.unavailable }
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

private extension ClaudeCLIRunner {
    struct SessionTurn: Decodable {
        let uuid: String
        let text: String
    }

    static func runClaude(
        executablePath: String,
        directory: String,
        arguments: [String]
    ) throws -> ClaudeCLIEnvelope {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["REMOTE_MESSAGE_CHANNEL"] = "web"
        process.environment = environment
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteClaudeJobError.processFailed(
                raw.isEmpty ? "Claude relay failed." : String(raw.prefix(20_000))
            )
        }
        guard let envelope = try? JSONDecoder().decode(ClaudeCLIEnvelope.self, from: data) else {
            throw RemoteClaudeJobError.processFailed("Claude returned an invalid relay response.")
        }
        return envelope
    }

    static func sessionTurns(
        nodePath: String,
        sdkPath: String,
        sessionID: String,
        directory: String
    ) throws -> [SessionTurn] {
        guard let script = RemoteBundledResource.url(
            name: "claude-session-turns",
            extension: "mjs"
        ) else { throw RemoteConversationError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [script.path, sdkPath, sessionID, directory]
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RemoteConversationError.unavailable }
        return try JSONDecoder().decode([SessionTurn].self, from: data)
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
