// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Vapor
import MCP
internal import NIOFoundationCompat

// MARK: - Models

struct GitHubRepo: Codable {
    let full_name: String
    let description: String?
    let stargazers_count: Int
    let forks_count: Int
    let open_issues_count: Int
    let default_branch: String
    let language: String?
    let html_url: String
}

enum GitHubAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GitHub URL."
        case .invalidResponse:
            return "Invalid GitHub response."
        case let .badStatus(code, body):
            return "GitHub API error \(code): \(body)"
        }
    }
}

// MARK: - GitHub API

struct GitHubAPI {
    let token: String?

    func fetchRepo(owner: String, repo: String) async throws -> GitHubRepo {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
            throw GitHubAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw GitHubAPIError.badStatus(http.statusCode, body)
        }

        return try JSONDecoder().decode(GitHubRepo.self, from: data)
    }
}

// MARK: - MCP server factory

func makeMCPServer(github: GitHubAPI) async -> MCP.Server {
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
                                "description": .string("GitHub owner or organization, for example 'apple'")
                            ]),
                            "repo": .object([
                                "type": .string("string"),
                                "description": .string("Repository name, for example 'swift'")
                            ])
                        ]),
                        "required": .array([
                            .string("owner"),
                            .string("repo")
                        ])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "github_get_repo" else {
            return .init(
                content: [
                    .text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }

        guard
            let owner = params.arguments?["owner"]?.stringValue,
            !owner.isEmpty,
            let repo = params.arguments?["repo"]?.stringValue,
            !repo.isEmpty
        else {
            return .init(
                content: [
                    .text(text: "Missing required parameters: owner and repo", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }

        do {
            let result = try await github.fetchRepo(owner: owner, repo: repo)
            let data = try JSONEncoder().encode(result)
            let json = String(data: data, encoding: .utf8) ?? "{}"

            return .init(
                content: [
                    .text(text: json, annotations: nil, _meta: nil)
                ],
                isError: false
            )
        } catch {
            return .init(
                content: [
                    .text(text: error.localizedDescription, annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }
    }

    return server
}

// MARK: - Vapor <-> MCP bridge

@main
enum MCP_server {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3001

        let github = GitHubAPI(
            token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        )

        let mcpServer = await makeMCPServer(github: github)
        let transport = StatefulHTTPServerTransport()

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

        app.on(.GET, "mcp") { req async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "GET",
                headers: mcpHeaders(from: req.headers),
                body: Data()
            )

            let httpResponse = await transport.handleRequest(httpRequest)
            return vaporResponse(from: httpResponse)
        }

        app.on(.DELETE, "mcp") { req async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "DELETE",
                headers: mcpHeaders(from: req.headers),
                body: Data()
            )

            let httpResponse = await transport.handleRequest(httpRequest)
            return vaporResponse(from: httpResponse)
        }

        try await app.execute()
    }
}

// MARK: - Header / body mapping

private func mcpHeaders(from headers: HTTPHeaders) -> [String: String] {
    var result: [String: String] = [:]
    for header in headers {
        result[header.name] = header.value
    }
    return result
}

private func vaporResponse(from response: HTTPResponse) -> Vapor.Response {
    var headers = HTTPHeaders()
    for (name, value) in response.headers {
        headers.add(name: name, value: value)
    }

    let data = response.bodyData ?? Data()

    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)

    return Response(
        status: HTTPResponseStatus(statusCode: response.statusCode),
        headers: headers,
        body: .init(buffer: buffer)
    )
}
