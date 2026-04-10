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
    jobRepository: JobRepositoryProtocol
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


// MARK: - Vapor <-> MCP bridge

@main
enum GitHubMCPServer {
    static func main() async throws {
        var env = try Environment.detect()
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
            jobRepository: jobRepository
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
