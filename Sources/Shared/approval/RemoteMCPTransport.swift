import Foundation
import MCP
import Vapor

/// The current Swift SDK models experimental capabilities as [String: String],
/// while clients can send arbitrary JSON values. Remote uses none of those extensions.
public actor RemoteMCPTransport: Transport {
    public nonisolated let logger = Logger(label: "remote-mcp-transport")
    private let base: any Transport

    public init(base: any Transport) { self.base = base }
    public func connect() async throws { try await base.connect() }
    public func disconnect() async { await base.disconnect() }
    public func send(_ data: Data) async throws { try await base.send(data) }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.normalizeInitialize(data))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated static func normalizeInitialize(_ data: Data) -> Data {
        guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any]
        else { return data }
        capabilities["experimental"] = experimental.filter { $0.value is String }
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
