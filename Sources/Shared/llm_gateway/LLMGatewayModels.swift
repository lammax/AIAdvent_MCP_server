//
// LLMGatewayModels.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation

public enum LLMGatewayProvider: String, Codable, Sendable {
    case openAI = "openai"
    case anthropic
}

public enum LLMGatewayGuardMode: String, Codable, Sendable {
    case block
    case mask
}

public enum LLMGatewayStatus: String, Codable, Sendable {
    case completed
    case blocked
    case rateLimited = "rate_limited"
}

public enum LLMGuardFindingKind: String, Codable, Sendable, CaseIterable {
    case openAIAPIKey = "openai_api_key"
    case githubToken = "github_token"
    case awsAccessKey = "aws_access_key"
    case emailAddress = "email_address"
    case paymentCard = "payment_card"
    case phoneNumber = "phone_number"
    case base64EncodedSecret = "base64_encoded_secret"
    case fragmentedAPIKey = "fragmented_api_key"
    case systemPromptDisclosure = "system_prompt_disclosure"
    case suspiciousURL = "suspicious_url"
    case dangerousCommand = "dangerous_command"
}

public struct LLMGuardFinding: Codable, Equatable, Sendable {
    public let kind: LLMGuardFindingKind
    public let fingerprint: String
    public let replacement: String

    public init(kind: LLMGuardFindingKind, fingerprint: String, replacement: String) {
        self.kind = kind
        self.fingerprint = fingerprint
        self.replacement = replacement
    }
}

public struct LLMGatewayMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LLMGatewayRequest: Codable, Equatable, Sendable {
    public let provider: LLMGatewayProvider
    public let model: String
    public let messages: [LLMGatewayMessage]
    public let guardMode: LLMGatewayGuardMode
    public let temperature: Double?
    public let maxTokens: Int?

    public init(
        provider: LLMGatewayProvider,
        model: String,
        messages: [LLMGatewayMessage],
        guardMode: LLMGatewayGuardMode = .block,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.provider = provider
        self.model = model
        self.messages = messages
        self.guardMode = guardMode
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, messages, temperature
        case guardMode = "guard_mode"
        case maxTokens = "max_tokens"
    }
}

public struct LLMGatewayUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal

    public init(promptTokens: Int, completionTokens: Int, estimatedCostUSD: Decimal = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case estimatedCostUSD = "estimated_cost_usd"
    }
}

public struct LLMGatewayResponse: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let status: LLMGatewayStatus
    public let provider: LLMGatewayProvider
    public let model: String
    public let content: String?
    public let warning: String?
    public let findings: [LLMGuardFinding]
    public let usage: LLMGatewayUsage?

    public init(
        requestId: UUID,
        status: LLMGatewayStatus,
        provider: LLMGatewayProvider,
        model: String,
        content: String?,
        warning: String?,
        findings: [LLMGuardFinding],
        usage: LLMGatewayUsage?
    ) {
        self.requestId = requestId
        self.status = status
        self.provider = provider
        self.model = model
        self.content = content
        self.warning = warning
        self.findings = findings
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case status, provider, model, content, warning, findings, usage
        case requestId = "request_id"
    }
}

public struct LLMUpstreamResponse: Equatable, Sendable {
    public let content: String
    public let promptTokens: Int
    public let completionTokens: Int

    public init(content: String, promptTokens: Int, completionTokens: Int) {
        self.content = content
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}
