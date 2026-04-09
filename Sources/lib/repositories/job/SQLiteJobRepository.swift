//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation
import GRDB

final class SQLiteJobRepository: JobRepositoryProtocol {
    
    private let dbQueue: DatabaseQueue
    
    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }
    
    // MARK: - Migration
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("createJobs") { db in
            try db.create(table: "jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("intervalSeconds", .double).notNull()
                t.column("nextRunAt", .double).notNull()
                t.column("isActive", .boolean).notNull()
            }
        }
        
        migrator.registerMigration("createResults") { db in
            try db.create(table: "results") { t in
                t.column("id", .text).primaryKey()
                t.column("jobId", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("data", .text).notNull()
            }
        }
        
        return migrator
    }
    
    // MARK: - Jobs
    
    func save(_ job: Job) async throws {
        try await dbQueue.write { db in
            let record = JobRecord(
                id: job.id,
                type: job.type,
                payload: job.payload,
                intervalSeconds: job.interval,
                nextRunAt: job.nextRunAt.timeIntervalSince1970,
                isActive: job.isActive
            )
            
            try record.insert(db)
        }
    }
    
    func fetchDueJobs(_ date: Date) async throws -> [Job] {
        try await dbQueue.read { db in
            let records = try JobRecord
                .filter(Column("isActive") == true)
                .filter(Column("nextRunAt") <= date.timeIntervalSince1970)
                .fetchAll(db)
            
            return records.map {
                Job(
                    id: $0.id,
                    type: $0.type,
                    payload: $0.payload,
                    interval: $0.intervalSeconds,
                    nextRunAt: Date(timeIntervalSince1970: $0.nextRunAt),
                    isActive: $0.isActive
                )
            }
        }
    }
    
    func updateNextRun(jobId: String) async throws {
        try await dbQueue.write { db in
            guard var record = try JobRecord.fetchOne(db, key: jobId) else { return }
            
            let next = Date().addingTimeInterval(record.intervalSeconds)
            record.nextRunAt = next.timeIntervalSince1970
            
            try record.update(db)
        }
    }
    
    func deactivate(jobId: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE jobs SET isActive = 0 WHERE id = ?",
                arguments: [jobId]
            )
        }
    }
    
    // MARK: - Results
    
    func saveResult(jobId: String, data: String) async throws {
        try await dbQueue.write { db in
            let record = ResultRecord(
                id: UUID().uuidString,
                jobId: jobId,
                createdAt: Date().timeIntervalSince1970,
                data: data
            )
            
            try record.insert(db)
        }
    }
    
    func latestResult(jobId: String) async throws -> String? {
        try await dbQueue.read { db in
            let record = try ResultRecord
                .filter(Column("jobId") == jobId)
                .order(Column("createdAt").desc)
                .fetchOne(db)
            
            return record?.data
        }
    }
}
