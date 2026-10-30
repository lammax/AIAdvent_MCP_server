import Foundation

public protocol ApprovalRepository: Sendable {
    func create(_ approval: Approval) async throws
    func approval(id: UUID, now: Date) async throws -> Approval?
    func pendingApprovals(now: Date) async throws -> [Approval]
    func respond(id: UUID, response: String, now: Date) async throws -> Approval
    func cancel(id: UUID, now: Date) async throws
}
