import Foundation

/// Read-only fallback context export for when the CLI's rate limit is fully exhausted:
/// dumps a thread's already-persisted turns via Codex's app-server `thread/turns/list`
/// instead of asking the agent to *generate* a new handoff summary — generation is
/// exactly what a zero-remaining-limit CLI refuses to do. Reading already-stored history
/// is not a new completion and is not subject to the same rate limit.
///
/// New, EnergyBot-only code: Codex's existing rotation handoff
/// (`RemoteCodex.rotationSummaryPrompt`) stays untouched and remains the primary path —
/// this is only the fallback used when that path's own CLI call gets refused.
public enum CodexRawHistoryExporter {
    public static func export(executable: String, directory: String, threadID: String) throws -> String {
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
        timer.schedule(deadline: .now() + 30)
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
            "params": ["clientInfo": ["name": "remote", "title": "Remote", "version": "1.0"]],
        ], to: inputPipe.fileHandleForWriting)
        var buffered = Data()
        _ = try response(id: 1, from: outputPipe.fileHandleForReading, buffered: &buffered)
        try send(["method": "initialized", "params": [:]], to: inputPipe.fileHandleForWriting)

        var pages: [[[String: Any]]] = []
        var cursor: String?
        for requestID in 2..<202 {
            var params: [String: Any] = [
                "threadId": threadID, "limit": 50, "sortDirection": "desc", "itemsView": "full",
            ]
            if let cursor { params["cursor"] = cursor }
            try send(["id": requestID, "method": "thread/turns/list", "params": params], to: inputPipe.fileHandleForWriting)
            let message = try response(id: requestID, from: outputPipe.fileHandleForReading, buffered: &buffered)
            guard message["error"] == nil,
                  let result = message["result"] as? [String: Any],
                  let turns = result["data"] as? [[String: Any]] else {
                throw RemoteConversationError.unavailable
            }
            pages.append(turns)
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        try inputPipe.fileHandleForWriting.close()

        // Pages and the turns within each page arrive newest-first; reverse both levels
        // to render the transcript in chronological order.
        let chronological = pages.reversed().flatMap { $0.reversed() }
        var lines: [String] = []
        for turn in chronological {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                switch item["type"] as? String {
                case "userMessage":
                    let text = (item["content"] as? [[String: Any]])?
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n") ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("User: \(text)")
                    }
                case "agentMessage":
                    if let text = item["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("Assistant: \(text)")
                    }
                default:
                    continue
                }
            }
        }
        guard !lines.isEmpty else { throw RemoteConversationError.unavailable }
        return String(lines.joined(separator: "\n\n").suffix(200_000))
    }

    private static func send(_ message: [String: Any], to input: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private static func response(id: Int, from output: FileHandle, buffered: inout Data) throws -> [String: Any] {
        while true {
            while let newline = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let responseID = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue
                if responseID == id { return message }
            }
            guard buffered.count < 10_000_000 else { throw RemoteConversationError.unavailable }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw RemoteConversationError.unavailable }
            buffered.append(chunk)
        }
    }
}
