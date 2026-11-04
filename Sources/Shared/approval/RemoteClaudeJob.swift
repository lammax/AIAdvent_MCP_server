import Foundation

public enum RemoteClaudeJobStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct RemoteClaudeJob: Codable, Sendable, Equatable {
    public let agent: String
    public let id: UUID
    public let prompt: String
    public let workingDirectory: String
    public let status: RemoteClaudeJobStatus
    public let response: String?
    public let errorMessage: String?
    public let sessionID: String?
    public let messageQueuedAt: Date?
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        id: UUID,
        prompt: String,
        workingDirectory: String,
        status: RemoteClaudeJobStatus,
        response: String? = nil,
        errorMessage: String? = nil,
        sessionID: String? = nil,
        messageQueuedAt: Date? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        agent: String = "claude"
    ) {
        self.id = id
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.status = status
        self.response = response
        self.errorMessage = errorMessage
        self.sessionID = sessionID
        self.messageQueuedAt = messageQueuedAt
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.agent = agent
    }
}

public enum RemoteClaudeJobError: LocalizedError, Equatable {
    case emptyPrompt
    case promptTooLong
    case invalidWorkingDirectory
    case processFailed(String)
    case notCancellable

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "The Claude request cannot be empty."
        case .promptTooLong:
            "The Claude request is too long."
        case .invalidWorkingDirectory:
            "The configured Claude working directory is unavailable."
        case .processFailed(let message):
            message
        case .notCancellable:
            "Only queued or running Remote tasks can be stopped."
        }
    }
}

public struct RemoteClaudeJobResult: Sendable, Equatable {
    public let response: String
    public let sessionID: String?

    public init(response: String, sessionID: String?) {
        self.response = response
        self.sessionID = sessionID
    }
}
