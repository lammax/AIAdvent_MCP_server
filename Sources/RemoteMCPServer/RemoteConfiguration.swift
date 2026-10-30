import Foundation
import Shared

struct RemoteServiceConfiguration: Sendable {
    let databasePath: String
    let timeout: TimeInterval

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let timeout: TimeInterval
        if let rawTimeout = environment["REMOTE_TIMEOUT_SECONDS"] {
            guard let value = Double(rawTimeout), (1...3_600).contains(value) else {
                throw ConfigurationError.invalidValue("REMOTE_TIMEOUT_SECONDS")
            }
            timeout = value
        } else {
            timeout = ApprovalService.defaultTimeout
        }

        return Self(
            databasePath: environment["REMOTE_DB_PATH"]
                ?? SQLiteApprovalRepository.defaultDatabasePath(),
            timeout: timeout
        )
    }
}

struct RemoteConfiguration: Sendable {
    let host: String
    let port: Int
    let token: String
    let databasePath: String
    let timeout: TimeInterval
    let claudeExecutablePath: String
    let claudeWorkingDirectory: String

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let service = try RemoteServiceConfiguration.load(environment: environment)
        let host = environment["REMOTE_HOST"] ?? "127.0.0.1"
        guard isAllowedHost(host) else {
            throw ConfigurationError.disallowedHost
        }

        let port = try integer(
            environment["REMOTE_PORT"],
            default: 3010,
            name: "REMOTE_PORT",
            range: 1...65_535
        )
        let token: String
        if let inlineToken = environment["REMOTE_TOKEN"] {
            token = inlineToken
        } else if let tokenPath = environment["REMOTE_TOKEN_FILE"] {
            do {
                token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw ConfigurationError.invalidValue("REMOTE_TOKEN_FILE")
            }
        } else {
            throw ConfigurationError.missingOrWeakToken
        }
        guard token.count >= 32 else {
            throw ConfigurationError.missingOrWeakToken
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeExecutablePath = NSString(
            string: environment["REMOTE_CLAUDE_PATH"]
                ?? home.appendingPathComponent(".local/bin/claude").path
        ).expandingTildeInPath
        let claudeWorkingDirectory = NSString(
            string: environment["REMOTE_CLAUDE_WORKING_DIRECTORY"]
                ?? home.appendingPathComponent("Documents/ThisIsMy/Programming/AI").path
        ).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: claudeExecutablePath) else {
            throw ConfigurationError.invalidValue("REMOTE_CLAUDE_PATH")
        }
        guard FileManager.default.fileExists(
            atPath: claudeWorkingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ConfigurationError.invalidValue("REMOTE_CLAUDE_WORKING_DIRECTORY")
        }
        return Self(
            host: host,
            port: port,
            token: token,
            databasePath: service.databasePath,
            timeout: service.timeout,
            claudeExecutablePath: claudeExecutablePath,
            claudeWorkingDirectory: claudeWorkingDirectory
        )
    }

    private static func integer(
        _ rawValue: String?,
        default defaultValue: Int,
        name: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let rawValue else { return defaultValue }
        guard let value = Int(rawValue), range.contains(value) else {
            throw ConfigurationError.invalidValue(name)
        }
        return value
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return true
        }
        if host.lowercased().hasPrefix("fd7a:115c:a1e0:") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) })
        else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

private enum ConfigurationError: LocalizedError {
    case disallowedHost
    case missingOrWeakToken
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .disallowedHost:
            "REMOTE_HOST must be a loopback or Tailscale address."
        case .missingOrWeakToken:
            "REMOTE_TOKEN or REMOTE_TOKEN_FILE is required and must provide at least 32 characters."
        case .invalidValue(let name):
            "\(name) has an invalid value."
        }
    }
}
