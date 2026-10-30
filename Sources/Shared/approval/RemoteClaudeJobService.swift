import Foundation

public actor RemoteClaudeJobService {
    public static let maximumPromptLength = 20_000

    private let repository: any RemoteClaudeJobRepository
    private let runner: any RemoteClaudeJobRunning
    private let workingDirectory: String
    private var worker: Task<Void, Never>?

    public init(
        repository: any RemoteClaudeJobRepository,
        runner: any RemoteClaudeJobRunning,
        workingDirectory: String
    ) {
        self.repository = repository
        self.runner = runner
        self.workingDirectory = workingDirectory
    }

    public func start() async throws {
        try await repository.requeueInterruptedClaudeJobs()
        startWorkerIfNeeded()
    }

    public func submit(prompt: String, now: Date = Date()) async throws -> RemoteClaudeJob {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { throw RemoteClaudeJobError.emptyPrompt }
        guard normalizedPrompt.count <= Self.maximumPromptLength else {
            throw RemoteClaudeJobError.promptTooLong
        }

        let job = RemoteClaudeJob(
            id: UUID(),
            prompt: normalizedPrompt,
            workingDirectory: workingDirectory,
            status: .queued,
            createdAt: now
        )
        try await repository.createClaudeJob(job)
        startWorkerIfNeeded()
        return job
    }

    public func recentJobs(limit: Int = 20) async throws -> [RemoteClaudeJob] {
        try await repository.recentClaudeJobs(limit: max(1, min(limit, 100)))
    }

    public func job(id: UUID) async throws -> RemoteClaudeJob? {
        try await repository.claudeJob(id: id)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await runQueue() }
    }

    private func runQueue() async {
        while !Task.isCancelled {
            do {
                guard let job = try await repository.claimNextClaudeJob(startedAt: Date()) else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                do {
                    let result = try await runner.run(job: job)
                    try await repository.completeClaudeJob(
                        id: job.id,
                        result: result,
                        completedAt: Date()
                    )
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                    try await repository.failClaudeJob(
                        id: job.id,
                        message: String(message.prefix(20_000)),
                        completedAt: Date()
                    )
                }
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        worker = nil
    }
}
