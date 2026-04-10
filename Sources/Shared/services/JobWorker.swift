//
//  File.swift
//  GitHubMCPServer
//
//  Created by Максим Ламанский on 9.04.26.
//

import Foundation

public enum JobWorker {
    
    static func run(_ job: Job) async throws -> String {
        switch job.type {
        case "github_summary":
            return try await runGitHubSummary(job)
        default:
            throw NSError(domain: "Job", code: -1)
        }
    }
    
    private static func runGitHubSummary(_ job: Job) async throws -> String {
        let payload = try JSONDecoder().decode([String: String].self, from: Data(job.payload.utf8))
        
        let owner = payload["owner"]!
        let repo = payload["repo"]!
        
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        return String(data: data, encoding: .utf8) ?? ""
    }
}
