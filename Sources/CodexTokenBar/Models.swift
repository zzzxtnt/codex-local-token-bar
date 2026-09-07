import Foundation

struct TokenCounts: Codable, Hashable, Sendable {
    let inputTokens: UInt64?
    let cachedInputTokens: UInt64?
    let cacheWriteInputTokens: UInt64?
    let outputTokens: UInt64?
    let reasoningOutputTokens: UInt64?
    let totalTokens: UInt64?

    var hasValues: Bool {
        inputTokens != nil || cachedInputTokens != nil || outputTokens != nil || totalTokens != nil
    }

    /// Codex includes cached input in input_tokens, so cached tokens must not be added twice.
    var normalizedTotal: UInt64 {
        totalTokens ?? (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    /// Codex reports cached input as a subset of input_tokens.
    /// This matches CC Switch's cache-read / cacheable-input definition.
    var cacheHitRate: Double {
        guard let inputTokens, inputTokens > 0 else { return 0 }
        let cached = min(cachedInputTokens ?? 0, inputTokens)
        return Double(cached) / Double(inputTokens)
    }

    static let zero = TokenCounts(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )
}

struct RateLimitWindow: Codable, Hashable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let limitWindowSeconds: Int?
    let resetsAt: TimeInterval?
    let resetAt: TimeInterval?

    var resetDate: Date? {
        guard let value = resetsAt ?? resetAt else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    var durationSeconds: Int? {
        limitWindowSeconds ?? windowMinutes.map { $0 * 60 }
    }
}

struct SessionRateLimits: Codable, Hashable, Sendable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?

    var isCodexQuota: Bool {
        limitId == nil || limitId == "" || limitId == "codex"
    }
}

struct QuotaSnapshot: Sendable {
    let timestamp: Date
    let limits: SessionRateLimits
}

struct TokenEventInfo: Codable, Sendable {
    let totalTokenUsage: TokenCounts?
    let lastTokenUsage: TokenCounts?
    let modelContextWindow: UInt64?
    let model: String?
    let modelName: String?
}

struct TokenEventPayload: Codable, Sendable {
    let type: String?
    let info: TokenEventInfo?
    let rateLimits: SessionRateLimits?
    let model: String?
}

struct CodexLogEvent: Codable, Sendable {
    let timestamp: String?
    let type: String?
    let payload: TokenEventPayload?
}

struct LocalUsageSnapshot: Sendable {
    let timestamp: Date
    let todayTotal: TokenCounts
    let todayRequestCount: Int
    let scannedFileCount: Int
    let deferredFileCount: Int
    let sessionTotal: TokenCounts
    let lastRequest: TokenCounts?
    let contextWindow: UInt64?
    let rateLimits: SessionRateLimits?
    let sourceFile: URL
    let quotaTimestamp: Date?

    init(
        timestamp: Date,
        todayTotal: TokenCounts? = nil,
        todayRequestCount: Int = 0,
        scannedFileCount: Int = 0,
        deferredFileCount: Int = 0,
        sessionTotal: TokenCounts,
        lastRequest: TokenCounts?,
        contextWindow: UInt64?,
        rateLimits: SessionRateLimits?,
        sourceFile: URL,
        quotaTimestamp: Date? = nil
    ) {
        self.timestamp = timestamp
        self.todayTotal = todayTotal ?? sessionTotal
        self.todayRequestCount = todayRequestCount
        self.scannedFileCount = scannedFileCount
        self.deferredFileCount = deferredFileCount
        self.sessionTotal = sessionTotal
        self.lastRequest = lastRequest
        self.contextWindow = contextWindow
        self.rateLimits = rateLimits
        self.sourceFile = sourceFile
        self.quotaTimestamp = quotaTimestamp
    }
}

enum UsageError: LocalizedError {
    case sessionsNotFound
    case noTokenEvents

    var errorDescription: String? {
        switch self {
        case .sessionsNotFound: "未找到 ~/.codex/sessions"
        case .noTokenEvents: "尚未找到 Codex token 记录"
        }
    }
}

enum CodexJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
