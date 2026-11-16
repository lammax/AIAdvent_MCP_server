import Foundation

enum RemoteCodexMCPConfiguration {
    static func overrides(serverPath: String?, databasePath: String?) -> [String] {
        guard let serverPath, !serverPath.isEmpty else { return [] }

        var values = [
            "mcp_servers.remote.command=\(tomlString(serverPath))",
            "mcp_servers.remote.args=[\"--stdio\"]",
        ]
        if let databasePath, !databasePath.isEmpty {
            values.append("mcp_servers.remote.env.REMOTE_DB_PATH=\(tomlString(databasePath))")
        }
        return values.flatMap { ["-c", $0] }
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
