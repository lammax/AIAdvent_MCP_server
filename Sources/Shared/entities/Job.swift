//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

public struct Job: Codable, Sendable {
    
    public init(id: String, type: String, payload: String, interval: TimeInterval, nextRunAt: Date, isActive: Bool) {
        self.id = id
        self.type = type
        self.payload = payload
        self.interval = interval
        self.nextRunAt = nextRunAt
        self.isActive = isActive
    }
    
    public let id: String
    public let type: String
    public let payload: String
    public let interval: TimeInterval
    public var nextRunAt: Date
    public var isActive: Bool
}

public struct JobResult: Codable, Sendable {
    
    public init(id: String, jobId: String, createdAt: Date, data: String) {
        self.id = id
        self.jobId = jobId
        self.createdAt = createdAt
        self.data = data
    }
    
    public let id: String
    public let jobId: String
    public let createdAt: Date
    public let data: String
}
