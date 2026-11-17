import Foundation
import Vapor

public struct RemoteBridgeSubmitRequest: Content, Sendable {
    public let agent: String
    public let prompt: String
    public let project: String?
    public let threadID: String?
    public let forceRotation: Bool?
    public let automaticRotation: Bool?
    public let rotationOnly: Bool?

    public init(agent: String = "codex", prompt: String, project: String? = nil, threadID: String? = nil, forceRotation: Bool? = nil, automaticRotation: Bool? = nil, rotationOnly: Bool? = nil) {
        self.agent = agent
        self.prompt = prompt
        self.project = project
        self.threadID = threadID
        self.forceRotation = forceRotation
        self.automaticRotation = automaticRotation
        self.rotationOnly = rotationOnly
    }

    enum CodingKeys: String, CodingKey {
        case agent, prompt, project
        case threadID = "thread_id"
        case forceRotation = "force_rotation"
        case automaticRotation = "automatic_rotation"
        case rotationOnly = "rotation_only"
    }
}

public struct RemoteBridgeJobResponse: Content, Sendable {
    public let id: UUID
    public let agent: String
    public let prompt: String
    public let project: String
    public let status: RemoteClaudeJobStatus
    public let response: String?
    public let error: String?
    public let threadID: String?
    public let pendingApprovalID: UUID?
    public let pendingApproval: Approval?
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    public init(_ job: RemoteClaudeJob, pendingApproval: Approval? = nil) {
        id = job.id
        agent = job.agent
        prompt = job.prompt
        project = job.workingDirectory
        status = job.status
        response = job.response
        error = job.errorMessage
        threadID = job.sessionID
        pendingApprovalID = pendingApproval?.id
        self.pendingApproval = pendingApproval
        createdAt = job.createdAt
        startedAt = job.startedAt
        completedAt = job.completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, prompt, project, status, response, error
        case threadID = "thread_id"
        case pendingApprovalID = "pending_approval_id"
        case pendingApproval = "pending_approval"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

public struct RemoteBridgeApprovalRequest: Content, Sendable {
    public let answers: [ApprovalAnswer]

    public init(answers: [ApprovalAnswer]) {
        self.answers = answers
    }
}

public struct RemoteBridgeHealthResponse: Content, Sendable {
    public let status: String
    public let bridge: String

    public init(status: String = "ok", bridge: String = "remote-agent") {
        self.status = status
        self.bridge = bridge
    }
}

public struct RemoteBridgeProjectResponse: Content, Sendable {
    public let name: String
    public let path: String

    public init(_ project: RemoteProject) {
        name = project.name
        path = project.path
    }

    public init(_ choice: RemoteProjectChoice) {
        name = choice.name
        path = choice.path
    }
}

public struct RemoteBridgeConversationResponse: Content, Sendable {
    public let id: String
    public let title: String
    public let project: String
    public let updatedAt: Double
    public let busy: Bool
    public let open: Bool?
    public let historyBytes: Int64?

    public init(_ conversation: RemoteConversation) {
        id = conversation.id
        title = conversation.title
        project = conversation.project
        updatedAt = conversation.updatedAt
        busy = conversation.busy
        open = conversation.open
        historyBytes = conversation.historyBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, title, project, busy, open
        case updatedAt = "updated_at"
        case historyBytes = "history_bytes"
    }
}

public struct RemoteBridgeUsageResponse: Content, Sendable {
    public let agent: String
    public let text: String
    public let fetchedAt: Date

    public init(agent: String, report: RemoteUsageReport) {
        self.agent = agent
        text = report.text
        fetchedAt = report.fetchedAt
    }

    enum CodingKeys: String, CodingKey {
        case agent, text
        case fetchedAt = "fetched_at"
    }
}

/// Machine-facing bridge for trusted local clients such as EnergyBot.
/// It deliberately shares the existing RemoteClaudeJobService worker, queue,
/// approvals, and SQLite repository with RemoteHTTPServer.
public func configureRemoteBridgeHTTPRoutes(
    app: Application,
    claudeService: RemoteClaudeJobService,
    approvalService: ApprovalService,
    authorization: ApprovalHTTPAuthorization,
    projects: [RemoteProject],
    projectRegistry: RemoteProjectRegistry?,
    conversations: RemoteConversationCatalog?,
    usage: RemoteUsageService? = nil
) {
    @Sendable func requireBridgeAuthorization(_ request: Request) throws {
        guard authorization.isBearerAuthorized(request) else {
            throw Abort(.unauthorized, reason: "Bridge authorization is required.")
        }
    }

    @Sendable func response(for job: RemoteClaudeJob) async throws -> RemoteBridgeJobResponse {
        let approval = try await approvalService.pendingApprovals()
            .first { $0.source?.taskID == job.id }
        return RemoteBridgeJobResponse(job, pendingApproval: approval)
    }

    @Sendable func resolveProject(_ rawProject: String?, agent: String) async throws -> String? {
        guard let rawProject else {
            guard agent == "claude" else {
                throw Abort(.badRequest, reason: "A registered project is required for Codex.")
            }
            return nil
        }
        do {
            if let projectRegistry {
                return try await projectRegistry.resolve(rawProject)
            }
            return try RemoteProject.resolve(rawProject, in: projects)
        } catch {
            throw Abort(.badRequest, reason: "Choose a registered project.")
        }
    }

    @Sendable func resolveThread(_ rawThreadID: String?, agent: String, project: String?) async throws -> String? {
        guard let rawThreadID else { return nil }
        guard UUID(uuidString: rawThreadID) != nil else {
            throw Abort(.badRequest, reason: "thread_id must be a UUID.")
        }
        guard let project, let conversations else {
            throw Abort(.badRequest, reason: "A registered project and conversation catalog are required for thread continuation.")
        }
        do {
            return try await conversations.validate(agent: agent, project: project, id: rawThreadID).id
        } catch RemoteConversationError.missing {
            throw Abort(.conflict, reason: "The requested thread was not found in this project.")
        } catch {
            throw Abort(.serviceUnavailable, reason: RemoteConversationError.unavailable.localizedDescription)
        }
    }

    app.get("v1", "health") { request async throws -> RemoteBridgeHealthResponse in
        try requireBridgeAuthorization(request)
        return RemoteBridgeHealthResponse()
    }

    app.get("v1", "projects") { request async throws -> [RemoteBridgeProjectResponse] in
        try requireBridgeAuthorization(request)
        let agent = request.query[String.self, at: "agent"] ?? "codex"
        guard ["codex", "claude"].contains(agent) else {
            throw Abort(.badRequest, reason: "agent must be codex or claude.")
        }
        if agent == "claude", let conversations {
            do {
                return try await conversations.openClaudeProjectChoices().map(RemoteBridgeProjectResponse.init)
            } catch {
                request.logger.warning("Claude project discovery failed", metadata: [
                    "error-type": "\(String(reflecting: type(of: error)))"
                ])
                throw Abort(.serviceUnavailable, reason: RemoteConversationError.unavailable.localizedDescription)
            }
        }
        let available = await projectRegistry?.projects() ?? projects
        var seen = Set<String>()
        return available.compactMap { project in
            guard seen.insert(project.path).inserted else { return nil }
            return RemoteBridgeProjectResponse(project)
        }
    }

    app.get("v1", "conversations") { request async throws -> [RemoteBridgeConversationResponse] in
        try requireBridgeAuthorization(request)
        let agent = request.query[String.self, at: "agent"] ?? "codex"
        guard ["codex", "claude"].contains(agent) else {
            throw Abort(.badRequest, reason: "agent must be codex or claude.")
        }
        guard let rawProject = request.query[String.self, at: "project"], !rawProject.isEmpty else {
            throw Abort(.badRequest, reason: "A registered project is required.")
        }
        guard let conversations else {
            throw Abort(.serviceUnavailable, reason: "Conversation catalog is not configured.")
        }
        do {
            let project = try await resolveProject(rawProject, agent: agent)
            guard let project else {
                throw Abort(.badRequest, reason: "A registered project is required.")
            }
            return try await conversations.list(agent: agent, project: project).map(RemoteBridgeConversationResponse.init)
        } catch let error as RemoteConversationError {
            switch error {
            case .unavailable:
                throw Abort(.serviceUnavailable, reason: error.localizedDescription)
            case .missing, .busy:
                throw Abort(.conflict, reason: error.localizedDescription)
            }
        }
    }

    app.get("v1", "usage") { request async throws -> RemoteBridgeUsageResponse in
        try requireBridgeAuthorization(request)
        let agent = request.query[String.self, at: "agent"] ?? "codex"
        guard let usage else {
            throw Abort(.serviceUnavailable, reason: "Usage is not configured.")
        }
        do {
            return RemoteBridgeUsageResponse(agent: agent, report: try await usage.report(agent: agent))
        } catch {
            throw Abort(.serviceUnavailable, reason: RemoteUsageError.unavailable.localizedDescription)
        }
    }

    app.post("v1", "jobs") { request async throws -> RemoteBridgeJobResponse in
        try requireBridgeAuthorization(request)
        let body = try request.content.decode(RemoteBridgeSubmitRequest.self)
        guard ["codex", "claude"].contains(body.agent) else {
            throw Abort(.badRequest, reason: "agent must be codex or claude.")
        }
        if body.forceRotation == true || body.rotationOnly == true, body.agent != "codex" {
            throw Abort(.badRequest, reason: "Chat rotation is supported only for codex.")
        }
        if body.rotationOnly == true, body.forceRotation != true {
            throw Abort(.badRequest, reason: "rotation_only requires force_rotation.")
        }
        let project = try await resolveProject(body.project, agent: body.agent)
        let threadID = try await resolveThread(body.threadID, agent: body.agent, project: project)
		let idempotencyKey = request.headers.first(name: "Idempotency-Key")?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let job = try await claudeService.submit(
                prompt: body.prompt,
                agent: body.agent,
                project: project,
                fromWeb: true,
                sessionID: threadID,
				idempotencyKey: idempotencyKey,
                forceRotation: body.forceRotation ?? false,
                automaticRotation: body.automaticRotation ?? true,
                rotationOnly: body.rotationOnly ?? false
            )
            return try await response(for: job)
        } catch let error as RemoteClaudeJobError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
    }

    app.get("v1", "jobs", ":jobID") { request async throws -> RemoteBridgeJobResponse in
        try requireBridgeAuthorization(request)
        guard let rawID = request.parameters.get("jobID"), let id = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "Invalid bridge job ID.")
        }
        guard let job = try await claudeService.job(id: id) else {
            throw Abort(.notFound, reason: "Bridge job was not found.")
        }
        return try await response(for: job)
    }

    app.post("v1", "jobs", ":jobID", "cancel") { request async throws -> RemoteBridgeJobResponse in
        try requireBridgeAuthorization(request)
        guard let rawID = request.parameters.get("jobID"), let id = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "Invalid bridge job ID.")
        }
        guard try await claudeService.job(id: id) != nil else {
            throw Abort(.notFound, reason: "Bridge job was not found.")
        }
        do {
            let cancelled = try await claudeService.cancel(id: id)
            try await approvalService.cancelPendingApprovals(taskID: id)
            return try await response(for: cancelled)
        } catch let error as RemoteClaudeJobError {
            throw Abort(.conflict, reason: error.localizedDescription)
        } catch {
            throw Abort(.internalServerError, reason: "Unable to cancel bridge job.")
        }
    }

    app.post("v1", "approvals", ":approvalID", "respond") { request async throws -> RemoteBridgeJobResponse in
        try requireBridgeAuthorization(request)
        guard let rawID = request.parameters.get("approvalID"), let approvalID = UUID(uuidString: rawID) else {
            throw Abort(.badRequest, reason: "Invalid approval ID.")
        }
        let body = try request.content.decode(RemoteBridgeApprovalRequest.self)
        guard !body.answers.isEmpty else {
            throw Abort(.badRequest, reason: "At least one approval answer is required.")
        }
        guard let approval = try await approvalService.approval(id: approvalID),
              let taskID = approval.source?.taskID else {
            throw Abort(.notFound, reason: "Approval was not found or is not linked to a bridge job.")
        }
        do {
            // A single-select answer from a lightweight client may omit
            // optional text questions. Fill those with an empty response so
            // the bridge keeps the same contract as the web approval form.
            var answers = body.answers
            let answeredIDs = Set(answers.map(\.id))
            if approval.questions.count > 1 {
                for question in approval.questions where
                    question.kind == .text && !answeredIDs.contains(question.id) {
                    answers.append(ApprovalAnswer(id: question.id, responses: []))
                }
            }
            _ = try await approvalService.respond(id: approvalID, answers: answers)
            guard let job = try await claudeService.job(id: taskID) else {
                throw Abort(.notFound, reason: "Bridge job was not found.")
            }
            return try await response(for: job)
        } catch let error as ApprovalError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }
    }
}
