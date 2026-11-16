import Foundation
import Vapor

public struct RemoteBridgeSubmitRequest: Content, Sendable {
    public let agent: String
    public let prompt: String
    public let project: String?
    public let threadID: String?

    public init(agent: String = "codex", prompt: String, project: String? = nil, threadID: String? = nil) {
        self.agent = agent
        self.prompt = prompt
        self.project = project
        self.threadID = threadID
    }

    enum CodingKeys: String, CodingKey {
        case agent, prompt, project
        case threadID = "thread_id"
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
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    public init(_ job: RemoteClaudeJob, pendingApprovalID: UUID? = nil) {
        id = job.id
        agent = job.agent
        prompt = job.prompt
        project = job.workingDirectory
        status = job.status
        response = job.response
        error = job.errorMessage
        threadID = job.sessionID
        self.pendingApprovalID = pendingApprovalID
        createdAt = job.createdAt
        startedAt = job.startedAt
        completedAt = job.completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, prompt, project, status, response, error
        case threadID = "thread_id"
        case pendingApprovalID = "pending_approval_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
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
    conversations: RemoteConversationCatalog?
) {
    @Sendable func requireBridgeAuthorization(_ request: Request) throws {
        guard authorization.isBearerAuthorized(request) else {
            throw Abort(.unauthorized, reason: "Bridge authorization is required.")
        }
    }

    @Sendable func response(for job: RemoteClaudeJob) async throws -> RemoteBridgeJobResponse {
        let pendingApprovalID = try await approvalService.pendingApprovals()
            .first { $0.source?.taskID == job.id }?.id
        return RemoteBridgeJobResponse(job, pendingApprovalID: pendingApprovalID)
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

    app.post("v1", "jobs") { request async throws -> RemoteBridgeJobResponse in
        try requireBridgeAuthorization(request)
        let body = try request.content.decode(RemoteBridgeSubmitRequest.self)
        guard ["codex", "claude"].contains(body.agent) else {
            throw Abort(.badRequest, reason: "agent must be codex or claude.")
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
				idempotencyKey: idempotencyKey
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
}
