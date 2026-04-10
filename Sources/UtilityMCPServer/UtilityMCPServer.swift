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

func makeUtilityMCPServer(github: GitHubAPI) async -> MCP.Server {
    let server = Server(
        name: "utility-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "search_data",
                    description: "Search or fetch source data for pipeline input. For MVP expects owner/repo.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("query")
                        ])
                    ])
                ),

                Tool(
                    name: "summarize_text",
                    description: "Summarize input text.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("text")
                        ])
                    ])
                ),

                Tool(
                    name: "save_to_file",
                    description: "Save text to a local file.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "filename": .object([
                                "type": .string("string")
                            ]),
                            "content": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("filename"),
                            .string("content")
                        ])
                    ])
                ),

                Tool(
                    name: "run_pipeline",
                    description: "Run search -> summarize -> save pipeline automatically.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string")
                            ]),
                            "filename": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([
                            .string("query"),
                            .string("filename")
                        ])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {

        case "search_data":
            guard
                let query = params.arguments?["query"]?.stringValue,
                !query.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing query", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let rawText = try await searchData(query: query, github: github)
                return .init(
                    content: [.text(text: rawText, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "summarize_text":
            guard
                let text = params.arguments?["text"]?.stringValue,
                !text.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing text", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            let summary = summarizeText(text)

            return .init(
                content: [.text(text: summary, annotations: nil, _meta: nil)],
                isError: false
            )

        case "save_to_file":
            guard
                let filename = params.arguments?["filename"]?.stringValue,
                !filename.isEmpty,
                let content = params.arguments?["content"]?.stringValue
            else {
                return .init(
                    content: [.text(text: "Missing filename or content", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let path = try saveToFile(filename: filename, content: content)
                return .init(
                    content: [.text(text: path, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

        case "run_pipeline":
            guard
                let query = params.arguments?["query"]?.stringValue,
                !query.isEmpty,
                let filename = params.arguments?["filename"]?.stringValue,
                !filename.isEmpty
            else {
                return .init(
                    content: [.text(text: "Missing query or filename", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let rawText = try await searchData(query: query, github: github)
                let summary = summarizeText(rawText)
                let filePath = try saveToFile(filename: filename, content: summary)

                let pipelineResult = PipelineResult(
                    query: query,
                    rawText: rawText,
                    summary: summary,
                    filePath: filePath
                )

                let data = try JSONEncoder().encode(pipelineResult)
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

// MARK: - Helpers

private func searchData(query: String, github: GitHubAPI) async throws -> String {
    let parts = query.split(separator: "/").map(String.init)
    guard parts.count == 2 else {
        throw NSError(
            domain: "Pipeline",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Query must be in format owner/repo"]
        )
    }

    let repo = try await github.fetchRepo(owner: parts[0], repo: parts[1])

    return """
    Repository: \(repo.full_name)
    Description: \(repo.description ?? "n/a")
    Stars: \(repo.stargazers_count)
    Forks: \(repo.forks_count)
    Open issues: \(repo.open_issues_count)
    Default branch: \(repo.default_branch)
    Language: \(repo.language ?? "n/a")
    URL: \(repo.html_url)
    """
}

private func summarizeText(_ text: String) -> String {
    let lines = text
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    return lines.prefix(4).joined(separator: "\n")
}

private func saveToFile(filename: String, content: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_pipeline", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let url = dir.appendingPathComponent(filename)
    try content.write(to: url, atomically: true, encoding: .utf8)

    return url.path
}

// MARK: - Vapor <-> MCP bridge

@main
enum UtilityMCPServer {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3002

        let github = GitHubAPI(
            token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        )

        let mcpServer = await makeUtilityMCPServer(github: github)

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
