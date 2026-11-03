import Foundation

/// Only explicitly registered directories can be execution roots.
public struct RemoteProject: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let chatPaths: [String]?
    public init(name: String, path: String, chatPaths: [String]? = nil) {
        self.name = name
        self.path = path
        self.chatPaths = chatPaths
    }

    public static func load(from path: String) throws -> [RemoteProject] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try JSONDecoder().decode([RemoteProject].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func resolve(_ path: String, in projects: [RemoteProject]) throws -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"),
              projects.contains(where: {
                  URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical
              }),
              FileManager.default.fileExists(atPath: canonical)
        else { throw RemoteClaudeJobError.invalidWorkingDirectory }
        return canonical
    }
}

/// A per-run profile: git metadata is writable, while other workspace safeguards remain.
public enum RemoteCodexPermissions {
    public static func httpsGitHost(_ remote: String) -> String? {
        guard let url = URLComponents(string: remote.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              host.contains("."), host.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
              }) else { return nil }
        return host
    }

    public static func overrides(gitHosts: Set<String>) -> [String] {
        // Use an inline TOML table: CLI dotted overrides cannot safely address a '.git' key.
        let hosts = gitHosts.sorted().filter { httpsGitHost("https://" + $0) == $0 }
        let domains = hosts.map { "\"\($0)\"=\"allow\"" }.joined(separator: ",")
        return [
            "default_permissions=\"remote-project\"",
            "features.network_proxy=true",
            "permissions.remote-project={extends=\":workspace\",filesystem={\":workspace_roots\"={\".\"=\"write\",\".git\"=\"write\",\".codex\"=\"read\",\".agents\"=\"read\",\".aws\"=\"read\"}},network={enabled=\(!hosts.isEmpty),domains={\(domains)}}}"
        ]
    }
}

public struct RemoteAgentRunner: RemoteClaudeJobRunning, Sendable {
    public let claude: ClaudeCLIRunner
    public let codexPath: String
    public let projects: [RemoteProject]
    public let conversations: RemoteConversationCatalog?

    public init(claude: ClaudeCLIRunner, codexPath: String, projects: [RemoteProject], conversations: RemoteConversationCatalog? = nil) {
        self.claude = claude
        self.codexPath = codexPath
        self.projects = projects
        self.conversations = conversations
    }

    public func run(job: RemoteClaudeJob) async throws -> RemoteClaudeJobResult {
        var selectedConversation: RemoteConversation?
        if let id = job.sessionID {
            guard let conversations else { throw RemoteConversationError.unavailable }
            let target = try await conversations.validate(agent: job.agent, project: job.workingDirectory, id: id)
            if target.busy { throw RemoteConversationError.busy }
            selectedConversation = target
        }
        if job.agent == "claude" {
            if let selectedConversation, selectedConversation.open == true {
                return try await claude.runInOpenCursorChat(
                    job: job,
                    peerName: selectedConversation.title
                )
            }
            return try await claude.run(job: job)
        }
        guard job.agent == "codex" else { throw RemoteClaudeJobError.processFailed("Unknown agent.") }
        let directory = try RemoteProject.resolve(job.workingDirectory, in: projects)
        return try await Task.detached {
            let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-codex-\(UUID())")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let outputURL = outputDirectory.appendingPathComponent("result.txt")
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment
            environment["REMOTE_MESSAGE_CHANNEL"] = "web"
            process.environment = environment
            var gitHosts = Set<String>()
            for flags in [["--all"], ["--push", "--all"]] {
                let git = Process()
                git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                git.arguments = ["-C", directory, "remote", "get-url"] + flags + ["origin"]
                let output = Pipe()
                git.standardOutput = output
                git.standardError = FileHandle.nullDevice
                try git.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                git.waitUntilExit()
                if git.terminationStatus == 0 {
                    for remote in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                        if let host = RemoteCodexPermissions.httpsGitHost(String(remote)) { gitHosts.insert(host) }
                    }
                }
            }
            process.arguments = ["exec", "-C", directory]
                + RemoteCodexPermissions.overrides(gitHosts: gitHosts).flatMap { ["-c", $0] }
                + [
                "-c", "approval_policy=\"never\"",
                "-c", "mcp_servers.remote.required=true"
                ]
                + (job.sessionID.map { ["resume", $0] } ?? ["--thread-source", "remote"])
                + [
                "--skip-git-repo-check", "--json", "--output-last-message", outputURL.path,
                "--", """
                This task was submitted through Remote on the user's iPhone.
                For blocking task questions use mcp__remote__ask_user with agent "codex",
                project "\(directory)", and the actual current chat ID when available.
                The selected existing chat ID is "\(job.sessionID ?? "new chat")".
                Each such call automatically queues Web Push. Never fabricate a human answer.
                Return your final report as the final response; Remote displays it on the task page.
                Host sandbox and approval restrictions still apply.
                This process has REMOTE_MESSAGE_CHANNEL=web. Never apply the desktop-message
                mode reset here. Mode was set when the web request was accepted; do not reset
                it when this queued task starts or resumes after a desktop message.
                A Remote-only permission profile allows project edits and git commits.
                Command network access is restricted to this project's HTTPS origin hosts.
                Commit only when requested; after a requested commit, push normally to the
                configured upstream and verify synchronization. Never force-push or perform
                destructive git operations without a separate explicit user instruction.

                User request:
                \(job.prompt)
                """
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            }
            // Drain output to avoid a full pipe blocking the child; retain only a bounded tail.
            var tail = Data()
            var lines = Data()
            var actualSessionID: String?
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
                if tail.count > 20_000 { tail = Data(tail.suffix(20_000)) }
                lines.append(chunk)
                while let end = lines.firstIndex(of: 10) {
                    let line = Data(lines[..<end]); lines.removeSubrange(...end)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       event["type"] as? String == "thread.started", let id = event["thread_id"] as? String {
                        guard UUID(uuidString: id) != nil,
                              job.sessionID == nil || UUID(uuidString: id) == job.sessionID.flatMap(UUID.init(uuidString:)) else {
                            throw RemoteConversationError.missing
                        }
                        actualSessionID = id
                    }
                }
                if lines.count > 1_000_000 { lines.removeAll(keepingCapacity: true) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if job.sessionID != nil, actualSessionID == nil,
                   String(data: tail, encoding: .utf8)?.contains("already has an active writer") == true {
                    throw RemoteConversationError.busy
                }
                throw RemoteClaudeJobError.processFailed("Codex exited with status \(process.terminationStatus). " + (String(data: tail, encoding: .utf8) ?? ""))
            }
            let result = try String(contentsOf: outputURL, encoding: .utf8)
            guard let actualSessionID else { throw RemoteConversationError.unavailable }
            return RemoteClaudeJobResult(response: String(result.prefix(200_000)), sessionID: actualSessionID)
        }.value
    }
}
