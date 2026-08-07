//
// LLMGatewayPolicy.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import Foundation

public struct LLMModelPrice: Equatable, Sendable {
    public let modelPrefix: String
    public let inputUSDPerMillionTokens: Decimal
    public let outputUSDPerMillionTokens: Decimal

    public init(modelPrefix: String, inputUSDPerMillionTokens: Decimal, outputUSDPerMillionTokens: Decimal) {
        self.modelPrefix = modelPrefix
        self.inputUSDPerMillionTokens = inputUSDPerMillionTokens
        self.outputUSDPerMillionTokens = outputUSDPerMillionTokens
    }
}

public struct LLMCostEstimator: Sendable {
    private let prices: [LLMModelPrice]
    private let fallback: LLMModelPrice

    public init(prices: [LLMModelPrice] = [], fallback: LLMModelPrice) {
        self.prices = prices
        self.fallback = fallback
    }

    public func usage(model: String, promptTokens: Int, completionTokens: Int) -> LLMGatewayUsage {
        let price = prices.first { model.hasPrefix($0.modelPrefix) } ?? fallback
        let inputCost = Decimal(promptTokens) * price.inputUSDPerMillionTokens / 1_000_000
        let outputCost = Decimal(completionTokens) * price.outputUSDPerMillionTokens / 1_000_000
        return LLMGatewayUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            estimatedCostUSD: inputCost + outputCost
        )
    }
}

public actor LLMRateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private var requestTimes: [String: [Date]] = [:]

    public init(limit: Int, window: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.window = window
    }

    public func allow(clientId: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-window)
        var recent = requestTimes[clientId, default: []].filter { $0 > cutoff }
        guard recent.count < limit else {
            requestTimes[clientId] = recent
            return false
        }
        recent.append(now)
        requestTimes[clientId] = recent
        return true
    }
}
