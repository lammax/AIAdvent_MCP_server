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

// MARK: - GitHub API

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

// MARK: - Helpers

private func jsonString(from object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - MCP server factory

func makeMCPServer(
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
    
    // MARK: - LIST TOOLS
    
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
    
    // MARK: - CALL TOOL
    
    await server.withMethodHandler(CallTool.self) { params in
        
        switch params.name {
            
        // MARK: github_get_repo
            
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
            
            
        // MARK: schedule_summary
            
        case "schedule_summary":
            print("schedule_summary args:", params.arguments ?? [:])
            
            let owner = params.arguments?["owner"]?.stringValue
            let repo = params.arguments?["repo"]?.stringValue
            let interval: Double? = parseIntervalSeconds(from: params.arguments?["interval_seconds"])

            print("schedule_summary args:", params.arguments ?? [:])
            print("owner:", owner ?? "nil")
            print("repo:", repo ?? "nil")
            print("interval:", interval ?? .zero)

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
            
            
        // MARK: get_summary
            
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
            
            
        // MARK: cancel_job
            
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
            
            
        // MARK: default
            
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

        // TODO: подставь свою реальную реализацию
        let jobRepository: JobRepositoryProtocol = InMemoryJobRepository()
        
        let scheduler = JobScheduler(db: jobRepository)
        await scheduler.start()

        let mcpServer = await makeMCPServer(
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

// MARK: - Temporary in-memory repository for MVP

actor InMemoryJobRepository: JobRepositoryProtocol {
    private var jobs: [String: Job] = [:]
    private var results: [String: [JobResult]] = [:]

    func save(_ job: Job) async throws {
        jobs[job.id] = job
    }

    func fetchDueJobs(_ date: Date) async throws -> [Job] {
        jobs.values
            .filter { $0.isActive && $0.nextRunAt <= date }
            .sorted { $0.nextRunAt < $1.nextRunAt }
    }

    func updateNextRun(jobId: String) async throws {
        guard var job = jobs[jobId] else { return }
        job.nextRunAt = Date().addingTimeInterval(job.interval)
        jobs[jobId] = job
    }

    func deactivate(jobId: String) async throws {
        guard var job = jobs[jobId] else { return }
        job.isActive = false
        jobs[jobId] = job
    }

    func saveResult(jobId: String, data: String) async throws {
        let result = JobResult(
            id: UUID().uuidString,
            jobId: jobId,
            createdAt: Date(),
            data: data
        )

        results[jobId, default: []].append(result)
    }

    func latestResult(jobId: String) async throws -> String? {
        results[jobId]?
            .sorted { $0.createdAt < $1.createdAt }
            .last?
            .data
    }
}
