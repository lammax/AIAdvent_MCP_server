//
// LLMGatewayService.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation

public protocol LLMGatewayUpstream: Sendable {
    func generate(_ request: LLMGatewayRequest) async throws -> LLMUpstreamResponse
}

public actor LLMGatewayService {
    private let upstream: any LLMGatewayUpstream
    private let auditLogger: any LLMGatewayAuditLogging
    private let rateLimiter: LLMRateLimiter
    private let costEstimator: LLMCostEstimator
    private let inputGuard = LLMInputGuard()
    private let outputGuard = LLMOutputGuard()

    public init(
        upstream: any LLMGatewayUpstream,
        auditLogger: any LLMGatewayAuditLogging,
        rateLimiter: LLMRateLimiter,
        costEstimator: LLMCostEstimator
    ) {
        self.upstream = upstream
        self.auditLogger = auditLogger
        self.rateLimiter = rateLimiter
        self.costEstimator = costEstimator
    }

    public func process(_ request: LLMGatewayRequest, clientId: String) async throws -> LLMGatewayResponse {
        let requestId = UUID()
        guard await rateLimiter.allow(clientId: clientId) else {
            let response = LLMGatewayResponse(
                requestId: requestId,
                status: .rateLimited,
                provider: request.provider,
                model: request.model,
                content: nil,
                warning: "Rate limit exceeded. Try again after the one-minute window.",
                findings: [],
                usage: nil
            )
            await audit(response, request: request, clientId: clientId, phase: "request", preview: "", status: "rate_limited")
            return response
        }

        var sanitizedMessages: [LLMGatewayMessage] = []
        var inputFindings: [LLMGuardFinding] = []
        for message in request.messages {
            let inspection = inputGuard.inspect(message.content)
            inputFindings.append(contentsOf: inspection.findings)
            sanitizedMessages.append(LLMGatewayMessage(role: message.role, content: inspection.sanitizedText))
        }

        let inputPreview = sanitizedMessages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        if !inputFindings.isEmpty && request.guardMode == .block {
            let response = LLMGatewayResponse(
                requestId: requestId,
                status: .blocked,
                provider: request.provider,
                model: request.model,
                content: nil,
                warning: "Input Guard blocked the request before any LLM call.",
                findings: inputFindings,
                usage: nil
            )
            await audit(response, request: request, clientId: clientId, phase: "input", preview: inputPreview, status: "blocked")
            return response
        }

        await auditLogger.record(LLMGatewayAuditEvent(
            requestId: requestId,
            phase: "input",
            clientId: clientId,
            provider: request.provider,
            model: request.model,
            status: inputFindings.isEmpty ? "accepted" : "masked",
            sanitizedPreview: inputPreview,
            findings: inputFindings
        ))

        let sanitizedRequest = LLMGatewayRequest(
            provider: request.provider,
            model: request.model,
            messages: sanitizedMessages,
            guardMode: request.guardMode,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        )

        do {
            let upstreamResponse = try await upstream.generate(sanitizedRequest)
            let usage = costEstimator.usage(
                model: request.model,
                promptTokens: upstreamResponse.promptTokens,
                completionTokens: upstreamResponse.completionTokens
            )
            let outputInspection = outputGuard.inspect(upstreamResponse.content)
            let findings = inputFindings + outputInspection.findings
            let response: LLMGatewayResponse
            if outputInspection.findings.isEmpty {
                response = LLMGatewayResponse(
                    requestId: requestId,
                    status: .completed,
                    provider: request.provider,
                    model: request.model,
                    content: upstreamResponse.content,
                    warning: inputFindings.isEmpty ? nil : "Input secrets were masked before the LLM call.",
                    findings: findings,
                    usage: usage
                )
            } else {
                response = LLMGatewayResponse(
                    requestId: requestId,
                    status: .blocked,
                    provider: request.provider,
                    model: request.model,
                    content: nil,
                    warning: "Output Guard blocked unsafe model output.",
                    findings: findings,
                    usage: usage
                )
            }

            await audit(
                response,
                request: request,
                clientId: clientId,
                phase: "output",
                preview: outputInspection.sanitizedText,
                status: response.status.rawValue
            )
            return response
        } catch {
            await auditLogger.record(LLMGatewayAuditEvent(
                requestId: requestId,
                phase: "upstream",
                clientId: clientId,
                provider: request.provider,
                model: request.model,
                status: "failed",
                sanitizedPreview: "Upstream request failed without retaining its response body.",
                findings: inputFindings
            ))
            throw error
        }
    }

    private func audit(
        _ response: LLMGatewayResponse,
        request: LLMGatewayRequest,
        clientId: String,
        phase: String,
        preview: String,
        status: String
    ) async {
        await auditLogger.record(LLMGatewayAuditEvent(
            requestId: response.requestId,
            phase: phase,
            clientId: clientId,
            provider: request.provider,
            model: request.model,
            status: status,
            sanitizedPreview: preview,
            findings: response.findings,
            usage: response.usage
        ))
    }
}
