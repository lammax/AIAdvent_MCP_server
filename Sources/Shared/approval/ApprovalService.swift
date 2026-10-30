import Foundation

public struct ApprovalService: Sendable {
    public static let defaultTimeout: TimeInterval = 300
    public static let defaultPollInterval: Duration = .milliseconds(500)

    private let repository: any ApprovalRepository
    private let timeout: TimeInterval
    private let pollInterval: Duration

    public init(
        repository: any ApprovalRepository,
        timeout: TimeInterval = ApprovalService.defaultTimeout,
        pollInterval: Duration = ApprovalService.defaultPollInterval
    ) {
        self.repository = repository
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func create(
        question: String,
        options: [String],
        now: Date = Date()
    ) async throws -> Approval {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptions = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try validate(question: normalizedQuestion, options: normalizedOptions)

        let approval = Approval(
            id: UUID(),
            question: normalizedQuestion,
            options: normalizedOptions,
            status: .pending,
            response: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(timeout),
            answeredAt: nil
        )
        try await repository.create(approval)
        return approval
    }

    public func createAndWait(question: String, options: [String]) async throws -> Approval {
        let approval = try await create(question: question, options: options)
        do {
            return try await waitForResponse(id: approval.id)
        } catch is CancellationError {
            let cleanupRepository = repository
            let cleanup = Task { @concurrent in
                try? await cleanupRepository.cancel(id: approval.id, now: Date())
            }
            _ = await cleanup.value
            throw CancellationError()
        }
    }

    public func waitForResponse(id: UUID) async throws -> Approval {
        while true {
            try Task.checkCancellation()
            let now = Date()
            guard let approval = try await repository.approval(id: id, now: now) else {
                throw ApprovalError.notFound(id)
            }

            switch approval.status {
            case .answered:
                return approval
            case .expired:
                throw ApprovalError.timedOut(id)
            case .cancelled:
                throw ApprovalError.cancelled(id)
            case .pending:
                break
            }

            try await Task.sleep(for: pollInterval)
        }
    }

    public func approval(id: UUID, now: Date = Date()) async throws -> Approval? {
        try await repository.approval(id: id, now: now)
    }

    public func pendingApprovals(now: Date = Date()) async throws -> [Approval] {
        try await repository.pendingApprovals(now: now)
    }

    public func respond(id: UUID, response: String, now: Date = Date()) async throws -> Approval {
        try await repository.respond(
            id: id,
            response: response.trimmingCharacters(in: .whitespacesAndNewlines),
            now: now
        )
    }

    public func cancel(id: UUID, now: Date = Date()) async throws {
        try await repository.cancel(id: id, now: now)
    }

    private func validate(question: String, options: [String]) throws {
        guard !question.isEmpty else { throw ApprovalError.emptyQuestion }
        guard question.count <= 4_000 else { throw ApprovalError.questionTooLong }
        guard (2...12).contains(options.count) else { throw ApprovalError.invalidOptionCount }
        guard options.allSatisfy({ !$0.isEmpty }) else { throw ApprovalError.emptyOption }
        guard options.allSatisfy({ $0.count <= 500 }) else { throw ApprovalError.optionTooLong }
        guard Set(options).count == options.count else { throw ApprovalError.duplicateOptions }
    }
}
