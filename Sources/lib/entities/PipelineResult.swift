//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

struct PipelineResult: Codable, Sendable {
    let query: String
    let rawText: String
    let summary: String
    let filePath: String
}
