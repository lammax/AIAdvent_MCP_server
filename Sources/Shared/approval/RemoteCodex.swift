import Foundation

/// Only explicitly registered directories can be execution roots.
public struct RemoteProject: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public init(name: String, path: String) {
        self.name = name
        self.path = path
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

    public init(claude: ClaudeCLIRunner, codexPath: String, projects: [RemoteProject]) {
        self.claude = claude
        self.codexPath = codexPath
        self.projects = projects
    }

    public func run(job: RemoteClaudeJob) async throws -> RemoteClaudeJobResult {
        if job.agent == "claude" { return try await claude.run(job: job) }
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
            process.arguments = ["exec", "--skip-git-repo-check"]
                + RemoteCodexPermissions.overrides(gitHosts: gitHosts).flatMap { ["-c", $0] }
                + [
                "-c", "approval_policy=\"never\"",
                "-c", "mcp_servers.remote.required=true",
                "-C", directory, "--output-last-message", outputURL.path,
                "--", """
                This task was submitted through Remote on the user's iPhone.
                For blocking task questions use mcp__remote__ask_user with agent "codex",
                project "\(directory)", and chat "\(job.id.uuidString)".
                Each such call automatically queues Web Push. Never fabricate a human answer.
                Return your final report as the final response; Remote displays it on the task page.
                Host sandbox and approval restrictions still apply.
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
            // Drain output to avoid a full pipe blocking the child; retain only a bounded tail.
            var tail = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
                if tail.count > 20_000 { tail = Data(tail.suffix(20_000)) }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RemoteClaudeJobError.processFailed("Codex exited with status \(process.terminationStatus). " + (String(data: tail, encoding: .utf8) ?? ""))
            }
            let result = try String(contentsOf: outputURL, encoding: .utf8)
            return RemoteClaudeJobResult(response: String(result.prefix(200_000)), sessionID: nil)
        }.value
    }
}
