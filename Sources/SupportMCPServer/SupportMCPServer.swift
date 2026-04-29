import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

// MARK: - MCP server factory

func makeSupportMCPServer(dataStore: SupportDataStore) async -> MCP.Server {
    let server = Server(
        name: "support-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "support_get_ticket",
                    description: "Get a support ticket by id from the configured support data source.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "ticketId": .object([
                                "type": .string("string"),
                                "description": .string("Support ticket id, for example T-1001.")
                            ])
                        ]),
                        "required": .array([.string("ticketId")])
                    ])
                ),
                Tool(
                    name: "support_get_user",
                    description: "Get support user context by user id from the configured support data source.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "userId": .object([
                                "type": .string("string"),
                                "description": .string("Support user id, for example U-42.")
                            ])
                        ]),
                        "required": .array([.string("userId")])
                    ])
                ),
                Tool(
                    name: "support_search_tickets",
                    description: "Search support tickets by id, subject, message, status, or metadata.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string")
                            ])
                        ]),
                        "required": .array([.string("query")])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "support_get_ticket":
                let ticketId = try requiredString("ticketId", from: params.arguments)
                let ticket = try dataStore.ticket(id: ticketId)
                return try jsonToolResult(ticket)

            case "support_get_user":
                let userId = try requiredString("userId", from: params.arguments)
                let user = try dataStore.user(id: userId)
                return try jsonToolResult(user)

            case "support_search_tickets":
                let query = try requiredString("query", from: params.arguments)
                let tickets = try dataStore.searchTickets(query: query)
                return try jsonToolResult(tickets)

            default:
                return .init(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

// MARK: - Data store

struct SupportUser: Codable {
    let userId: String
    let name: String
    let plan: String
    let emailVerified: Bool
    let lastLoginAt: String
}

struct SupportTicket: Codable {
    let ticketId: String
    let userId: String
    let subject: String
    let status: String
    let messages: [String]
    let metadata: [String: String]
}

final class SupportDataStore: Sendable {
    private let dataRoot: URL

    init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    func ticket(id: String) throws -> SupportTicket {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ticket = try tickets().first(where: { $0.ticketId.caseInsensitiveCompare(normalizedId) == .orderedSame }) else {
            throw SupportDataError.notFound("Ticket \(normalizedId) was not found.")
        }

        return ticket
    }

    func user(id: String) throws -> SupportUser {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = try users().first(where: { $0.userId.caseInsensitiveCompare(normalizedId) == .orderedSame }) else {
            throw SupportDataError.notFound("User \(normalizedId) was not found.")
        }

        return user
    }

    func searchTickets(query: String) throws -> [SupportTicket] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let queryTerms = searchTerms(in: normalizedQuery)

        return try tickets()
            .compactMap { ticket -> (ticket: SupportTicket, score: Int)? in
                let searchableText = searchableTicketText(ticket)

                if searchableText.contains(normalizedQuery) {
                    return (ticket, 100 + queryTerms.count)
                }

                let score = queryTerms.reduce(0) { partialResult, term in
                    partialResult + (searchableText.contains(term) ? 1 : 0)
                }

                guard score > 0 else {
                    return nil
                }

                return (ticket, score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.ticket.ticketId < rhs.ticket.ticketId
                }

                return lhs.score > rhs.score
            }
            .map(\.ticket)
    }

    private func tickets() throws -> [SupportTicket] {
        try decode([SupportTicket].self, from: dataRoot.appendingPathComponent("tickets.json"))
    }

    private func users() throws -> [SupportUser] {
        try decode([SupportUser].self, from: dataRoot.appendingPathComponent("users.json"))
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func searchableTicketText(_ ticket: SupportTicket) -> String {
        [
            ticket.ticketId,
            ticket.userId,
            ticket.subject,
            ticket.status,
            ticket.messages.joined(separator: " "),
            ticket.metadata.map { "\($0.key) \($0.value)" }.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func searchTerms(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "for", "how", "is", "it", "not", "of", "or", "the", "to", "why",
            "как", "не", "почему", "что", "это"
        ]

        return text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { term in
                term.count >= 3 && !stopWords.contains(term)
            }
    }
}

enum SupportDataError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let message):
            return message
        }
    }
}

private func jsonToolResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let json = String(data: data, encoding: .utf8) ?? "{}"

    return .init(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: false
    )
}

private func requiredString(_ key: String, from arguments: [String: Value]?) throws -> String {
    guard
        let value = arguments?[key]?.stringValue,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw NSError(
            domain: "SupportMCPServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing parameter: \(key)"]
        )
    }

    return value
}

// MARK: - Runtime configuration

private struct SupportMCPRuntimeConfiguration {
    let dataRoot: URL?
    let vaporArguments: [String]
}

private func runtimeConfiguration(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> SupportMCPRuntimeConfiguration {
    var dataRootArgument: String?
    var vaporArguments: [String] = []
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]

        if argument == "--data-root" {
            let valueIndex = arguments.index(after: index)
            if valueIndex < arguments.endIndex {
                dataRootArgument = arguments[valueIndex]
                index = arguments.index(after: valueIndex)
            } else {
                index = valueIndex
            }
            continue
        }

        if argument.hasPrefix("--data-root=") {
            dataRootArgument = String(argument.dropFirst("--data-root=".count))
            index = arguments.index(after: index)
            continue
        }

        vaporArguments.append(argument)
        index = arguments.index(after: index)
    }

    let rawDataRoot = dataRootArgument
        ?? environment["SUPPORT_DATA_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return SupportMCPRuntimeConfiguration(
        dataRoot: rawDataRoot.flatMap(dataRootURL(from:)),
        vaporArguments: vaporArguments
    )
}

private func dataRootURL(from rawPath: String) -> URL? {
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
enum SupportMCPServer {
    static func main() async throws {
        let configuration = runtimeConfiguration()
        var env = try Environment.detect(arguments: configuration.vaporArguments)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3004

        guard let dataRoot = configuration.dataRoot else {
            throw NSError(
                domain: "SupportMCPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Support data root is not configured. Set SUPPORT_DATA_ROOT or pass --data-root."]
            )
        }

        let mcpServer = await makeSupportMCPServer(
            dataStore: SupportDataStore(dataRoot: dataRoot)
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
