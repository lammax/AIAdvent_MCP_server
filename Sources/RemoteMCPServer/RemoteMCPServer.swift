import Foundation
import MCP
import Shared

private struct ApprovalToolOutput: Codable, Sendable {
    let requestId: UUID
    let status: ApprovalStatus
    let answers: [ApprovalToolAnswer]
    let response: String?
    let responses: [String]
}

private struct ApprovalToolAnswer: Codable, Sendable {
    let id: String
    let type: ApprovalKind
    let response: String?
    let responses: [String]
}

private enum ToolInputError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

private func parseQuestions(arguments: [String: MCP.Value]?) throws -> [ApprovalQuestion] {
    if let questionsValue = arguments?["questions"] {
        guard let values = questionsValue.arrayValue else {
            throw ToolInputError.invalid("Questions must be an array.")
        }
        return try values.map { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let question = object["question"]?.stringValue,
                  let rawType = object["type"]?.stringValue,
                  let kind = ApprovalKind(rawValue: rawType)
            else {
                throw ToolInputError.invalid(
                    "Every question requires string id, question, and valid type fields."
                )
            }
            return ApprovalQuestion(
                id: id,
                question: question,
                kind: kind,
                options: try parseOptions(object["options"])
            )
        }
    }

    guard let question = arguments?["question"]?.stringValue else {
        throw ToolInputError.invalid("Provide questions or the legacy question field.")
    }
    let rawMode = arguments?["mode"]?.stringValue ?? ApprovalKind.singleSelect.rawValue
    guard let kind = ApprovalKind(rawValue: rawMode) else {
        throw ToolInputError.invalid("Unknown answer mode: \(rawMode)")
    }
    return [
        ApprovalQuestion(
            id: "answer",
            question: question,
            kind: kind,
            options: try parseOptions(arguments?["options"])
        )
    ]
}

private func parseOptions(_ value: MCP.Value?) throws -> [String] {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue else {
        throw ToolInputError.invalid("Options must be an array of strings.")
    }
    let options = rawOptions.compactMap(\.stringValue)
    guard options.count == rawOptions.count else {
        throw ToolInputError.invalid("Every option must be a string.")
    }
    return options
}

private func makeRemoteMCPServer(service: ApprovalService, repository: SQLiteApprovalRepository) async -> MCP.Server {
    let server = Server(
        name: "remote-mcp-server",
        version: "1.0.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(name: "remote_mode", description: "Read or change Remote mode for one agent. Does not stop the shared HTTP service.",
                 inputSchema: .object(["type": .string("object"), "properties": .object([
                    "agent": .object(["type": .string("string"), "enum": .array([.string("codex"), .string("claude")])]),
                    "enabled": .object(["type": .string("boolean")])
                 ]), "required": .array([.string("agent")]), "additionalProperties": .bool(false)])),
            Tool(
                name: "ask_user",
                description: "Ask one or more questions in a single remote request. Each question can be single-select, multi-select, or free text. A lone free-text question requires an answer; free-text fields in a multi-question request are optional comments. Waits for the human response and never invents an answer. Prefer the questions array; legacy question/mode/options fields remain supported.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "agent": .object(["type": .string("string"), "enum": .array([.string("codex"), .string("claude")])]),
                        "project": .object(["type": .string("string"), "maxLength": .int(1024), "description": .string("Absolute project directory; display context, not execution authority.")]),
                        "chat": .object(["type": .string("string"), "maxLength": .int(200), "description": .string("Originating chat ID or label.")]),
                        "task_id": .object(["type": .string("string"), "format": .string("uuid"), "description": .string("Remote task UUID used to show waiting state on its task card.")]),
                        "questions": .object([
                            "type": .string("array"),
                            "minItems": .int(1),
                            "maxItems": .int(12),
                            "description": .string("Questions shown together and submitted in one response."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object([
                                        "type": .string("string"),
                                        "description": .string("Unique stable ID used to match the answer.")
                                    ]),
                                    "question": .object([
                                        "type": .string("string")
                                    ]),
                                    "type": .object([
                                        "type": .string("string"),
                                        "enum": .array([
                                            .string(ApprovalKind.singleSelect.rawValue),
                                            .string(ApprovalKind.multiSelect.rawValue),
                                            .string(ApprovalKind.text.rawValue)
                                        ])
                                    ]),
                                    "options": .object([
                                        "type": .string("array"),
                                        "items": .object(["type": .string("string")]),
                                        "maxItems": .int(12),
                                        "description": .string("Required for selection types; omit for text.")
                                    ])
                                ]),
                                "required": .array([
                                    .string("id"), .string("question"), .string("type")
                                ]),
                                "additionalProperties": .bool(false)
                            ])
                        ]),
                        "question": .object([
                            "type": .string("string"),
                            "description": .string("Legacy single-question form.")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string(ApprovalKind.singleSelect.rawValue),
                                .string(ApprovalKind.multiSelect.rawValue),
                                .string(ApprovalKind.text.rawValue)
                            ]),
                            "default": .string(ApprovalKind.singleSelect.rawValue),
                            "description": .string("Answer type. Omit for a single selection.")
                        ]),
                        "options": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "maxItems": .int(12),
                            "description": .string("Required for selection modes (2-12 unique options); omit for text mode.")
                        ])
                    ]),
                    "additionalProperties": .bool(false)
                ])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        if params.name == "remote_mode" {
            do {
                guard let agent = params.arguments?["agent"]?.stringValue, ["codex", "claude"].contains(agent) else {
                    throw ToolInputError.invalid("Choose codex or claude.")
                }
                if let enabled = params.arguments?["enabled"] {
                    guard let value = enabled.boolValue else { throw ToolInputError.invalid("enabled must be boolean.") }
                    try await repository.setRemoteMode(agent: agent, enabled: value)
                }
                let modes = try await repository.remoteModes()
                let enabled = modes.first { $0.agent == agent }?.enabled ?? false
                return .init(content: [.text(text: "\(agent): \(enabled ? "enabled" : "disabled")", annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }
        }
        guard params.name == "ask_user" else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let source: RemoteRequestSource?
            if let agent = params.arguments?["agent"]?.stringValue {
                guard ["codex", "claude"].contains(agent),
                      let project = params.arguments?["project"]?.stringValue,
                      project.hasPrefix("/"), project.count <= 1024,
                      (params.arguments?["chat"]?.stringValue?.count ?? 0) <= 200
                else { throw ToolInputError.invalid("Source requires a valid agent and absolute project directory.") }
                let rawTaskID = params.arguments?["task_id"]?.stringValue
                guard rawTaskID == nil || rawTaskID.flatMap(UUID.init(uuidString:)) != nil else {
                    throw ToolInputError.invalid("task_id must be a UUID.")
                }
                source = RemoteRequestSource(
                    agent: agent,
                    project: project,
                    chat: params.arguments?["chat"]?.stringValue,
                    taskID: rawTaskID.flatMap(UUID.init(uuidString:))
                )
            } else {
                source = nil
            }
            let approval = try await service.createAndWait(
                questions: try parseQuestions(arguments: params.arguments),
                source: source
            )
            let answers = approval.questions.map {
                ApprovalToolAnswer(
                    id: $0.id,
                    type: $0.kind,
                    response: $0.response,
                    responses: $0.responses
                )
            }
            let output = ApprovalToolOutput(
                requestId: approval.id,
                status: approval.status,
                answers: answers,
                response: approval.response,
                responses: approval.responses
            )
            let summary = answers.map {
                "\($0.id): \($0.responses.joined(separator: ", "))"
            }.joined(separator: "\n")
            return try .init(
                content: [
                    .text(
                        text: summary,
                        annotations: nil,
                        _meta: nil
                    )
                ],
                structuredContent: output,
                isError: false
            )
        } catch let error as ToolInputError {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch let error as ApprovalError {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch is CancellationError {
            return .init(
                content: [.text(text: "Approval request was cancelled.", annotations: nil, _meta: nil)],
                isError: true
            )
        } catch {
            return .init(
                content: [.text(text: "Approval request failed.", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

@main
enum RemoteMCPServer {
    static func main() async throws {
        let configuration = try RemoteServiceConfiguration.load()
        let repository = try SQLiteApprovalRepository(path: configuration.databasePath)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--agent-mode") {
            guard arguments.count == index + 3,
                  ["codex", "claude"].contains(arguments[index + 1]),
                  ["start", "stop", "status"].contains(arguments[index + 2]) else {
                throw ToolInputError.invalid("Use --agent-mode codex|claude start|stop|status")
            }
            let agent = arguments[index + 1]
            let action = arguments[index + 2]
            if action != "status" { try await repository.setRemoteMode(agent: agent, enabled: action == "start") }
            let enabled = try await repository.remoteModes().first { $0.agent == agent }?.enabled ?? false
            print("\(agent): \(enabled ? "enabled" : "disabled")")
            return
        }
        let service = ApprovalService(repository: repository, timeout: configuration.timeout)
        let server = await makeRemoteMCPServer(service: service, repository: repository)
        let transport = RemoteMCPTransport(base: StdioTransport())

        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
