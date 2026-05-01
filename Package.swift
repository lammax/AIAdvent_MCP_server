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
        ),
        .executable(
            name: "RAGMCPServer",
            targets: ["RAGMCPServer"]
        ),
        .executable(
            name: "SupportMCPServer",
            targets: ["SupportMCPServer"]
        ),
        .executable(
            name: "FileOperationsMCPServer",
            targets: ["FileOperationsMCPServer"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/groue/GRDB.swift", branch: "master"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
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
        ),

        .executableTarget(
            name: "RAGMCPServer",
            dependencies: [
                "Shared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),

        .executableTarget(
            name: "SupportMCPServer",
            dependencies: [
                "Shared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),

        .executableTarget(
            name: "FileOperationsMCPServer",
            dependencies: [
                "Shared",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
