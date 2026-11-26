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

struct NamedRateLimitWindow: Codable, Hashable, Sendable, Identifiable {
    let label: String
    let window: RateLimitWindow

    var id: String { label }
}

struct SessionRateLimits: Codable, Hashable, Sendable {
    let limitId: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let planType: String?
    let additional: [NamedRateLimitWindow]?

    init(
        limitId: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        planType: String?,
        additional: [NamedRateLimitWindow]? = nil
    ) {
        self.limitId = limitId
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.additional = additional
    }

    var isCodexQuota: Bool {
        limitId == nil || limitId == "" || limitId == "codex"
    }

    var isAntigravityQuota: Bool {
        limitId == "antigravity"
    }

    var isTrackedQuota: Bool {
        isCodexQuota || isAntigravityQuota
    }
}

struct QuotaSnapshot: Sendable {
    let timestamp: Date
    let limits: SessionRateLimits
}

struct LocalQuotaRecord: Sendable {
    let quota: QuotaSnapshot
    let sourceFile: URL
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
    /// Output recorded in the last 60 seconds / 60; not decode throughput.
    let averageOutputTokensPerSecond: Double?
    let outputSpeedIsPartial: Bool

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
        quotaTimestamp: Date? = nil,
        averageOutputTokensPerSecond: Double? = nil,
        outputSpeedIsPartial: Bool = false
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
        self.averageOutputTokensPerSecond = averageOutputTokensPerSecond
        self.outputSpeedIsPartial = outputSpeedIsPartial
    }
}

enum UsageDataSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: "Codex Token"
        case .antigravity: "Antigravity Token"
        }
    }

    var supportsLocalQuota: Bool {
        true
    }

    var quotaRefreshInterval: TimeInterval {
        switch self {
        case .codex: 30
        case .antigravity: 300
        }
    }

    var speedSubtitle: String {
        "近 1 分钟均值"
    }
}

enum UsageError: LocalizedError {
    case sessionsNotFound
    case noTokenEvents
    case antigravitySessionsNotFound
    case noAntigravityTokenEvents
    case antigravityCLIMissing
    case antigravityQuotaUnavailable
    case antigravityQuotaTimedOut

    var errorDescription: String? {
        switch self {
        case .sessionsNotFound: "未找到 ~/.codex/sessions"
        case .noTokenEvents: "尚未找到 Codex token 记录"
        case .antigravitySessionsNotFound: "未找到 Antigravity 本地会话目录"
        case .noAntigravityTokenEvents: "尚未找到 Antigravity token 记录"
        case .antigravityCLIMissing: "未找到 agy 命令，无法读取 Antigravity 额度"
        case .antigravityQuotaUnavailable: "未能从 agy 获取额度，请确认已完成登录"
        case .antigravityQuotaTimedOut: "查询 agy 额度超时，请稍后重试"
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
