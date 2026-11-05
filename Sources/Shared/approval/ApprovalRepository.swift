import Foundation

public protocol ApprovalRepository: Sendable {
    func create(_ approval: Approval) async throws
    func createOrFindResumable(_ approval: Approval, now: Date) async throws -> Approval
    func approval(id: UUID, now: Date) async throws -> Approval?
    func pendingApprovals(now: Date) async throws -> [Approval]
    func respond(id: UUID, answers: [ApprovalAnswer], now: Date) async throws -> Approval
    func cancel(id: UUID, now: Date) async throws
    func cancelPendingApprovals(taskID: UUID, now: Date) async throws
}
