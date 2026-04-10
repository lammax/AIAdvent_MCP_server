//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation

public enum GitHubAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid GitHub URL."
        case .invalidResponse:
            return "Invalid GitHub response."
        case let .badStatus(code, body):
            return "GitHub API error \(code): \(body)"
        }
    }
}
