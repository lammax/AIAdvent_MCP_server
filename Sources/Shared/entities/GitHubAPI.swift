//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation

public struct GitHubAPI: Sendable {
    
    public init(token: String?) {
        self.token = token
    }
    
    public let token: String?

    public func fetchRepo(owner: String, repo: String) async throws -> GitHubRepo {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
            throw GitHubAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw GitHubAPIError.badStatus(http.statusCode, body)
        }

        return try JSONDecoder().decode(GitHubRepo.self, from: data)
    }
}
