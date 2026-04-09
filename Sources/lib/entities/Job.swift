//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

struct Job: Codable {
    let id: String
    let type: String
    let payload: String
    let interval: TimeInterval
    var nextRunAt: Date
    var isActive: Bool
}

struct JobResult: Codable, Sendable {
    let id: String
    let jobId: String
    let createdAt: Date
    let data: String
}
