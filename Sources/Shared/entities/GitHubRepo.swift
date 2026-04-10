//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation

public struct GitHubRepo: Codable {
    public let full_name: String
    public let description: String?
    public let stargazers_count: Int
    public let forks_count: Int
    public let open_issues_count: Int
    public let default_branch: String
    public let language: String?
    public let html_url: String
}
