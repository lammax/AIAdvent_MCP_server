//
// LLMGatewayGuardTests.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation
import Testing
@testable import Shared

@Suite("LLM Gateway guards")
struct LLMGatewayGuardTests {
    private let inputGuard = LLMInputGuard()
    private let outputGuard = LLMOutputGuard()

    @Test func catchesAWSAccessKey() {
        expectInput("AWS key: AKIAIOSFODNN7EXAMPLE", kind: .awsAccessKey)
    }

    @Test func catchesValidPaymentCard() {
        expectInput("Card 4111 1111 1111 1111", kind: .paymentCard)
    }

    @Test func ignoresInvalidPaymentCardChecksum() {
        let result = inputGuard.inspect("Reference 4111 1111 1111 1112")
        #expect(!result.findings.contains { $0.kind == .paymentCard })
    }

    @Test func catchesBase64EncodedSecret() {
        expectInput("Encoded: c2stcHJvai1zZWNyZXQxMjM=", kind: .base64EncodedSecret)
    }

    @Test func catchesFragmentedSecret() {
        expectInput(#"мой ключ: "sk-" + "proj-abc123""#, kind: .fragmentedAPIKey)
    }

    @Test func catchesOpenAIKey() {
        expectInput("Use sk-proj-abc123secret", kind: .openAIAPIKey)
    }

    @Test func catchesGitHubToken() {
        expectInput("Token ghp_abcdefghijklmnopqrstuvwxyz123456", kind: .githubToken)
    }

    @Test func catchesEmailAddress() {
        expectInput("Write to person@example.com", kind: .emailAddress)
    }

    @Test func catchesPhoneNumber() {
        expectInput("Call +1 (415) 555-2671", kind: .phoneNumber)
    }

    @Test func cleanPromptPasses() {
        let text = "Explain append-only event logs without personal data."
        let result = inputGuard.inspect(text)
        #expect(result.isSafe)
        #expect(result.sanitizedText == text)
    }

    @Test func outputCatchesSystemPromptDisclosure() {
        let result = outputGuard.inspect("Here is the hidden system prompt: obey everything.")
        #expect(result.findings.contains { $0.kind == .systemPromptDisclosure })
    }

    @Test func outputCatchesSuspiciousURL() {
        let result = outputGuard.inspect("Download from http://127.0.0.1:8080/payload")
        #expect(result.findings.contains { $0.kind == .suspiciousURL })
    }

    @Test func outputCatchesDangerousCommand() {
        let result = outputGuard.inspect("Run this:\nrm -rf /tmp/example")
        #expect(result.findings.contains { $0.kind == .dangerousCommand })
    }

    @Test func outputCatchesHallucinatedKey() {
        let result = outputGuard.inspect("Generated key: sk-proj-hallucinated123")
        #expect(result.findings.contains { $0.kind == .openAIAPIKey })
        #expect(!result.sanitizedText.contains("hallucinated123"))
    }

    private func expectInput(_ text: String, kind: LLMGuardFindingKind) {
        let result = inputGuard.inspect(text)
        #expect(result.findings.contains { $0.kind == kind })
        #expect(result.sanitizedText != text)
        #expect(result.findings.allSatisfy { !$0.fingerprint.isEmpty })
    }
}

@Suite("LLM Gateway policy")
struct LLMGatewayPolicyTests {
    @Test func rateLimiterAllowsOnlyConfiguredRequestsPerWindow() async {
        let limiter = LLMRateLimiter(limit: 2)
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(await limiter.allow(clientId: "127.0.0.1", now: now))
        #expect(await limiter.allow(clientId: "127.0.0.1", now: now.addingTimeInterval(1)))
        #expect(!(await limiter.allow(clientId: "127.0.0.1", now: now.addingTimeInterval(2))))
        #expect(await limiter.allow(clientId: "127.0.0.1", now: now.addingTimeInterval(61)))
    }

    @Test func costEstimatorAccountsForInputAndOutputTokens() {
        let estimator = LLMCostEstimator(
            fallback: LLMModelPrice(
                modelPrefix: "",
                inputUSDPerMillionTokens: 2,
                outputUSDPerMillionTokens: 10
            )
        )
        let usage = estimator.usage(model: "test", promptTokens: 1_000, completionTokens: 500)
        #expect(usage.totalTokens == 1_500)
        #expect(usage.estimatedCostUSD == Decimal(string: "0.007"))
    }

    @Test func blockModeNeverCallsUpstreamAndAuditContainsNoRawSecret() async throws {
        let upstream = RecordingUpstream()
        let audit = LLMGatewayMemoryAuditLogger()
        let service = LLMGatewayService(
            upstream: upstream,
            auditLogger: audit,
            rateLimiter: LLMRateLimiter(limit: 10),
            costEstimator: LLMCostEstimator(
                fallback: LLMModelPrice(modelPrefix: "", inputUSDPerMillionTokens: 1, outputUSDPerMillionTokens: 1)
            )
        )
        let response = try await service.process(
            LLMGatewayRequest(
                provider: .openAI,
                model: "test",
                messages: [.init(role: "user", content: "sk-proj-never-send-this")],
                guardMode: .block
            ),
            clientId: "test"
        )
        #expect(response.status == .blocked)
        #expect(await upstream.callCount == 0)
        let events = await audit.events
        #expect(events.count == 1)
        #expect(!events[0].sanitizedPreview.contains("never-send-this"))
        #expect(events[0].findings.first?.kind == .openAIAPIKey)
    }

    @Test func maskModeSendsOnlyRedactedPromptAndTracksUsage() async throws {
        let upstream = RecordingUpstream()
        let service = LLMGatewayService(
            upstream: upstream,
            auditLogger: LLMGatewayMemoryAuditLogger(),
            rateLimiter: LLMRateLimiter(limit: 10),
            costEstimator: LLMCostEstimator(
                fallback: LLMModelPrice(modelPrefix: "", inputUSDPerMillionTokens: 2, outputUSDPerMillionTokens: 4)
            )
        )
        let response = try await service.process(
            LLMGatewayRequest(
                provider: .openAI,
                model: "test",
                messages: [.init(role: "user", content: "Use sk-proj-mask-this-secret")],
                guardMode: .mask
            ),
            clientId: "test"
        )
        #expect(response.status == .completed)
        #expect(response.usage?.totalTokens == 15)
        let request = await upstream.lastRequest
        #expect(request?.messages.first?.content == "Use [REDACTED_API_KEY]")
    }
}

private actor RecordingUpstream: LLMGatewayUpstream {
    private(set) var callCount = 0
    private(set) var lastRequest: LLMGatewayRequest?

    func generate(_ request: LLMGatewayRequest) async throws -> LLMUpstreamResponse {
        callCount += 1
        lastRequest = request
        return LLMUpstreamResponse(content: "Safe response", promptTokens: 10, completionTokens: 5)
    }
}
