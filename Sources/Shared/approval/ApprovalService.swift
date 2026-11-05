import Foundation

public struct ApprovalService: Sendable {
    public static let defaultTimeout: TimeInterval = 300
    public static let defaultResumableTimeout: TimeInterval = 86_400
    public static let defaultResumableWaitTimeout: TimeInterval = 240
    public static let defaultPollInterval: Duration = .milliseconds(500)

    private let repository: any ApprovalRepository
    private let timeout: TimeInterval
    private let resumableTimeout: TimeInterval
    private let resumableWaitTimeout: TimeInterval
    private let pollInterval: Duration

    public init(
        repository: any ApprovalRepository,
        timeout: TimeInterval = ApprovalService.defaultTimeout,
        resumableTimeout: TimeInterval = ApprovalService.defaultResumableTimeout,
        resumableWaitTimeout: TimeInterval = ApprovalService.defaultResumableWaitTimeout,
        pollInterval: Duration = ApprovalService.defaultPollInterval
    ) {
        self.repository = repository
        self.timeout = timeout
        self.resumableTimeout = resumableTimeout
        self.resumableWaitTimeout = resumableWaitTimeout
        self.pollInterval = pollInterval
    }

    public func create(
        question: String,
        options: [String],
        kind: ApprovalKind = .singleSelect,
        now: Date = Date()
    ) async throws -> Approval {
        try await create(
            questions: [
                ApprovalQuestion(
                    id: "answer",
                    question: question,
                    kind: kind,
                    options: options
                )
            ],
            now: now
        )
    }

    public func create(
        questions: [ApprovalQuestion],
        now: Date = Date(),
        source: RemoteRequestSource? = nil
    ) async throws -> Approval {
        let normalizedQuestions = try normalized(questions: questions)

        let approval = Approval(
            id: UUID(),
            questions: normalizedQuestions,
            status: .pending,
            createdAt: now,
            expiresAt: now.addingTimeInterval(timeout),
            answeredAt: nil,
            source: source
        )
        try await repository.create(approval)
        return approval
    }

    public func createOrResumeAndWait(
        questions: [ApprovalQuestion],
        source: RemoteRequestSource?,
        now: Date = Date()
    ) async throws -> Approval {
        guard source?.taskID != nil else {
            return try await createAndWait(questions: questions, source: source)
        }
        let normalizedQuestions = try normalized(questions: questions)
        let candidate = Approval(
            id: UUID(),
            questions: normalizedQuestions,
            status: .pending,
            createdAt: now,
            expiresAt: now.addingTimeInterval(resumableTimeout),
            answeredAt: nil,
            source: source
        )
        let approval = try await repository.createOrFindResumable(candidate, now: now)
        return try await waitForResponse(
            id: approval.id,
            returnPendingAfter: resumableWaitTimeout
        )
    }

    public func createAndWait(
        question: String,
        options: [String],
        kind: ApprovalKind = .singleSelect
    ) async throws -> Approval {
        try await createAndWait(
            questions: [
                ApprovalQuestion(
                    id: "answer",
                    question: question,
                    kind: kind,
                    options: options
                )
            ]
        )
    }

    public func createAndWait(questions: [ApprovalQuestion], source: RemoteRequestSource? = nil) async throws -> Approval {
        let approval = try await create(questions: questions, source: source)
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
        try await waitForResponse(id: id, returnPendingAfter: nil)
    }

    private func waitForResponse(
        id: UUID,
        returnPendingAfter waitTimeout: TimeInterval?
    ) async throws -> Approval {
        let waitDeadline = waitTimeout.map { Date().addingTimeInterval($0) }
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

            if let waitDeadline, now >= waitDeadline {
                return approval
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
        try await respond(id: id, responses: [response], now: now)
    }

    public func respond(id: UUID, responses: [String], now: Date = Date()) async throws -> Approval {
        try await respond(
            id: id,
            answers: [ApprovalAnswer(id: "answer", responses: responses)],
            now: now
        )
    }

    public func respond(id: UUID, answers: [ApprovalAnswer], now: Date = Date()) async throws -> Approval {
        try await repository.respond(
            id: id,
            answers: answers.map { answer in
                ApprovalAnswer(
                    id: answer.id.trimmingCharacters(in: .whitespacesAndNewlines),
                    responses: answer.responses.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            },
            now: now
        )
    }

    public func cancel(id: UUID, now: Date = Date()) async throws {
        try await repository.cancel(id: id, now: now)
    }

    public func cancelPendingApprovals(taskID: UUID, now: Date = Date()) async throws {
        try await repository.cancelPendingApprovals(taskID: taskID, now: now)
    }

    private func normalized(questions: [ApprovalQuestion]) throws -> [ApprovalQuestion] {
        let normalizedQuestions = questions.map {
            ApprovalQuestion(
                id: $0.id.trimmingCharacters(in: .whitespacesAndNewlines),
                question: $0.question.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: $0.kind,
                options: $0.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
        }
        try validate(questions: normalizedQuestions)
        return normalizedQuestions
    }

    private func validate(questions: [ApprovalQuestion]) throws {
        guard (1...12).contains(questions.count) else {
            throw ApprovalError.invalidQuestionCount
        }
        guard questions.allSatisfy({ (1...100).contains($0.id.count) }) else {
            throw ApprovalError.invalidQuestionID
        }
        guard Set(questions.map(\.id)).count == questions.count else {
            throw ApprovalError.duplicateQuestionIDs
        }
        for question in questions {
            guard !question.question.isEmpty else { throw ApprovalError.emptyQuestion }
            guard question.question.count <= 4_000 else { throw ApprovalError.questionTooLong }
            if question.kind == .text {
                guard question.options.isEmpty else { throw ApprovalError.invalidOptionCount }
                continue
            }
            guard (2...12).contains(question.options.count) else {
                throw ApprovalError.invalidOptionCount
            }
            guard question.options.allSatisfy({ !$0.isEmpty }) else {
                throw ApprovalError.emptyOption
            }
            guard question.options.allSatisfy({ $0.count <= 500 }) else {
                throw ApprovalError.optionTooLong
            }
            guard Set(question.options).count == question.options.count else {
                throw ApprovalError.duplicateOptions
            }
        }
    }
}
