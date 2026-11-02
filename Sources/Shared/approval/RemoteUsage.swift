import Foundation

public struct RemoteUsageReport: Sendable {
    public let id: UUID
    public let text: String
    public let fetchedAt: Date
    public init(text: String, fetchedAt: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.fetchedAt = fetchedAt
    }
}

public protocol RemoteUsageReading: Sendable {
    func read(agent: String) async throws -> RemoteUsageReport
}

public enum RemoteUsageError: LocalizedError {
    case unavailable
    public var errorDescription: String? {
        "Не удалось получить лимиты. Проверьте вход в CLI выбранного агента на Mac и повторите запрос."
    }
}

/// Coalesce clicks and retain the provider timestamp when returning a cached snapshot.
public actor RemoteUsageService {
    private let reader: any RemoteUsageReading
    private var cached: [String: RemoteUsageReport] = [:]
    private var pending: [String: Task<RemoteUsageReport, Error>] = [:]

    public init(reader: any RemoteUsageReading) { self.reader = reader }

    public func report(agent: String) async throws -> RemoteUsageReport {
        guard agent == "codex" || agent == "claude" else { throw RemoteUsageError.unavailable }
        if let report = cached[agent], Date().timeIntervalSince(report.fetchedAt) < 30 { return report }
        if let task = pending[agent] { return try await task.value }
        let reader = reader
        let task = Task { try await reader.read(agent: agent) }
        pending[agent] = task
        defer { pending[agent] = nil }
        let report = try await task.value
        cached[agent] = report
        return report
    }
}

public struct RemoteCLIUsageReader: RemoteUsageReading {
    public let codexPath: String
    public let claudePath: String
    public init(codexPath: String, claudePath: String) {
        self.codexPath = codexPath
        self.claudePath = claudePath
    }

    public func read(agent: String) async throws -> RemoteUsageReport {
        // Foundation's synchronous pipe reads must not block Vapor's event loop or the service actor.
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: agent == "codex" ? codexPath : claudePath)
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            process.arguments = agent == "codex" ? ["app-server", "--listen", "stdio://"] : [
                "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                "--tools", "", "--no-session-persistence", "--max-turns", "1", "-p", "/usage"
            ]
            try process.run()
            // The reader owns this short-lived process. Kill it at the deadline so reads cannot hang.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 25)
            timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            timer.resume()
            defer {
                try? stdin.fileHandleForWriting.close()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                timer.cancel()
            }
            func send(_ message: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(10)
                try stdin.fileHandleForWriting.write(contentsOf: data)
            }
            if agent == "codex" {
                try send(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "remote_usage", "version": "1.0"]
                ]])
            } else {
                try stdin.fileHandleForWriting.close()
            }
            var buffer = Data()
            var total = 0
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                total += chunk.count
                guard total <= 1_000_000 else { throw RemoteUsageError.unavailable }
                buffer.append(chunk)
                if agent == "codex" {
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let id = message["id"] as? Int else { continue }
                        guard message["error"] == nil else { throw RemoteUsageError.unavailable }
                        if id == 1 {
                            try send(["method": "initialized", "params": [:]])
                            try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                        } else if id == 2, let result = message["result"] {
                            let data = try JSONSerialization.data(withJSONObject: result)
                            return RemoteUsageReport(text: try Self.codexText(data))
                        }
                    }
                }
            }
            process.waitUntilExit()
            guard agent == "claude", process.terminationStatus == 0,
                  let text = String(data: buffer, encoding: .utf8) else { throw RemoteUsageError.unavailable }
            return RemoteUsageReport(text: try Self.claudeText(text))
        }.value
    }

    public static func claudeText(_ output: String) throws -> String {
        // Only usage windows: omit the CLI's unrelated local session/skill analytics.
        let regex = try NSRegularExpression(pattern: #"^(Current [^:]+): ([0-9]+(?:\.[0-9]+)?)% used(?: · resets (.+))?$"#)
        let lines = output.components(separatedBy: .newlines).compactMap { line -> String? in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let valueRange = Range(match.range(at: 2), in: line),
                  let used = Double(line[valueRange]), used.isFinite else { return nil }
            let rawLabel = String(line.prefix { $0 != ":" })
            let label = rawLabel == "Current session" ? "5 часов" : rawLabel
                .replacingOccurrences(of: "Current week", with: "7 дней")
                .replacingOccurrences(of: "all models", with: "все модели")
            var result = "\(label): использовано \(used.formatted())%, осталось \(max(0, min(100, 100 - used)).formatted())%."
            if let reset = Range(match.range(at: 3), in: line) { result += " Сброс: \(line[reset])." }
            return result
        }
        guard !lines.isEmpty else { throw RemoteUsageError.unavailable }
        return "Claude — лимиты аккаунта\n" + lines.joined(separator: "\n")
    }

    public static func codexText(_ data: Data) throws -> String {
        struct Window: Decodable { let usedPercent: Double?; let windowDurationMins: Int?; let resetsAt: Double? }
        struct Bucket: Decodable { let primary: Window?; let secondary: Window? }
        struct Payload: Decodable { let rateLimits: Bucket?; let rateLimitsByLimitId: [String: Bucket]? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let buckets = payload.rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? payload.rateLimits.map { ["codex": $0] } ?? [:]
        var lines = [String]()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
        formatter.dateFormat = "dd.MM HH:mm 'МСК'"
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            for window in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
                guard let used = window.usedPercent, used.isFinite, used >= 0 else { continue }
                let label = window.windowDurationMins.map { $0 == 10080 ? "7 дней" : $0 % 60 == 0 ? "\($0 / 60) часов" : "\($0) мин" } ?? "Лимит"
                var line = "\(key): \(label) — использовано \(used.formatted())%, осталось \(max(0, min(100, 100 - used)).formatted())%."
                if let reset = window.resetsAt, reset.isFinite { line += " Сброс: \(formatter.string(from: Date(timeIntervalSince1970: reset)))." }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { throw RemoteUsageError.unavailable }
        return "Codex — лимиты аккаунта\n" + lines.joined(separator: "\n")
    }
}
