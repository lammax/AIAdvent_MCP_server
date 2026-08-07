//
// LLMGuard.swift
// MCPServer
//
// Created by Auto (Codex) on 08.08.2026.
//

import CryptoKit
import Foundation

public struct LLMGuardResult: Equatable, Sendable {
    public let sanitizedText: String
    public let findings: [LLMGuardFinding]

    public var isSafe: Bool { findings.isEmpty }

    public init(sanitizedText: String, findings: [LLMGuardFinding]) {
        self.sanitizedText = sanitizedText
        self.findings = findings
    }
}

public struct LLMInputGuard: Sendable {
    private let detector = LLMSecretDetector()

    public init() {}

    public func inspect(_ text: String) -> LLMGuardResult {
        detector.inspect(text)
    }
}

public struct LLMOutputGuard: Sendable {
    private let detector = LLMSecretDetector()

    public init() {}

    public func inspect(_ text: String) -> LLMGuardResult {
        var result = detector.inspect(text)
        let patterns: [(LLMGuardFindingKind, String, String)] = [
            (.systemPromptDisclosure, #"(?i)\b(?:system|developer)\s+(?:prompt|message|instructions?)\b|\bhidden\s+instructions?\b"#, "[BLOCKED_SYSTEM_PROMPT_DISCLOSURE]"),
            (.suspiciousURL, #"(?i)https?://(?:localhost|127\.0\.0\.1|(?:\d{1,3}\.){3}\d{1,3}|[^\s/]*(?:ngrok|bit\.ly|tinyurl|\.onion))[^\s]*"#, "[BLOCKED_SUSPICIOUS_URL]"),
            (.dangerousCommand, #"(?im)(?:^|\n)\s*(?:sudo\s+|rm\s+-rf\b|curl\s+[^\n]*\|\s*(?:sh|bash)\b|powershell\s+-enc\b|chmod\s+777\b)[^\n]*"#, "[BLOCKED_DANGEROUS_COMMAND]")
        ]

        for (kind, pattern, replacement) in patterns {
            result = applying(
                pattern: pattern,
                kind: kind,
                replacement: replacement,
                to: result
            )
        }
        return result
    }
}

private struct LLMSecretDetector: Sendable {
    private struct Pattern: Sendable {
        let kind: LLMGuardFindingKind
        let expression: String
        let replacement: String
        let requiresLuhn: Bool
    }

    private let patterns: [Pattern] = [
        Pattern(kind: .fragmentedAPIKey, expression: #"(?i)\bsk-\s*[\"']?\s*\+\s*[\"']?\s*(?:proj-)?[A-Za-z0-9_-]{4,}\b"#, replacement: "[REDACTED_API_KEY]", requiresLuhn: false),
        Pattern(kind: .openAIAPIKey, expression: #"\bsk-(?:proj-)?[A-Za-z0-9_-]{6,}\b"#, replacement: "[REDACTED_API_KEY]", requiresLuhn: false),
        Pattern(kind: .githubToken, expression: #"\bghp_[A-Za-z0-9]{8,}\b"#, replacement: "[REDACTED_GITHUB_TOKEN]", requiresLuhn: false),
        Pattern(kind: .awsAccessKey, expression: #"\bAKIA[0-9A-Z]{16}\b"#, replacement: "[REDACTED_AWS_KEY]", requiresLuhn: false),
        Pattern(kind: .emailAddress, expression: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, replacement: "[REDACTED_EMAIL]", requiresLuhn: false),
        Pattern(kind: .paymentCard, expression: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, replacement: "[REDACTED_CARD]", requiresLuhn: true),
        Pattern(kind: .phoneNumber, expression: #"(?<!\w)(?:\+?\d[\d ()-]{7,}\d)(?!\w)"#, replacement: "[REDACTED_PHONE]", requiresLuhn: false)
    ]

    func inspect(_ text: String, inspectBase64: Bool = true) -> LLMGuardResult {
        var sanitized = text
        var findings: [LLMGuardFinding] = []

        for pattern in patterns {
            let matches = regexMatches(pattern.expression, in: sanitized).reversed()
            for match in matches {
                guard let range = Range(match.range, in: sanitized) else { continue }
                let value = String(sanitized[range])
                if pattern.requiresLuhn && !passesLuhn(value) { continue }
                if pattern.kind == .phoneNumber && value.filter(\.isNumber).count > 15 { continue }
                findings.append(finding(kind: pattern.kind, value: value, replacement: pattern.replacement))
                sanitized.replaceSubrange(range, with: pattern.replacement)
            }
        }

        if inspectBase64 {
            let matches = regexMatches(#"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{16,}={0,2}(?![A-Za-z0-9+/=])"#, in: sanitized).reversed()
            for match in matches {
                guard let range = Range(match.range, in: sanitized) else { continue }
                let candidate = String(sanitized[range])
                guard let data = Data(base64Encoded: candidate),
                      let decoded = String(data: data, encoding: .utf8),
                      !inspect(decoded, inspectBase64: false).findings.isEmpty else { continue }
                let replacement = "[REDACTED_BASE64_SECRET]"
                findings.append(finding(kind: .base64EncodedSecret, value: candidate, replacement: replacement))
                sanitized.replaceSubrange(range, with: replacement)
            }
        }

        return LLMGuardResult(sanitizedText: sanitized, findings: findings.reversed())
    }

    private func regexMatches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func passesLuhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { partial, item in
            let (offset, digit) = item
            guard offset.isMultiple(of: 2) == false else { return partial + digit }
            let doubled = digit * 2
            return partial + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10)
    }
}

private func applying(
    pattern: String,
    kind: LLMGuardFindingKind,
    replacement: String,
    to result: LLMGuardResult
) -> LLMGuardResult {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
    var sanitized = result.sanitizedText
    var findings = result.findings
    for match in regex.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).reversed() {
        guard let range = Range(match.range, in: sanitized) else { continue }
        let value = String(sanitized[range])
        findings.append(finding(kind: kind, value: value, replacement: replacement))
        sanitized.replaceSubrange(range, with: replacement)
    }
    return LLMGuardResult(sanitizedText: sanitized, findings: findings)
}

private func finding(kind: LLMGuardFindingKind, value: String, replacement: String) -> LLMGuardFinding {
    let digest = SHA256.hash(data: Data(value.utf8))
    let fingerprint = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    return LLMGuardFinding(kind: kind, fingerprint: fingerprint, replacement: replacement)
}
