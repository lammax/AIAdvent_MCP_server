//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation
import GRDB

public struct JobRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var type: String
    var payload: String
    var intervalSeconds: Double
    var nextRunAt: Double
    var isActive: Bool
}

public struct ResultRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var jobId: String
    var createdAt: Double
    var data: String
}
