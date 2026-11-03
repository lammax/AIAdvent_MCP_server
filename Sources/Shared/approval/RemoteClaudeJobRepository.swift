import Foundation

public protocol RemoteClaudeJobRepository: Sendable {
    func createClaudeJob(_ job: RemoteClaudeJob) async throws
    func createWebJob(_ job: RemoteClaudeJob, remoteEnabled: Bool) async throws
    func conversationSessionIDs(agent: String, project: String) async throws -> [String]
    func deferBusyConversation(id: UUID, until: Date) async throws
    func claudeJob(id: UUID) async throws -> RemoteClaudeJob?
    func recentClaudeJobs(limit: Int) async throws -> [RemoteClaudeJob]
    func requeueInterruptedClaudeJobs() async throws
    func claimNextClaudeJob(startedAt: Date) async throws -> RemoteClaudeJob?
    func completeClaudeJob(
        id: UUID,
        result: RemoteClaudeJobResult,
        completedAt: Date
    ) async throws
    func failClaudeJob(id: UUID, message: String, completedAt: Date) async throws
}

public protocol RemoteClaudeJobRunning: Sendable {
    func run(job: RemoteClaudeJob) async throws -> RemoteClaudeJobResult
}
