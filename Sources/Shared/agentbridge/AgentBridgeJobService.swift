import Foundation

/// EnergyBot's own job scheduler. Deliberately a separate actor from
/// `RemoteClaudeJobService` (not a shared/modified copy of it): it runs one long-lived
/// worker per independently-schedulable scope (`RemoteClaudeJobScope`), so unrelated
/// agent/project/session combinations run concurrently instead of queuing behind a
/// single global worker. The existing `RemoteClaudeJobService` (used by the original
/// Remote approval system) is untouched and keeps its single-worker behavior.
public actor AgentBridgeJobService {
    public static let maximumPromptLength = RemoteClaudeJobService.maximumPromptLength

    private let repository: any AgentBridgeJobRepository
    private let runner: any RemoteClaudeJobRunning
    private let workingDirectory: String
    /// A worker never exits once started: idle scopes just poll at low frequency,
    /// which keeps this map race-free (no stop/restart dance around a shrinking set
    /// of keys racing a concurrent submit for that same key).
    private var activeWorkers: [RemoteClaudeJobScope: Task<Void, Never>] = [:]
    private var activeRuns: [UUID: Task<RemoteClaudeJobResult, Error>] = [:]

    public init(
        repository: any AgentBridgeJobRepository,
        runner: any RemoteClaudeJobRunning,
        workingDirectory: String
    ) {
        self.repository = repository
        self.runner = runner
        self.workingDirectory = workingDirectory
    }

    public func start() async throws {
        try await repository.requeueInterruptedClaudeJobs()
        for scope in try await repository.distinctQueuedJobScopes() {
            startWorkerIfNeeded(for: scope)
        }
    }

    public func submit(prompt: String, now: Date = Date(), agent: String = "claude", project: String? = nil, fromWeb: Bool = false, sessionID: String? = nil, idempotencyKey: String? = nil, forceRotation: Bool = false, automaticRotation: Bool = true, rotationOnly: Bool = false) async throws -> RemoteClaudeJob {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { throw RemoteClaudeJobError.emptyPrompt }
        guard normalizedPrompt.count <= Self.maximumPromptLength else {
            throw RemoteClaudeJobError.promptTooLong
        }
        let normalizedIdempotencyKey = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedIdempotencyKey, !normalizedIdempotencyKey.isEmpty,
           let existing = try await repository.claudeJob(agent: agent, idempotencyKey: normalizedIdempotencyKey) {
            return existing
        }

        let job = RemoteClaudeJob(
            id: UUID(),
            prompt: normalizedPrompt,
            workingDirectory: project ?? workingDirectory,
            status: .queued,
            sessionID: sessionID,
            createdAt: now,
            agent: agent,
            idempotencyKey: normalizedIdempotencyKey?.isEmpty == false ? normalizedIdempotencyKey : nil,
            forceRotation: forceRotation,
            automaticRotation: automaticRotation,
            rotationOnly: rotationOnly
        )
        if fromWeb {
            try await repository.createWebJob(job, remoteEnabled: RemoteModePolicy.enabled(channel: .web, prompt: normalizedPrompt))
        } else {
            try await repository.createClaudeJob(job)
        }
        startWorkerIfNeeded(for: RemoteClaudeJobScope(job: job))
        return job
    }

    public func recentJobs(limit: Int = 20) async throws -> [RemoteClaudeJob] {
        try await repository.recentClaudeJobs(limit: max(1, min(limit, 100)))
    }

    public func job(id: UUID) async throws -> RemoteClaudeJob? {
        try await repository.claudeJob(id: id)
    }

    public func clearFinishedHistory(agent: String, now: Date = Date()) async throws -> Int {
        try await repository.hideFinishedClaudeJobs(agent: agent, at: now)
    }

    public func cancel(id: UUID, now: Date = Date()) async throws -> RemoteClaudeJob {
        let job = try await repository.requestClaudeJobCancellation(id: id, at: now)
        activeRuns[id]?.cancel()
        return job
    }

    private func startWorkerIfNeeded(for scope: RemoteClaudeJobScope) {
        guard activeWorkers[scope] == nil else { return }
        activeWorkers[scope] = Task { await runQueue(for: scope) }
    }

    private func runQueue(for scope: RemoteClaudeJobScope) async {
        while !Task.isCancelled {
            do {
                guard let job = try await repository.claimNextClaudeJob(startedAt: Date(), scopedTo: scope) else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                do {
                    let runner = self.runner
                    let run = Task { @concurrent in try await runner.run(job: job) }
                    activeRuns[job.id] = run
                    defer { activeRuns[job.id] = nil }
                    let result = try await run.value
                    try await repository.completeClaudeJob(
                        id: job.id,
                        result: result,
                        completedAt: Date()
                    )
                } catch is CancellationError {
                    try await repository.cancelClaudeJob(id: job.id, at: Date())
                } catch RemoteConversationError.busy {
                    try await repository.deferBusyConversation(id: job.id, until: Date().addingTimeInterval(5))
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
        activeWorkers[scope] = nil
    }
}
