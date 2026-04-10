//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

public protocol JobRepositoryProtocol: Sendable {
    func save(_ job: Job) async throws
    func fetchDueJobs(_ date: Date) async throws -> [Job]
    func updateNextRun(jobId: String) async throws
    func deactivate(jobId: String) async throws
    
    func saveResult(jobId: String, data: String) async throws
    func latestResult(jobId: String) async throws -> String?
}
