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

public struct RemoteProjectCreationRoot: Codable, Sendable, Equatable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    public static func load(from path: String) throws -> [RemoteProjectCreationRoot] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try JSONDecoder().decode(
            [RemoteProjectCreationRoot].self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    }
}

public enum RemoteProjectRegistryError: LocalizedError, Equatable {
    case unavailable, invalidName, invalidParent, alreadyExists, gitInitializationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Project creation is not configured."
        case .invalidName: "Use a project name and a single directory name without slashes."
        case .invalidParent: "Choose an allowed parent directory."
        case .alreadyExists: "That project directory already exists."
        case .gitInitializationFailed: "The project directory was created, but Git initialization failed."
        }
    }
}

public actor RemoteProjectRegistry {
    private var registeredProjects: [RemoteProject]
    private let roots: [RemoteProjectCreationRoot]
    private let projectsFile: String?

    public init(
        projects: [RemoteProject],
        creationRoots: [RemoteProjectCreationRoot] = [],
        projectsFile: String? = nil
    ) {
        self.registeredProjects = projects
        self.roots = creationRoots
        self.projectsFile = projectsFile
    }

    public static func load(projectsPath: String, creationRootsPath: String) throws -> RemoteProjectRegistry {
        try RemoteProjectRegistry(
            projects: RemoteProject.load(from: projectsPath),
            creationRoots: RemoteProjectCreationRoot.load(from: creationRootsPath),
            projectsFile: projectsPath
        )
    }

    public func projects() -> [RemoteProject] { registeredProjects }

    public func creationRoots() -> [RemoteProjectCreationRoot] {
        roots.filter { root in
            var isDirectory: ObjCBool = false
            return root.path.hasPrefix("/") &&
                FileManager.default.fileExists(atPath: canonical(root.path), isDirectory: &isDirectory) &&
                isDirectory.boolValue
        }.map { RemoteProjectCreationRoot(name: $0.name, path: canonical($0.path)) }
    }

    public func resolve(_ path: String) throws -> String {
        try RemoteProject.resolve(path, in: registeredProjects)
    }

    public func create(name rawName: String, directoryName rawDirectoryName: String, parent rawParent: String) throws -> RemoteProject {
        guard let projectsFile else { throw RemoteProjectRegistryError.unavailable }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryName = rawDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !directoryName.isEmpty, directoryName.count <= 100,
              directoryName != ".", directoryName != "..",
              directoryName == URL(fileURLWithPath: directoryName).lastPathComponent,
              !directoryName.contains("/"), !directoryName.contains(":")
        else { throw RemoteProjectRegistryError.invalidName }

        let parent = canonical(rawParent)
        let allowed = creationRoots().contains { canonical($0.path) == parent }
        guard allowed else { throw RemoteProjectRegistryError.invalidParent }
        let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
        let targetURL = parentURL.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL
        guard targetURL.deletingLastPathComponent().path == parent else {
            throw RemoteProjectRegistryError.invalidName
        }
        guard !FileManager.default.fileExists(atPath: targetURL.path),
              !registeredProjects.contains(where: { canonical($0.path) == targetURL.path })
        else { throw RemoteProjectRegistryError.alreadyExists }

        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let project = RemoteProject(name: name, path: targetURL.path)
        let updated = registeredProjects + [project]
        do {
            try initializeGitRepository(at: targetURL)
            var data = try JSONEncoder.remoteProjects.encode(updated)
            data.append(0x0A)
            try data.write(to: URL(fileURLWithPath: projectsFile), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectsFile)
            registeredProjects = updated
            return project
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw error
        }
    }

    private nonisolated func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private nonisolated func initializeGitRepository(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--initial-branch=main", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RemoteProjectRegistryError.gitInitializationFailed
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git", isDirectory: true).path)
        else { throw RemoteProjectRegistryError.gitInitializationFailed }
    }
}

private extension JSONEncoder {
    static var remoteProjects: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
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
    static let codexRotationThresholdBytes: Int64 = 25 * 1_024 * 1_024
    public let claude: ClaudeCLIRunner
    public let codexPath: String
    public let projects: [RemoteProject]
    public let projectRegistry: RemoteProjectRegistry?
    public let conversations: RemoteConversationCatalog?
    public let repository: (any RemoteClaudeJobRepository)?

    public init(claude: ClaudeCLIRunner, codexPath: String, projects: [RemoteProject],
                projectRegistry: RemoteProjectRegistry? = nil,
                conversations: RemoteConversationCatalog? = nil,
                repository: (any RemoteClaudeJobRepository)? = nil) {
        self.claude = claude
        self.codexPath = codexPath
        self.projects = projects
        self.projectRegistry = projectRegistry
        self.conversations = conversations
        self.repository = repository
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
        let directory: String
        if let projectRegistry { directory = try await projectRegistry.resolve(job.workingDirectory) }
        else { directory = try RemoteProject.resolve(job.workingDirectory, in: projects) }
        let prompt = Self.codexPrompt(job: job, directory: directory)
        if let retiredSessionID = job.sessionID,
           let selectedConversation,
           selectedConversation.historyBytes.map({ $0 > Self.codexRotationThresholdBytes }) == true {
            guard let repository else { throw RemoteConversationError.unavailable }
            let summary = try await RemoteCodexQueueRunner(
                codexPath: codexPath,
                repository: repository
            ).run(
                job: job,
                directory: directory,
                prompt: Self.rotationSummaryPrompt(jobID: job.id, directory: directory)
            ).response
            return try await runCodexThread(
                job: job,
                directory: directory,
                prompt: Self.rotatedCodexPrompt(job: job, directory: directory, summary: summary),
                retiredSessionID: retiredSessionID
            )
        }
        if let sessionID = job.sessionID {
            guard let repository else { throw RemoteConversationError.unavailable }
            if job.messageQueuedAt != nil {
                return try await RemoteCodexQueueRunner(codexPath: codexPath, repository: repository)
                    .run(job: job, directory: directory, prompt: prompt)
            }
            do {
                // A closed Codex chat has no desktop owner to consume `codex queue`.
                // Resume it non-interactively so Remote work starts without opening the chat.
                return try await runCodexThread(
                    job: job,
                    directory: directory,
                    prompt: prompt,
                    resumeSessionID: sessionID
                )
            } catch RemoteConversationError.busy {
                // An open desktop chat owns the rollout writer. Queueing is the supported
                // way to hand the task to that owner without competing for the transcript.
                return try await RemoteCodexQueueRunner(codexPath: codexPath, repository: repository)
                    .run(job: job, directory: directory, prompt: prompt)
            }
        }
        return try await runCodexThread(job: job, directory: directory, prompt: prompt)
    }

    private func runCodexThread(
        job: RemoteClaudeJob,
        directory: String,
        prompt: String,
        resumeSessionID: String? = nil,
        retiredSessionID: String? = nil
    ) async throws -> RemoteClaudeJobResult {
        let cancellation = RemoteProcessCancellation()
        let work = Task.detached {
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
                + (resumeSessionID.map { ["resume", $0] } ?? ["--thread-source", "remote"])
                + ["--skip-git-repo-check", "--json", "--output-last-message", outputURL.path,
                   "--", prompt]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let processID = process.processIdentifier
            await cancellation.register(processID: processID)
            defer { Task { @concurrent in await cancellation.unregister(processID: processID) } }
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            }
            try Task.checkCancellation()
            // Drain output to avoid a full pipe blocking the child; retain only a bounded tail.
            var tail = Data()
            var lines = Data()
            var actualSessionID: String?
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                try Task.checkCancellation()
                tail.append(chunk)
                if tail.count > 20_000 { tail = Data(tail.suffix(20_000)) }
                lines.append(chunk)
                while let end = lines.firstIndex(of: 10) {
                    let line = Data(lines[..<end]); lines.removeSubrange(...end)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       event["type"] as? String == "thread.started", let id = event["thread_id"] as? String {
                        guard UUID(uuidString: id) != nil,
                              resumeSessionID == nil || id == resumeSessionID else {
                            throw RemoteConversationError.missing
                        }
                        actualSessionID = id
                        if let retiredSessionID {
                            guard let repository else { throw RemoteConversationError.unavailable }
                            try await repository.markCodexConversationRotated(
                                jobID: job.id,
                                project: directory,
                                retiredSessionID: retiredSessionID,
                                successorSessionID: id,
                                at: Date()
                            )
                        }
                    }
                }
                if lines.count > 1_000_000 { lines.removeAll(keepingCapacity: true) }
            }
            if process.isRunning { process.waitUntilExit() }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                if resumeSessionID != nil, actualSessionID == nil,
                   String(data: tail, encoding: .utf8)?.contains("already has an active writer") == true {
                    throw RemoteConversationError.busy
                }
                throw RemoteClaudeJobError.processFailed("Codex exited with status \(process.terminationStatus). " + (String(data: tail, encoding: .utf8) ?? ""))
            }
            let result = try String(contentsOf: outputURL, encoding: .utf8)
            guard let actualSessionID else { throw RemoteConversationError.unavailable }
            return RemoteClaudeJobResult(response: String(result.prefix(200_000)), sessionID: actualSessionID)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
            Task { @concurrent in await cancellation.cancel() }
        }
    }

    static func rotationSummaryPrompt(jobID: UUID, directory: String) -> String {
        """
        Remote is rotating this Codex chat because its persisted history exceeded 25 MiB.
        Remote task ID: \(jobID.uuidString)
        Do not modify files, run commands, ask questions, or continue the pending user task.
        Produce only a compact, self-contained handoff summary for a new Codex chat in project
        \(directory). Keep the latest and still-relevant information: current goals, architecture,
        decisions, implemented state, uncommitted work, important recent commits, remaining tasks,
        operating constraints, and user preferences. Omit superseded decisions, old diagnostics,
        raw logs, and conversational filler. Resolve conflicts in favor of the newest instruction.
        Return only the handoff summary.
        """
    }

    static func rotatedCodexPrompt(job: RemoteClaudeJob, directory: String, summary: String) -> String {
        let context = String(summary.prefix(50_000))
        return """
        This is a clean continuation of a previous Codex chat. Treat the following handoff as
        context, verify mutable repository state before relying on it, and do not consult the
        retired chat unless the user explicitly asks.

        HANDOFF SUMMARY
        \(context)
        END HANDOFF SUMMARY

        \(codexPrompt(job: RemoteClaudeJob(
            id: job.id,
            prompt: job.prompt,
            workingDirectory: job.workingDirectory,
            status: job.status,
            response: job.response,
            errorMessage: job.errorMessage,
            sessionID: nil,
            messageQueuedAt: job.messageQueuedAt,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            agent: job.agent
        ), directory: directory))
        """
    }

    static func codexPrompt(job: RemoteClaudeJob, directory: String) -> String {
        return """
        Remote web task.
        Remote task ID: \(job.id.uuidString)
        Target: project="\(directory)", chat="\(job.sessionID ?? "new")".
        REMOTE_MESSAGE_CHANNEL=web: do not run the desktop Remote-mode reset.
        Blocking questions: mcp__remote__ask_user (agent="codex", this project, actual chat ID,
        task_id="\(job.id.uuidString)").
        It sends Web Push; never invent replies. Put the result in final for Remote.
        Git: commit only if explicitly asked, then push upstream and verify; no force-push or
        destructive operations without a separate explicit request.

        User request:
        \(job.prompt)
        """
    }
}
