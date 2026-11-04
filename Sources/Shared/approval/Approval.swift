import Foundation

public enum ApprovalStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case answered
    case expired
    case cancelled
}

public enum ApprovalKind: String, Codable, Sendable, CaseIterable {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
    case text
}

public struct ApprovalQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let kind: ApprovalKind
    public let options: [String]
    public let responses: [String]

    public var response: String? {
        responses.first
    }

    public init(
        id: String,
        question: String,
        kind: ApprovalKind,
        options: [String] = [],
        responses: [String] = []
    ) {
        self.id = id
        self.question = question
        self.kind = kind
        self.options = options
        self.responses = responses
    }
}

public struct ApprovalAnswer: Codable, Equatable, Sendable {
    public let id: String
    public let responses: [String]

    public init(id: String, responses: [String]) {
        self.id = id
        self.responses = responses
    }
}

public struct Approval: Codable, Equatable, Sendable {
    public let source: RemoteRequestSource?
    public let id: UUID
    public let questions: [ApprovalQuestion]
    public let status: ApprovalStatus
    public let createdAt: Date
    public let expiresAt: Date
    public let answeredAt: Date?

    // Compatibility accessors for clients that submit one question per approval.
    public var question: String { questions.first?.question ?? "" }
    public var kind: ApprovalKind { questions.first?.kind ?? .singleSelect }
    public var options: [String] { questions.first?.options ?? [] }
    public var responses: [String] { questions.first?.responses ?? [] }
    public var response: String? { questions.first?.response }

    public init(
        id: UUID,
        questions: [ApprovalQuestion],
        status: ApprovalStatus,
        createdAt: Date,
        expiresAt: Date,
        answeredAt: Date?,
        source: RemoteRequestSource? = nil
    ) {
        self.id = id
        self.questions = questions
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.answeredAt = answeredAt
        self.source = source
    }
}

public struct RemoteRequestSource: Codable, Equatable, Sendable {
    public let agent: String
    public let project: String
    public let chat: String?
    public let taskID: UUID?

    public init(agent: String, project: String, chat: String? = nil, taskID: UUID? = nil) {
        self.agent = agent
        self.project = project
        self.chat = chat
        self.taskID = taskID
    }
}

public struct RemoteAgentMode: Codable, Sendable {
    public let agent: String
    public let enabled: Bool
}

public enum ApprovalError: Error, Equatable, Sendable {
    case emptyQuestion
    case questionTooLong
    case invalidQuestionCount
    case invalidQuestionID
    case duplicateQuestionIDs
    case invalidOptionCount
    case emptyOption
    case optionTooLong
    case duplicateOptions
    case emptyResponse
    case responseTooLong
    case invalidResponse
    case notFound(UUID)
    case alreadyAnswered(UUID)
    case expired(UUID)
    case cancelled(UUID)
    case timedOut(UUID)
}

extension ApprovalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            "Question must not be empty."
        case .questionTooLong:
            "Question exceeds the 4,000 character limit."
        case .invalidQuestionCount:
            "Provide between 1 and 12 questions."
        case .invalidQuestionID:
            "Every question needs an ID between 1 and 100 characters."
        case .duplicateQuestionIDs:
            "Question IDs must be unique."
        case .invalidOptionCount:
            "Provide between 2 and 12 options."
        case .emptyOption:
            "Options must not be empty."
        case .optionTooLong:
            "An option exceeds the 500 character limit."
        case .duplicateOptions:
            "Options must be unique."
        case .emptyResponse:
            "Response must not be empty."
        case .responseTooLong:
            "Response exceeds the 4,000 character limit."
        case .invalidResponse:
            "Response does not match the requested answer type or available options."
        case .notFound(let id):
            "Approval \(id.uuidString) was not found."
        case .alreadyAnswered(let id):
            "Approval \(id.uuidString) has already been answered."
        case .expired(let id):
            "Approval \(id.uuidString) has expired."
        case .cancelled(let id):
            "Approval \(id.uuidString) was cancelled."
        case .timedOut(let id):
            "Approval \(id.uuidString) timed out."
        }
    }
}
