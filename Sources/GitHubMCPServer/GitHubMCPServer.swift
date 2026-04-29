//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

// MARK: - MCP server factory

func makeGitHubMCPServer(
    github: GitHubAPI,
    jobRepository: JobRepositoryProtocol,
    projectRoot: URL?
) async -> MCP.Server {
    let server = Server(
        name: "github-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "github_get_repo",
                    description: "Get summary information about a GitHub repository.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "owner": .object([
                                "type": .string("string"),
                                "description": .string("GitHub owner (e.g. apple)")
                            ]),
                            "repo": .object([
                                "type": .string("string"),
                                "description": .string("Repository name (e.g. swift)")
                            ])
                        ]),
                        "required": .array([
                            .string("owner"),
                            .string("repo")
                        ])
                    ])
                ),

                Tool(
                    name: "schedule_summary",
                    description: "Schedule periodic GitHub repository summary collection.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "owner": .object([
                                "type": .string("string")
                            ]),
                            "repo": .object([
                                "type": .string("string")
                            ]),
                            "interval_seconds": .object([
                                "type": .double(.zero)
                            ])
                        ]),
                        "required": .array([
                            .string("owner"),
                            .string("repo"),
                            .double(.zero)
                        ])
                    ])
                ),

                Tool(
                    name: "get_summary",
                    description: "Get latest summary result for a job.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "job_id": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("job_id")
                        ])
                    ])
                ),

                Tool(
                    name: "cancel_job",
                    description: "Cancel a scheduled job.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "job_id": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("job_id")
                        ])
                    ])
                ),

                Tool(
                    name: "git_current_branch",
                    description: "Get the current local git branch for the configured project repository.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),

                Tool(
                    name: "git_changed_files",
                    description: "Get changed files for the configured local project repository.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ),

                Tool(
                    name: "git_diff",
                    description: "Get staged and unstaged diff for the configured local project repository.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {

        case "github_get_repo":
            guard
                let owner = params.arguments?["owner"]?.stringValue,
                let repo = params.arguments?["repo"]?.stringValue,
                !owner.isEmpty,
                !repo.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing parameters: owner, repo", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let repoData = try await github.fetchRepo(owner: owner, repo: repo)
                let data = try JSONEncoder().encode(repoData)
                let json = String(data: data, encoding: .utf8) ?? "{}"

                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "schedule_summary":
            let owner = params.arguments?["owner"]?.stringValue
            let repo = params.arguments?["repo"]?.stringValue
            let interval: Double? = parseIntervalSeconds(from: params.arguments?["interval_seconds"])

            guard
                let owner, !owner.isEmpty,
                let repo, !repo.isEmpty,
                let interval
            else {
                return .init(
                    content: [.text(text: "Missing parameters", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let payloadData = try JSONSerialization.data(withJSONObject: [
                    "owner": owner,
                    "repo": repo
                ])

                let payload = String(data: payloadData, encoding: .utf8) ?? "{}"

                let job = Job(
                    id: UUID().uuidString,
                    type: "github_summary",
                    payload: payload,
                    interval: interval,
                    nextRunAt: Date().addingTimeInterval(interval),
                    isActive: true
                )

                try await jobRepository.save(job)

                return .init(
                    content: [.text(text: "Scheduled job \(job.id)", annotations: nil, _meta: nil)],
                    isError: false
                )

            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "get_summary":
            guard
                let jobId = params.arguments?["job_id"]?.stringValue,
                !jobId.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing job_id", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let result = try await jobRepository.latestResult(jobId: jobId)

                return .init(
                    content: [.text(text: result ?? "No data yet", annotations: nil, _meta: nil)],
                    isError: false
                )

            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "cancel_job":
            guard
                let jobId = params.arguments?["job_id"]?.stringValue,
                !jobId.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing job_id", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                try await jobRepository.deactivate(jobId: jobId)

                return .init(
                    content: [.text(text: "Cancelled \(jobId)", annotations: nil, _meta: nil)],
                    isError: false
                )

            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "git_current_branch":
            guard let projectRoot else {
                return .init(
                    content: [.text(text: "Project root is not configured. Set PROJECT_ROOT or pass --project-root.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let branch = try currentGitBranch(projectRoot: projectRoot)
                let payload = GitCurrentBranchResult(
                    branch: branch,
                    repository: projectRoot.lastPathComponent
                )
                let data = try JSONEncoder().encode(payload)
                let json = String(data: data, encoding: .utf8) ?? "{}"

                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "git_changed_files":
            guard let projectRoot else {
                return .init(
                    content: [.text(text: "Project root is not configured. Set PROJECT_ROOT or pass --project-root.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let branch = try currentGitBranch(projectRoot: projectRoot)
                let files = try changedGitFiles(projectRoot: projectRoot)
                let payload = GitChangedFilesResult(
                    branch: branch,
                    repository: projectRoot.lastPathComponent,
                    files: files
                )
                let data = try JSONEncoder().encode(payload)
                let json = String(data: data, encoding: .utf8) ?? "{}"

                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "git_diff":
            guard let projectRoot else {
                return .init(
                    content: [.text(text: "Project root is not configured. Set PROJECT_ROOT or pass --project-root.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let branch = try currentGitBranch(projectRoot: projectRoot)
                let payload = GitDiffResult(
                    branch: branch,
                    repository: projectRoot.lastPathComponent,
                    diff: try currentGitDiff(projectRoot: projectRoot)
                )
                let data = try JSONEncoder().encode(payload)
                let json = String(data: data, encoding: .utf8) ?? "{}"

                return .init(
                    content: [.text(text: json, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        default:
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

private func parseIntervalSeconds(from value: Value?) -> Double? {
    guard let value else { return nil }

    if let double = value.doubleValue {
        return double
    }

    if let int = value.intValue {
        return Double(int)
    }

    if let string = value.stringValue {
        return Double(string)
    }

    return nil
}

private struct GitCurrentBranchResult: Encodable {
    let branch: String
    let repository: String
}

private struct GitChangedFilesResult: Encodable {
    let branch: String
    let repository: String
    let files: [GitChangedFile]
}

private struct GitChangedFile: Encodable {
    let path: String
    let status: String
}

private struct GitDiffResult: Encodable {
    let branch: String
    let repository: String
    let diff: String
}

private func currentGitBranch(projectRoot: URL) throws -> String {
    let branch = try runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], projectRoot: projectRoot)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else {
        throw NSError(
            domain: "GitHubMCPServer.Git",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to read current git branch."]
        )
    }

    return branch
}

private func changedGitFiles(projectRoot: URL) throws -> [GitChangedFile] {
    let output = try runGitCommand(["status", "--porcelain=v1"], projectRoot: projectRoot)
    return output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { line -> GitChangedFile? in
            guard line.count >= 4 else { return nil }

            let rawStatus = String(line.prefix(2))
            let rawPath = String(line.dropFirst(3))
            let path = rawPath.components(separatedBy: " -> ").last ?? rawPath

            return GitChangedFile(
                path: path,
                status: gitStatusDescription(rawStatus)
            )
        }
}

private func currentGitDiff(projectRoot: URL) throws -> String {
    let staged = try runGitCommand(["diff", "--cached", "--no-ext-diff", "--"], projectRoot: projectRoot)
    let unstaged = try runGitCommand(["diff", "--no-ext-diff", "--"], projectRoot: projectRoot)
    var sections: [String] = []

    if !staged.isEmpty {
        sections.append("Staged diff:\n\(staged)")
    }

    if !unstaged.isEmpty {
        sections.append("Unstaged diff:\n\(unstaged)")
    }

    return sections.joined(separator: "\n\n")
}

private func gitStatusDescription(_ status: String) -> String {
    if status == "??" {
        return "untracked"
    }

    if status.contains("A") {
        return "added"
    }

    if status.contains("D") {
        return "deleted"
    }

    if status.contains("R") {
        return "renamed"
    }

    if status.contains("C") {
        return "copied"
    }

    if status.contains("M") {
        return "modified"
    }

    return status.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func runGitCommand(_ arguments: [String], projectRoot: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    let errorOutput = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = projectRoot
    process.standardOutput = output
    process.standardError = errorOutput

    try process.run()
    process.waitUntilExit()

    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: outputData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw NSError(
            domain: "GitHubMCPServer.Git",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "Unable to run git command."]
        )
    }

    return text
}

private struct GitHubMCPRuntimeConfiguration {
    let projectRoot: URL?
    let vaporArguments: [String]
}

private func runtimeConfiguration(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> GitHubMCPRuntimeConfiguration {
    var projectRootArgument: String?
    var vaporArguments: [String] = []
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]

        if argument == "--project-root" {
            let valueIndex = arguments.index(after: index)
            if valueIndex < arguments.endIndex {
                projectRootArgument = arguments[valueIndex]
                index = arguments.index(after: valueIndex)
            } else {
                index = valueIndex
            }
            continue
        }

        if argument.hasPrefix("--project-root=") {
            projectRootArgument = String(argument.dropFirst("--project-root=".count))
            index = arguments.index(after: index)
            continue
        }

        vaporArguments.append(argument)
        index = arguments.index(after: index)
    }

    let rawProjectRoot = projectRootArgument
        ?? environment["PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return GitHubMCPRuntimeConfiguration(
        projectRoot: rawProjectRoot.flatMap(projectRootURL(from:)),
        vaporArguments: vaporArguments
    )
}

private func projectRootURL(from rawPath: String) -> URL? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
        return nil
    }

    let url: URL
    if path.hasPrefix("/") {
        url = URL(fileURLWithPath: path)
    } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
    }

    return url.standardizedFileURL
}

// MARK: - Vapor <-> MCP bridge

@main
enum GitHubMCPServer {
    static func main() async throws {
        let configuration = runtimeConfiguration()
        var env = try Environment.detect(arguments: configuration.vaporArguments)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3001

        let github = GitHubAPI(
            token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        )

        let jobRepository: JobRepositoryProtocol = InMemoryJobRepository()

        let scheduler = JobScheduler(db: jobRepository)
        await scheduler.start()

        let mcpServer = await makeGitHubMCPServer(
            github: github,
            jobRepository: jobRepository,
            projectRoot: configuration.projectRoot
        )

        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in
            "OK"
        }

        app.on(.POST, "mcp") { req async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "POST",
                headers: mcpHeaders(from: req.headers),
                body: Data(buffer: req.body.data ?? ByteBuffer())
            )

            let httpResponse = await transport.handleRequest(httpRequest)
            return vaporResponse(from: httpResponse)
        }

        try await app.execute()
    }
}
