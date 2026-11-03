import Foundation

/// Uses Codex's supported queue command to append to an existing thread without
/// competing with the desktop client's rollout writer. A separate read-only
/// app-server process polls persisted thread history for the matching result.
struct RemoteCodexQueueRunner: Sendable {
    let codexPath: String
    let repository: any RemoteClaudeJobRepository
    var timeout: TimeInterval = 1_800
    var pollInterval: TimeInterval = 3

    func run(job: RemoteClaudeJob, directory: String, prompt: String) async throws -> RemoteClaudeJobResult {
        guard let threadID = job.sessionID, UUID(uuidString: threadID) != nil else {
            throw RemoteConversationError.missing
        }
        return try await Task.detached(priority: .utility) {
            if job.messageQueuedAt == nil {
                try Self.queue(
                    executable: codexPath,
                    threadID: threadID,
                    directory: directory,
                    prompt: prompt
                )
                // Persist only after Codex confirms the durable enqueue. If the server dies
                // before this receipt, the task fails closed instead of replaying changes.
                try await repository.markCodexMessageQueued(id: job.id, at: Date())
            }

            let marker = "Remote task ID: \(job.id.uuidString)"
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let outcome = try CodexThreadHistoryReader.outcome(
                    executable: codexPath,
                    directory: directory,
                    threadID: threadID,
                    marker: marker
                ) {
                    switch outcome {
                    case .completed(let response):
                        return RemoteClaudeJobResult(
                            response: String(response.prefix(200_000)),
                            sessionID: threadID
                        )
                    case .failed(let message):
                        throw RemoteClaudeJobError.processFailed(message)
                    case .running:
                        break
                    }
                }
                try await Task.sleep(for: .seconds(pollInterval))
            }
            throw RemoteClaudeJobError.processFailed(
                "Codex queued the message, but the selected chat did not finish within \(Int(timeout)) seconds."
            )
        }.value
    }

    private static func queue(executable: String, threadID: String, directory: String, prompt: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["REMOTE_MESSAGE_CHANNEL"] = "web"
        process.environment = environment
        process.arguments = [
            "queue", "-C", directory,
            "-c", "mcp_servers.remote.required=true",
            "--thread", threadID,
            "--message", prompt,
            "--resume",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = String(data: data.suffix(20_000), encoding: .utf8) ?? ""
            throw RemoteClaudeJobError.processFailed(
                "Codex queue exited with status \(process.terminationStatus). \(tail)"
            )
        }
    }
}

private enum CodexQueuedTurnOutcome {
    case running
    case completed(String)
    case failed(String)
}

private enum CodexThreadHistoryReader {
    static func outcome(executable: String, directory: String, threadID: String,
                        marker: String) throws -> CodexQueuedTurnOutcome? {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["REMOTE_MESSAGE_CHANNEL"] = "web"
        process.environment = environment
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            timer.cancel()
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "remote",
                    "title": "Remote",
                    "version": "1.0",
                ],
            ],
        ], to: inputPipe.fileHandleForWriting)
        var buffered = Data()
        _ = try response(id: 1, from: outputPipe.fileHandleForReading, buffered: &buffered)
        try send(["method": "initialized", "params": [:]], to: inputPipe.fileHandleForWriting)
        var cursor: String?
        for requestID in 2..<22 {
            var params: [String: Any] = [
                "threadId": threadID,
                "limit": 5,
                "sortDirection": "desc",
                "itemsView": "summary",
            ]
            if let cursor { params["cursor"] = cursor }
            try send([
                "id": requestID,
                "method": "thread/turns/list",
                "params": params,
            ], to: inputPipe.fileHandleForWriting)
            let message = try response(
                id: requestID,
                from: outputPipe.fileHandleForReading,
                buffered: &buffered
            )
            guard message["error"] == nil,
                  let result = message["result"] as? [String: Any],
                  let turns = result["data"] as? [[String: Any]] else {
                throw RemoteConversationError.unavailable
            }
            if let outcome = outcome(in: turns, marker: marker) {
                try inputPipe.fileHandleForWriting.close()
                return outcome
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        try inputPipe.fileHandleForWriting.close()
        return nil
    }

    private static func outcome(in turns: [[String: Any]], marker: String) -> CodexQueuedTurnOutcome? {
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]],
                  items.contains(where: { Self.userMessage($0, contains: marker) }) else { continue }
            let status = turn["status"] as? String ?? ""
            if status == "inProgress" { return .running }
            if status == "failed" || status == "interrupted" {
                let error = (turn["error"] as? [String: Any])?["message"] as? String
                return .failed(error ?? "Codex turn \(status).")
            }
            guard status == "completed" else { return .running }
            let answer = items.reversed().compactMap { item -> String? in
                guard item["type"] as? String == "agentMessage",
                      let text = item["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }.first
            return answer.map(CodexQueuedTurnOutcome.completed) ?? .running
        }
        return nil
    }

    private static func userMessage(_ item: [String: Any], contains marker: String) -> Bool {
        guard item["type"] as? String == "userMessage",
              let content = item["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["text"] as? String)?.contains(marker) == true }
    }

    private static func send(_ message: [String: Any], to input: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private static func response(id: Int, from output: FileHandle,
                                 buffered: inout Data) throws -> [String: Any] {
        while true {
            while let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                let responseID = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue
                if responseID == id { return message }
            }
            guard buffered.count < 5_000_000 else { throw RemoteConversationError.unavailable }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw RemoteConversationError.unavailable }
            buffered.append(chunk)
        }
    }
}
