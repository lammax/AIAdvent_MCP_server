// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [
            .macOS(.v14)
        ],
    products: [
        .executable(
            name: "GitHubMCPServer",
            targets: ["GitHubMCPServer"]
        ),
        .executable(
            name: "UtilityMCPServer",
            targets: ["UtilityMCPServer"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/groue/GRDB.swift", branch: "master")
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),

        .executableTarget(
            name: "GitHubMCPServer",
            dependencies: [
                "Shared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),

        .executableTarget(
            name: "UtilityMCPServer",
            dependencies: [
                "Shared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
