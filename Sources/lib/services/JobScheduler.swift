//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

actor JobScheduler {
    
    private let db: JobRepositoryProtocol
    private var isRunning = false
    
    init(db: JobRepositoryProtocol) {
        self.db = db
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        Task {
            await self.loop()
        }
    }
    
    private func loop() async {
        while isRunning {
            do {
                let jobs = try await db.fetchDueJobs(Date())
                
                for job in jobs {
                    await execute(job)
                }
                
                try await Task.sleep(nanoseconds: 5_000_000_000) // каждые 5 сек
            } catch {
                print("Scheduler error: \(error)")
            }
        }
    }
    
    private func execute(_ job: Job) async {
        print("Running job \(job.id)")
        
        do {
            let result = try await JobWorker.run(job)
            
            try await db.saveResult(jobId: job.id, data: result)
            
            try await db.updateNextRun(jobId: job.id)
        } catch {
            print("Job failed: \(error)")
        }
    }
}
