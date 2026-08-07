//
// LLMGatewayAudit.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation

public struct LLMGatewayAuditEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let requestId: UUID
    public let phase: String
    public let clientId: String
    public let provider: LLMGatewayProvider
    public let model: String
    public let status: String
    public let sanitizedPreview: String
    public let findings: [LLMGuardFinding]
    public let usage: LLMGatewayUsage?

    public init(
        timestamp: Date = Date(),
        requestId: UUID,
        phase: String,
        clientId: String,
        provider: LLMGatewayProvider,
        model: String,
        status: String,
        sanitizedPreview: String,
        findings: [LLMGuardFinding],
        usage: LLMGatewayUsage? = nil
    ) {
        self.timestamp = timestamp
        self.requestId = requestId
        self.phase = phase
        self.clientId = clientId
        self.provider = provider
        self.model = model
        self.status = status
        self.sanitizedPreview = String(sanitizedPreview.prefix(512))
        self.findings = findings
        self.usage = usage
    }
}

public protocol LLMGatewayAuditLogging: Sendable {
    func record(_ event: LLMGatewayAuditEvent) async
}

public actor LLMGatewayJSONLAuditLogger: LLMGatewayAuditLogging {
    private let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    public func record(_ event: LLMGatewayAuditEvent) async {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}

public actor LLMGatewayMemoryAuditLogger: LLMGatewayAuditLogging {
    public private(set) var events: [LLMGatewayAuditEvent] = []

    public init() {}

    public func record(_ event: LLMGatewayAuditEvent) async {
        events.append(event)
    }
}
