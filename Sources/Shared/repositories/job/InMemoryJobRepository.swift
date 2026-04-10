//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation

public actor InMemoryJobRepository: JobRepositoryProtocol {
    
    public init() {
        
    }
    
    private var jobs: [String: Job] = [:]
    private var results: [String: [JobResult]] = [:]

    public func save(_ job: Job) async throws {
        jobs[job.id] = job
    }

    public func fetchDueJobs(_ date: Date) async throws -> [Job] {
        jobs.values
            .filter { $0.isActive && $0.nextRunAt <= date }
            .sorted { $0.nextRunAt < $1.nextRunAt }
    }

    public func updateNextRun(jobId: String) async throws {
        guard var job = jobs[jobId] else { return }
        job.nextRunAt = Date().addingTimeInterval(job.interval)
        jobs[jobId] = job
    }

    public func deactivate(jobId: String) async throws {
        guard var job = jobs[jobId] else { return }
        job.isActive = false
        jobs[jobId] = job
    }

    public func saveResult(jobId: String, data: String) async throws {
        let result = JobResult(
            id: UUID().uuidString,
            jobId: jobId,
            createdAt: Date(),
            data: data
        )

        results[jobId, default: []].append(result)
    }

    public func latestResult(jobId: String) async throws -> String? {
        results[jobId]?
            .sorted { $0.createdAt < $1.createdAt }
            .last?
            .data
    }
}
