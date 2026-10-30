import Foundation

public enum ApprovalStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case answered
    case expired
    case cancelled
}

public struct Approval: Codable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let options: [String]
    public let status: ApprovalStatus
    public let response: String?
    public let createdAt: Date
    public let expiresAt: Date
    public let answeredAt: Date?

    public init(
        id: UUID,
        question: String,
        options: [String],
        status: ApprovalStatus,
        response: String?,
        createdAt: Date,
        expiresAt: Date,
        answeredAt: Date?
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.status = status
        self.response = response
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.answeredAt = answeredAt
    }
}

public enum ApprovalError: Error, Equatable, Sendable {
    case emptyQuestion
    case questionTooLong
    case invalidOptionCount
    case emptyOption
    case optionTooLong
    case duplicateOptions
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
        case .invalidOptionCount:
            "Provide between 2 and 12 options."
        case .emptyOption:
            "Options must not be empty."
        case .optionTooLong:
            "An option exceeds the 500 character limit."
        case .duplicateOptions:
            "Options must be unique."
        case .invalidResponse:
            "Response must exactly match one of the available options."
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
