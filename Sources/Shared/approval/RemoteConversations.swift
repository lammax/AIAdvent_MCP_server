import Foundation

public struct RemoteConversation: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let project: String
    public let updatedAt: Double
    public var busy: Bool
    public var open: Bool? = nil
    public var historyBytes: Int64? = nil
}

public struct RemoteProjectChoice: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let sessionID: String?

    public init(name: String, path: String, sessionID: String? = nil) {
        self.name = name
        self.path = path
        self.sessionID = sessionID
    }
}

public enum RemoteConversationError: LocalizedError {
    case unavailable, missing, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось прочитать список чатов. Проверьте CLI и повторите запрос."
        case .missing: "Выбранный чат недоступен в этом проекте. Обновите список или явно выберите новый чат."
        case .busy: "Чат занят другим клиентом. Запрос ждёт освобождения того же чата."
        }
    }
}

public protocol RemoteConversationsReading: Sendable {
    func list(agent: String, projects: [String], knownRemoteIDs: Set<String>) async throws -> [RemoteConversation]
}

public actor RemoteConversationCatalog {
    private let reader: any RemoteConversationsReading
    private let repository: any RemoteClaudeJobRepository
    private let projectRegistry: RemoteProjectRegistry

    public init(reader: any RemoteConversationsReading, repository: any RemoteClaudeJobRepository, projects: [RemoteProject]) {
        self.reader = reader
        self.repository = repository
        self.projectRegistry = RemoteProjectRegistry(projects: projects)
    }

    public init(reader: any RemoteConversationsReading, repository: any RemoteClaudeJobRepository,
                projectRegistry: RemoteProjectRegistry) {
        self.reader = reader
        self.repository = repository
        self.projectRegistry = projectRegistry
    }

    public func list(agent: String, project: String) async throws -> [RemoteConversation] {
        guard ["codex", "claude"].contains(agent) else { throw RemoteConversationError.unavailable }
        let projects = await projectRegistry.projects()
        let canonical = try await projectRegistry.resolve(project)
        let registered = projects.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical }
        let paths = Set(([canonical] + (registered?.chatPaths ?? [])).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        let known = try await repository.conversationSessionIDs(agent: agent, project: canonical)
        let retired = try await repository.retiredConversationSessionIDs(agent: agent, project: canonical)
        let result = try await reader.list(agent: agent, projects: paths.sorted(), knownRemoteIDs: Set(known))
        return result.filter {
            UUID(uuidString: $0.id) != nil && paths.contains($0.project) && !retired.contains($0.id)
        }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    public func validate(agent: String, project: String, id: String) async throws -> RemoteConversation {
        guard let target = try await list(agent: agent, project: project).first(where: { $0.id == id }) else {
            throw RemoteConversationError.missing
        }
        return target
    }

    public func projectChoices(agent: String) async throws -> [RemoteProjectChoice] {
        let projects = await projectRegistry.projects()
        guard agent == "claude" else {
            return projects.map { RemoteProjectChoice(name: $0.name, path: $0.path) }
        }

        var pathOwners: [String: RemoteProject] = [:]
        var lookupPaths = Set<String>()
        var knownIDs = Set<String>()
        for project in projects {
            let canonical = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL.path
            pathOwners[canonical] = pathOwners[canonical] ?? project
            lookupPaths.insert(canonical)
            for alias in project.chatPaths ?? [] where alias.hasPrefix("/") {
                let resolved = URL(fileURLWithPath: alias).resolvingSymlinksInPath().standardizedFileURL.path
                pathOwners[resolved] = pathOwners[resolved] ?? project
                lookupPaths.insert(resolved)
            }
            knownIDs.formUnion(try await repository.conversationSessionIDs(agent: agent, project: canonical))
        }

        let rows = try await reader.list(agent: agent, projects: lookupPaths.sorted(), knownRemoteIDs: knownIDs)
        var representedPaths = Set<String>()
        var choices: [RemoteProjectChoice] = []
        for row in rows.filter({ $0.open == true }).sorted(by: {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }) {
            guard UUID(uuidString: row.id) != nil, let owner = pathOwners[row.project] else { continue }
            let executionPath = URL(fileURLWithPath: owner.path).resolvingSymlinksInPath().standardizedFileURL.path
            representedPaths.insert(executionPath)
            choices.append(RemoteProjectChoice(name: row.title, path: executionPath, sessionID: row.id))
        }

        for project in projects {
            let canonical = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard !representedPaths.contains(canonical) else { continue }
            representedPaths.insert(canonical)
            choices.append(RemoteProjectChoice(name: project.name, path: canonical))
        }
        return choices
    }
}

/// Uses public provider interfaces only. Does not parse provider transcript/database files.
public struct RemoteCLIConversationsReader: RemoteConversationsReading {
    public let codexPath: String
    public let claudePath: String
    public let nodePath: String
    public let claudeSDKPath: String

    public init(codexPath: String, claudePath: String,
                nodePath: String = "/opt/homebrew/bin/node",
                claudeSDKPath: String = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Remote/support/claude-sessions").path) {
        self.codexPath = codexPath; self.claudePath = claudePath
        self.nodePath = nodePath; self.claudeSDKPath = claudeSDKPath
    }

    public func list(agent: String, projects: [String], knownRemoteIDs: Set<String>) async throws -> [RemoteConversation] {
        // Blocking process I/O is isolated from Vapor's event loop and catalog actor.
        try await Task.detached(priority: .utility) {
            if agent == "codex" {
                let data = try Self.codexList(executable: codexPath, projects: projects, knownRemoteIDs: knownRemoteIDs)
                return try Self.decodeCodex(data, knownRemoteIDs: knownRemoteIDs)
            }
            guard agent == "claude", let script = RemoteBundledResource.url(name: "claude-sessions", extension: "mjs") else {
                throw RemoteConversationError.unavailable
            }
            let jsonProjects = String(data: try JSONEncoder().encode(projects), encoding: .utf8)!
            let jsonIDs = String(data: try JSONEncoder().encode(knownRemoteIDs.sorted()), encoding: .utf8)!
            let data = try Self.command(executable: nodePath, arguments: [script.path, claudeSDKPath, jsonProjects, jsonIDs])
            let sessions = try JSONDecoder().decode([RemoteConversation].self, from: data)
            // Claude permits parallel --resume, so fail closed if an owner is still registered,
            // even if that interactive client is currently idle with a cached context.
            let active = try Self.command(executable: claudePath, arguments: ["agents", "--json"])
            guard let activeRows = try JSONSerialization.jsonObject(with: active) as? [[String: Any]] else {
                throw RemoteConversationError.unavailable
            }
            return try Self.mergeClaudeOwners(sessions: sessions, activeRows: activeRows, projects: projects)
        }.value
    }

    public static func mergeClaudeOwners(
        sessions: [RemoteConversation],
        activeRows: [[String: Any]],
        projects: [String]
    ) throws -> [RemoteConversation] {
        let allowed = Set(projects.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        var merged = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for row in activeRows {
            guard let id = row["sessionId"] as? String, UUID(uuidString: id) != nil,
                  let cwd = row["cwd"] as? String else { continue }
            let project = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
            guard allowed.contains(project) else { continue }
            let cursorName = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = merged[id]
            let timestamp = (row["startedAt"] as? NSNumber)?.doubleValue ?? 0
            merged[id] = RemoteConversation(
                id: id,
                title: cursorName.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.title ?? id,
                project: project,
                updatedAt: existing?.updatedAt ?? timestamp / 1_000,
                busy: (row["status"] as? String)?.lowercased() == "busy",
                open: true
            )
        }
        return Array(merged.values)
    }

    public static func decodeCodex(_ data: Data, knownRemoteIDs: Set<String>) throws -> [RemoteConversation] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = payload["data"] as? [[String: Any]] else { throw RemoteConversationError.unavailable }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let cwd = row["cwd"] as? String,
                  let updated = row["updatedAt"] as? Double else { return nil }
            let source = row["source"] as? String ?? ""
            let custom = (row["source"] as? [String: Any])?["custom"] as? String
            guard source != "remote-diagnostic", custom != "remote-diagnostic",
                  row["archived"] as? Bool != true, row["ephemeral"] as? Bool != true,
                  ["cli", "vscode", "appServer"].contains(source) || knownRemoteIDs.contains(id) else { return nil }
            return RemoteConversation(id: id,
                title: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String((row["preview"] as? String ?? id).prefix(100)),
                project: URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path,
                // Codex's app-server `active` status also means merely loaded in a
                // desktop client. The native writer lock is the authoritative busy
                // check when `exec resume` starts.
                updatedAt: updated, busy: false,
                historyBytes: Self.historyBytes(path: row["path"] as? String))
        }
    }

    private static func historyBytes(path: String?) -> Int64? {
        guard let path, path.hasPrefix("/"),
              let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func process(executable: String, arguments: [String]) throws -> (Process, Pipe, Pipe, DispatchSourceTimer) {
        let p = Process(); let input = Pipe(); let output = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        timer.resume()
        return (p, input, output, timer)
    }

    private static func finish(_ p: Process, _ input: Pipe, _ timer: DispatchSourceTimer) {
        try? input.fileHandleForWriting.close()
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); timer.cancel()
    }

    private static func command(executable: String, arguments: [String]) throws -> Data {
        let (p, input, output, timer) = try process(executable: executable, arguments: arguments)
        defer { finish(p, input, timer) }
        try input.fileHandleForWriting.close()
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count < 2_000_000 else { throw RemoteConversationError.unavailable }
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "RemoteConversationReader." + URL(fileURLWithPath: executable).lastPathComponent,
                          code: Int(p.terminationStatus), userInfo: nil)
        }
        return data
    }

    private static func codexList(executable: String, projects: [String], knownRemoteIDs: Set<String>) throws -> Data {
        let (p, input, output, timer) = try process(executable: executable, arguments: ["app-server", "--listen", "stdio://"])
        defer { finish(p, input, timer) }
        func send(_ message: [String: Any]) throws {
            var d = try JSONSerialization.data(withJSONObject: message); d.append(10)
            try input.fileHandleForWriting.write(contentsOf: d)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "remote_sessions", "version": "1.0"]]])
        func requestPage(cursor: String? = nil) throws {
            var params: [String: Any] = ["cwd": projects, "sortKey": "updated_at", "archived": false,
                "limit": 100, "modelProviders": [] as [String], "sourceKinds": [] as [String]]
            if let cursor { params["cursor"] = cursor }
            try send(["id": 2, "method": "thread/list", "params": params])
        }
        var buffer = Data(); var total = 0; var pages = 0
        var rows: [[String: Any]] = []
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            total += chunk.count; guard total < 2_000_000 else { throw RemoteConversationError.unavailable }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = msg["id"] as? Int else { continue }
                guard msg["error"] == nil else { throw RemoteConversationError.unavailable }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try requestPage()
                } else if id == 2, let result = msg["result"] as? [String: Any] {
                    pages += 1
                    rows.append(contentsOf: result["data"] as? [[String: Any]] ?? [])
                    guard let cursor = result["nextCursor"] as? String else {
                        return try JSONSerialization.data(withJSONObject: ["data": rows])
                    }
                    guard pages < 20 else { throw RemoteConversationError.unavailable }
                    try requestPage(cursor: cursor)
                }
            }
        }
        throw RemoteConversationError.unavailable
    }
}

/// Native SwiftPM produces a flat resource bundle; certificate signing can make
/// Foundation treat it as a conventional Contents/Resources bundle instead.
enum RemoteBundledResource {
    static func url(name: String, extension suffix: String) -> URL? {
        if let resource = Bundle.module.url(forResource: name, withExtension: suffix) { return resource }
        let flat = Bundle.module.bundleURL.appendingPathComponent(name + "." + suffix)
        return FileManager.default.fileExists(atPath: flat.path) ? flat : nil
    }
}
