//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

public struct PipelineResult: Codable, Sendable {
    
    public init(query: String, rawText: String, summary: String, filePath: String) {
        self.query = query
        self.rawText = rawText
        self.summary = summary
        self.filePath = filePath
    }
    
    public let query: String
    public let rawText: String
    public let summary: String
    public let filePath: String
}
