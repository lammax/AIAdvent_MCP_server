//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

public actor JobScheduler {
    private let db: JobRepositoryProtocol
    private var isStarted = false

    public init(db: JobRepositoryProtocol) {
        self.db = db
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        Task {
            while true {
                do {
                    let dueJobs = try await db.fetchDueJobs(Date())

                    for job in dueJobs where job.type == "github_summary" {
                        try await db.saveResult(
                            jobId: job.id,
                            data: "Scheduled summary placeholder for job \(job.id)"
                        )
                        try await db.updateNextRun(jobId: job.id)
                    }
                } catch {
                    print("JobScheduler error: \(error.localizedDescription)")
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
