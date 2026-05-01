import Foundation
import Vapor
import MCP
import Shared
internal import NIOFoundationCompat

// MARK: - MCP server factory

func makeFileOperationsMCPServer(projectRoot: URL?) async -> MCP.Server {
    let server = Server(
        name: "file-operations-mcp-server",
        version: "1.0.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        .init(
            tools: [
                Tool(
                    name: "project_list_files",
                    description: "List files in the configured local project repository. Paths are always relative to the project root.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("Optional case-insensitive filename/path substring.")
                            ]),
                            "extensions": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Optional file extensions without dots, for example swift or md.")
                            ]),
                            "max_results": .object([
                                "type": .string("integer"),
                                "description": .string("Maximum number of files to return. Defaults to 80.")
                            ]),
                            "project_root": .object([
                                "type": .string("string"),
                                "description": .string("Optional absolute or server-relative project root override. If omitted, the server uses --project-root or FILE_OPERATIONS_PROJECT_ROOT.")
                            ])
                        ])
                    ])
                ),
                Tool(
                    name: "project_search_files",
                    description: "Search text across files in the configured local project repository. Paths are always relative to the project root.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "query": .object([
                                "type": .string("string"),
                                "description": .string("Text or terms to search for.")
                            ]),
                            "extensions": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("Optional file extensions without dots, for example swift or md.")
                            ]),
                            "max_results": .object([
                                "type": .string("integer"),
                                "description": .string("Maximum number of line matches to return. Defaults to 40.")
                            ]),
                            "project_root": .object([
                                "type": .string("string"),
                                "description": .string("Optional absolute or server-relative project root override. If omitted, the server uses --project-root or FILE_OPERATIONS_PROJECT_ROOT.")
                            ])
                        ]),
                        "required": .array([.string("query")])
                    ])
                ),
                Tool(
                    name: "project_read_file",
                    description: "Read a UTF-8 text file from the configured local project repository by relative path.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Relative file path inside the configured project root.")
                            ]),
                            "max_characters": .object([
                                "type": .string("integer"),
                                "description": .string("Maximum characters to return. Defaults to 40000.")
                            ]),
                            "project_root": .object([
                                "type": .string("string"),
                                "description": .string("Optional absolute or server-relative project root override. If omitted, the server uses --project-root or FILE_OPERATIONS_PROJECT_ROOT.")
                            ])
                        ]),
                        "required": .array([.string("path")])
                    ])
                ),
                Tool(
                    name: "project_write_file",
                    description: "Create or replace a UTF-8 text file in the configured local project repository by relative path.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Relative file path inside the configured project root.")
                            ]),
                            "content": .object([
                                "type": .string("string"),
                                "description": .string("Complete UTF-8 file content to write.")
                            ]),
                            "overwrite": .object([
                                "type": .string("boolean"),
                                "description": .string("Allow replacing an existing file. Defaults to false.")
                            ]),
                            "project_root": .object([
                                "type": .string("string"),
                                "description": .string("Optional absolute or server-relative project root override. If omitted, the server uses --project-root or FILE_OPERATIONS_PROJECT_ROOT.")
                            ])
                        ]),
                        "required": .array([.string("path"), .string("content")])
                    ])
                ),
                Tool(
                    name: "project_delete_file",
                    description: "Delete a text file from the configured local project repository by relative path. Used to undo files created by project_write_file.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object([
                                "type": .string("string"),
                                "description": .string("Relative file path inside the configured project root.")
                            ]),
                            "project_root": .object([
                                "type": .string("string"),
                                "description": .string("Optional absolute or server-relative project root override. If omitted, the server uses --project-root or FILE_OPERATIONS_PROJECT_ROOT.")
                            ])
                        ]),
                        "required": .array([.string("path")])
                    ])
                )
            ]
        )
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard let activeProjectRoot = try projectRootOverride(
            from: params.arguments,
            fallback: projectRoot
        ) else {
            return .init(
                content: [.text(text: "Project root is not configured. Set FILE_OPERATIONS_PROJECT_ROOT or pass --project-root.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            switch params.name {
            case "project_list_files":
                let query = stringValue("query", from: params.arguments) ?? ""
                let extensions = stringArrayValue("extensions", from: params.arguments) ?? []
                let maxResults = intValue("max_results", from: params.arguments) ?? 80
                return try jsonToolResult(ProjectListFilesResult(
                    repository: activeProjectRoot.lastPathComponent,
                    files: listProjectFiles(
                        projectRoot: activeProjectRoot,
                        query: query,
                        extensions: extensions,
                        maxResults: maxResults
                    )
                ))

            case "project_search_files":
                let query = try requiredString("query", from: params.arguments)
                let extensions = stringArrayValue("extensions", from: params.arguments) ?? []
                let maxResults = intValue("max_results", from: params.arguments) ?? 40
                return try jsonToolResult(ProjectSearchFilesResult(
                    repository: activeProjectRoot.lastPathComponent,
                    query: query,
                    matches: searchProjectFiles(
                        projectRoot: activeProjectRoot,
                        query: query,
                        extensions: extensions,
                        maxResults: maxResults
                    )
                ))

            case "project_read_file":
                let path = try requiredString("path", from: params.arguments)
                let maxCharacters = intValue("max_characters", from: params.arguments) ?? 40_000
                return try jsonToolResult(readProjectFile(
                    path: path,
                    projectRoot: activeProjectRoot,
                    maxCharacters: maxCharacters
                ))

            case "project_write_file":
                let path = try requiredString("path", from: params.arguments)
                let content = try requiredRawString("content", from: params.arguments)
                let overwrite = boolValue("overwrite", from: params.arguments) ?? false
                return try jsonToolResult(writeProjectFile(
                    path: path,
                    content: content,
                    overwrite: overwrite,
                    projectRoot: activeProjectRoot
                ))

            case "project_delete_file":
                let path = try requiredString("path", from: params.arguments)
                return try jsonToolResult(deleteProjectFile(
                    path: path,
                    projectRoot: activeProjectRoot
                ))

            default:
                return .init(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    return server
}

// MARK: - Models

private struct ProjectListFilesResult: Encodable {
    let repository: String
    let files: [String]
}

private struct ProjectSearchFilesResult: Encodable {
    let repository: String
    let query: String
    let matches: [ProjectFileSearchMatch]
}

private struct ProjectFileSearchMatch: Encodable {
    let path: String
    let line: Int
    let preview: String
}

private struct ProjectReadFileResult: Encodable {
    let path: String
    let content: String
    let truncated: Bool
}

private struct ProjectWriteFileResult: Encodable {
    let path: String
    let action: String
    let bytesWritten: Int
}

private struct ProjectDeleteFileResult: Encodable {
    let path: String
    let deleted: Bool
}

// MARK: - File operations

private func listProjectFiles(
    projectRoot: URL,
    query: String,
    extensions: [String],
    maxResults: Int
) throws -> [String] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let allowedExtensions = normalizedExtensions(extensions)
    let limit = max(1, min(maxResults, 500))

    let files = try enumerableProjectFiles(projectRoot: projectRoot)
        .filter { path in
            if !normalizedQuery.isEmpty, !path.lowercased().contains(normalizedQuery) {
                return false
            }

            if !allowedExtensions.isEmpty {
                let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
                return allowedExtensions.contains(fileExtension)
            }

            return true
        }

    return Array(files.prefix(limit))
}

private func searchProjectFiles(
    projectRoot: URL,
    query: String,
    extensions: [String],
    maxResults: Int
) throws -> [ProjectFileSearchMatch] {
    let terms = searchTerms(from: query)
    guard !terms.isEmpty else {
        throw FileOperationsToolError.invalidParameter("query")
    }

    let allowedExtensions = normalizedExtensions(extensions)
    let limit = max(1, min(maxResults, 200))
    var matches: [ProjectFileSearchMatch] = []

    for path in try enumerableProjectFiles(projectRoot: projectRoot) {
        if !allowedExtensions.isEmpty {
            let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard allowedExtensions.contains(fileExtension) else { continue }
        }

        guard isTextReadableProjectPath(path) else { continue }

        let fileURL = try resolveProjectPath(path, projectRoot: projectRoot)
        guard fileSize(fileURL) <= 1_000_000 else { continue }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lowercasedLine = line.lowercased()
            guard terms.contains(where: { lowercasedLine.contains($0) }) else { continue }

            matches.append(ProjectFileSearchMatch(
                path: path,
                line: index + 1,
                preview: String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            ))

            if matches.count >= limit {
                return matches
            }
        }
    }

    return matches
}

private func readProjectFile(
    path: String,
    projectRoot: URL,
    maxCharacters: Int
) throws -> ProjectReadFileResult {
    let fileURL = try resolveProjectPath(path, projectRoot: projectRoot)
    guard isTextReadableProjectPath(path) else {
        throw FileOperationsToolError.unsupportedFileType(path)
    }

    guard fileSize(fileURL) <= 2_000_000 else {
        throw FileOperationsToolError.fileTooLarge(path)
    }

    let content = try String(contentsOf: fileURL, encoding: .utf8)
    let limit = max(1, min(maxCharacters, 120_000))
    guard content.count > limit else {
        return ProjectReadFileResult(path: path, content: content, truncated: false)
    }

    let endIndex = content.index(content.startIndex, offsetBy: limit)
    return ProjectReadFileResult(path: path, content: String(content[..<endIndex]), truncated: true)
}

private func writeProjectFile(
    path: String,
    content: String,
    overwrite: Bool,
    projectRoot: URL
) throws -> ProjectWriteFileResult {
    let fileURL = try resolveProjectPath(path, projectRoot: projectRoot)
    guard isWritableProjectPath(path) else {
        throw FileOperationsToolError.unsupportedFileType(path)
    }

    let fileManager = FileManager.default
    let exists = fileManager.fileExists(atPath: fileURL.path)
    if exists, !overwrite {
        throw FileOperationsToolError.fileAlreadyExists(path)
    }

    let parent = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)

    return ProjectWriteFileResult(
        path: path,
        action: exists ? "updated" : "created",
        bytesWritten: content.data(using: .utf8)?.count ?? 0
    )
}

private func deleteProjectFile(
    path: String,
    projectRoot: URL
) throws -> ProjectDeleteFileResult {
    let fileURL = try resolveProjectPath(path, projectRoot: projectRoot)
    guard isWritableProjectPath(path) else {
        throw FileOperationsToolError.unsupportedFileType(path)
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return ProjectDeleteFileResult(path: path, deleted: false)
    }

    try FileManager.default.removeItem(at: fileURL)
    return ProjectDeleteFileResult(path: path, deleted: true)
}

private func enumerableProjectFiles(projectRoot: URL) throws -> [String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: projectRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [String] = []
    for case let url as URL in enumerator {
        let relativePath = try relativeProjectPath(for: url, projectRoot: projectRoot)
        if shouldSkipProjectPath(relativePath) {
            enumerator.skipDescendants()
            continue
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values.isRegularFile == true {
            files.append(relativePath)
        }
    }

    return files.sorted()
}

private func resolveProjectPath(_ rawPath: String, projectRoot: URL) throws -> URL {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.hasPrefix("/") else {
        throw FileOperationsToolError.invalidPath(rawPath)
    }

    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty,
          !components.contains("."),
          !components.contains(".."),
          !components.contains(".git") else {
        throw FileOperationsToolError.invalidPath(path)
    }

    let url = components.reduce(projectRoot) { partial, component in
        partial.appendingPathComponent(component)
    }.standardizedFileURL

    guard try relativeProjectPath(for: url, projectRoot: projectRoot) == path else {
        throw FileOperationsToolError.invalidPath(path)
    }

    return url
}

private func relativeProjectPath(for url: URL, projectRoot: URL) throws -> String {
    let rootPath = projectRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path == rootPath || path.hasPrefix(rootPath + "/") else {
        throw FileOperationsToolError.invalidPath(url.lastPathComponent)
    }

    if path == rootPath {
        return ""
    }

    return String(path.dropFirst(rootPath.count + 1))
}

private func shouldSkipProjectPath(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    return components.contains(".git")
        || components.contains(".build")
        || components.contains("DerivedData")
        || components.contains("node_modules")
        || components.contains(".swiftpm")
}

private func isTextReadableProjectPath(_ path: String) -> Bool {
    isWritableProjectPath(path)
        || ["gitignore", "xcconfig", "entitlements"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

private func isWritableProjectPath(_ path: String) -> Bool {
    let allowedExtensions: Set<String> = [
        "swift", "md", "txt", "json", "yml", "yaml", "plist",
        "xml", "html", "css", "js", "ts", "tsx", "jsx", "sh"
    ]
    let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    return allowedExtensions.contains(fileExtension)
}

private func normalizedExtensions(_ extensions: [String]) -> Set<String> {
    Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty })
}

private func fileSize(_ url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? UInt64 ?? 0
}

private func searchTerms(from query: String) -> [String] {
    let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that",
        "где", "как", "что", "это", "или", "для", "найди", "найти", "все", "места"
    ]

    return query
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        .map(String.init)
        .filter { $0.count >= 2 && !stopWords.contains($0) }
}

// MARK: - Argument parsing

private func requiredString(_ key: String, from arguments: [String: Value]?) throws -> String {
    guard let value = stringValue(key, from: arguments), !value.isEmpty else {
        throw FileOperationsToolError.missingParameter(key)
    }

    return value
}

private func requiredRawString(_ key: String, from arguments: [String: Value]?) throws -> String {
    guard let value = arguments?[key]?.stringValue else {
        throw FileOperationsToolError.missingParameter(key)
    }

    return value
}

private func stringValue(_ key: String, from arguments: [String: Value]?) -> String? {
    arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func intValue(_ key: String, from arguments: [String: Value]?) -> Int? {
    if let int = arguments?[key]?.intValue {
        return int
    }

    if let double = arguments?[key]?.doubleValue {
        return Int(double)
    }

    if let string = arguments?[key]?.stringValue {
        return Int(string)
    }

    return nil
}

private func boolValue(_ key: String, from arguments: [String: Value]?) -> Bool? {
    if let bool = arguments?[key]?.boolValue {
        return bool
    }

    if let string = arguments?[key]?.stringValue?.lowercased() {
        switch string {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    return nil
}

private func stringArrayValue(_ key: String, from arguments: [String: Value]?) -> [String]? {
    arguments?[key]?.arrayValue?.compactMap { $0.stringValue }
}

private func projectRootOverride(
    from arguments: [String: Value]?,
    fallback: URL?
) throws -> URL? {
    guard let rawProjectRoot = stringValue("project_root", from: arguments) else {
        return fallback
    }

    guard let url = projectRootURL(from: rawProjectRoot),
          isDirectory(url) else {
        throw FileOperationsToolError.invalidParameter("project_root")
    }

    return url
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private func jsonToolResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let data = try JSONEncoder().encode(value)
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return .init(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: false
    )
}

private enum FileOperationsToolError: LocalizedError {
    case missingParameter(String)
    case invalidParameter(String)
    case invalidPath(String)
    case unsupportedFileType(String)
    case fileTooLarge(String)
    case fileAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "Missing parameter: \(name)"
        case .invalidParameter(let name):
            return "Invalid parameter: \(name)"
        case .invalidPath(let path):
            return "Invalid project-relative path: \(path)"
        case .unsupportedFileType(let path):
            return "Unsupported file type for project file operation: \(path)"
        case .fileTooLarge(let path):
            return "File is too large to read safely: \(path)"
        case .fileAlreadyExists(let path):
            return "File already exists. Set overwrite=true to replace it: \(path)"
        }
    }
}

// MARK: - Runtime configuration

private struct FileOperationsMCPRuntimeConfiguration {
    let projectRoot: URL?
    let vaporArguments: [String]
}

private func runtimeConfiguration(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> FileOperationsMCPRuntimeConfiguration {
    var projectRootArgument: String?
    var vaporArguments: [String] = []
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let argument = arguments[index]

        if argument == "--project-root" {
            let valueIndex = arguments.index(after: index)
            if valueIndex < arguments.endIndex {
                projectRootArgument = arguments[valueIndex]
                index = arguments.index(after: valueIndex)
            } else {
                index = valueIndex
            }
            continue
        }

        if argument.hasPrefix("--project-root=") {
            projectRootArgument = String(argument.dropFirst("--project-root=".count))
            index = arguments.index(after: index)
            continue
        }

        vaporArguments.append(argument)
        index = arguments.index(after: index)
    }

    let rawProjectRoot = projectRootArgument
        ?? environment["FILE_OPERATIONS_PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return FileOperationsMCPRuntimeConfiguration(
        projectRoot: rawProjectRoot.flatMap(projectRootURL(from:)),
        vaporArguments: vaporArguments
    )
}

private func projectRootURL(from rawPath: String) -> URL? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
        return nil
    }

    let url: URL
    if path.hasPrefix("/") {
        url = URL(fileURLWithPath: path)
    } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
    }

    return url.standardizedFileURL
}

// MARK: - Vapor <-> MCP bridge

@main
enum FileOperationsMCPServer {
    static func main() async throws {
        let configuration = runtimeConfiguration()
        var env = try Environment.detect(arguments: configuration.vaporArguments)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        defer {
            Task { try? await app.asyncShutdown() }
        }

        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 3005

        let mcpServer = await makeFileOperationsMCPServer(projectRoot: configuration.projectRoot)
        let transport = StatelessHTTPServerTransport()
        try await mcpServer.start(transport: transport)

        app.get("health") { _ in
            "OK"
        }

        app.on(.POST, "mcp") { req async throws -> Vapor.Response in
            let httpRequest = HTTPRequest(
                method: "POST",
                headers: mcpHeaders(from: req.headers),
                body: Data(buffer: req.body.data ?? ByteBuffer())
            )

            let httpResponse = await transport.handleRequest(httpRequest)
            return vaporResponse(from: httpResponse)
        }

        try await app.execute()
    }
}
