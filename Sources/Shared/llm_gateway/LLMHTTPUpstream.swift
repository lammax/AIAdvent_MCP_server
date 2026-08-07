//
// LLMHTTPUpstream.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation

public struct LLMHTTPUpstreamConfiguration: Sendable {
    public let openAIBaseURL: URL
    public let openAIAPIKey: String?
    public let anthropicBaseURL: URL
    public let anthropicAPIKey: String?
    public let anthropicVersion: String

    public init(
        openAIBaseURL: URL,
        openAIAPIKey: String?,
        anthropicBaseURL: URL,
        anthropicAPIKey: String?,
        anthropicVersion: String = "2023-06-01"
    ) {
        self.openAIBaseURL = openAIBaseURL
        self.openAIAPIKey = openAIAPIKey
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicAPIKey = anthropicAPIKey
        self.anthropicVersion = anthropicVersion
    }
}

public enum LLMHTTPUpstreamError: LocalizedError, Equatable {
    case missingAPIKey(LLMGatewayProvider)
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "Missing API key for \(provider.rawValue)."
        case .invalidResponse:
            "The upstream LLM returned an invalid response."
        case .httpStatus(let status):
            "The upstream LLM request failed with HTTP \(status)."
        case .emptyResponse:
            "The upstream LLM returned no text content."
        }
    }
}

public struct LLMHTTPUpstream: LLMGatewayUpstream {
    private let configuration: LLMHTTPUpstreamConfiguration
    private let session: URLSession

    public init(configuration: LLMHTTPUpstreamConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func generate(_ request: LLMGatewayRequest) async throws -> LLMUpstreamResponse {
        switch request.provider {
        case .openAI:
            try await generateOpenAI(request)
        case .anthropic:
            try await generateAnthropic(request)
        }
    }

    private func generateOpenAI(_ request: LLMGatewayRequest) async throws -> LLMUpstreamResponse {
        guard let apiKey = configuration.openAIAPIKey, !apiKey.isEmpty else {
            throw LLMHTTPUpstreamError.missingAPIKey(.openAI)
        }
        let payload = OpenAIRequest(
            model: request.model,
            messages: request.messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        )
        var urlRequest = URLRequest(url: configuration.openAIBaseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data = try await execute(urlRequest)
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = response.choices.first?.message.content else {
            throw LLMHTTPUpstreamError.emptyResponse
        }
        return LLMUpstreamResponse(
            content: content,
            promptTokens: response.usage?.promptTokens ?? 0,
            completionTokens: response.usage?.completionTokens ?? 0
        )
    }

    private func generateAnthropic(_ request: LLMGatewayRequest) async throws -> LLMUpstreamResponse {
        guard let apiKey = configuration.anthropicAPIKey, !apiKey.isEmpty else {
            throw LLMHTTPUpstreamError.missingAPIKey(.anthropic)
        }
        let system = request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let messages = request.messages
            .filter { $0.role != "system" }
            .map { LLMGatewayMessage(role: $0.role == "assistant" ? "assistant" : "user", content: $0.content) }
        let payload = AnthropicRequest(
            model: request.model,
            system: system.isEmpty ? nil : system,
            messages: messages,
            temperature: request.temperature,
            maxTokens: request.maxTokens ?? 1_024
        )
        var urlRequest = URLRequest(url: configuration.anthropicBaseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data = try await execute(urlRequest)
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = response.content.filter { $0.type == "text" }.map(\.text).joined()
        guard !content.isEmpty else { throw LLMHTTPUpstreamError.emptyResponse }
        return LLMUpstreamResponse(
            content: content,
            promptTokens: response.usage.inputTokens,
            completionTokens: response.usage.outputTokens
        )
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMHTTPUpstreamError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LLMHTTPUpstreamError.httpStatus(httpResponse.statusCode)
        }
        return data
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [LLMGatewayMessage]
    let temperature: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        let message: LLMGatewayMessage
    }
    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

private struct AnthropicRequest: Encodable {
    let model: String
    let system: String?
    let messages: [LLMGatewayMessage]
    let temperature: Double?
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String
    }
    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
    let content: [Content]
    let usage: Usage
}
