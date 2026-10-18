import Foundation
import Testing
@testable import CodexTokenBar

@MainActor
struct OutputSpeedTests {
    @Test(arguments: [false, true])
    func manualRefreshDuringReadWaitsAndReadsFreshSpeedAndQuota(blockQuota: Bool) async throws {
        let source = BlockingRefreshFixture(blockQuota: blockQuota)
        defer { source.release.signal() }
        let suite = "OutputSpeedTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = UsageModel(startAutomatically: false, readLocal: { source.read() },
                               readQuota: { source.quota() }, preferences: preferences)
        let first = Task { await model.refresh() }
        for _ in 0..<200 where !source.started {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.started)
        #expect(model.isManuallyRefreshing)
        let second = Task { await model.refresh() }
        // Let the second call reach the in-flight read before releasing it.
        try await Task.sleep(for: .milliseconds(30))
        source.release.signal()
        await first.value
        await second.value
        #expect(source.readCount == 2)
        #expect(source.quotaCount >= 2)
        #expect(model.speedValue == "6.0 tok/s")
        #expect(model.effectivePrimaryWindow?.usedPercent == 2)
        #expect(!model.isManuallyRefreshing)
    }
    @Test func genuinelyIncompleteSpeedIsNotPresentedAsComplete() async {
        let model = UsageModel(startAutomatically: false, readLocal: {
            LocalUsageSnapshot(timestamp: Date(), sessionTotal: .zero,
                lastRequest: nil, contextWindow: nil, rateLimits: nil,
                sourceFile: URL(fileURLWithPath: "/fixture.jsonl"),
                averageOutputTokensPerSecond: 3.19, outputSpeedIsPartial: true)
        }, readQuota: { nil })
        await model.refresh()
        #expect(model.speedValue == "— tok/s")
    }
    @Test func menuBarShowsAverageAfterTotalAndHidesSpeedOnReadFailure() async {
        let source = SpeedFixture()
        let model = UsageModel(startAutomatically: false, readLocal: { try source.read() }, readQuota: { nil })
        #expect(model.statusBarValue == "— · — tok/s")
        await model.refresh()
        #expect(model.statusBarValue == "42 · 3.0 tok/s")
        #expect(model.speedHistory.samples.last?.rate == 3)
        #expect(model.menuTitle.contains("近 1 分钟平均输出"))
        source.fail()
        await model.refresh()
        #expect(model.statusBarValue == "42 · — tok/s")
        #expect(model.speedHistory.samples.last?.rate == nil)
        #expect(model.speedHistory.samples.count == 2)
    }
}

private final class BlockingRefreshFixture: @unchecked Sendable {
    private let lock = NSLock()
    let release = DispatchSemaphore(value: 0)
    private var reads = 0
    private var quotas = 0
    private let blockQuota: Bool
    init(blockQuota: Bool) { self.blockQuota = blockQuota }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var quotaCount: Int { lock.lock(); defer { lock.unlock() }; return quotas }
    var started: Bool { blockQuota ? quotaCount > 0 : readCount > 0 }
    func quota() -> LocalQuotaRecord? {
        lock.lock(); quotas += 1; let count = quotas; lock.unlock()
        if blockQuota && count == 1 { _ = release.wait(timeout: .now() + 5) }
        return LocalQuotaRecord(quota: QuotaSnapshot(timestamp: Date().addingTimeInterval(-60 + Double(count)),
            limits: SessionRateLimits(limitId: "codex",
                primary: RateLimitWindow(usedPercent: Double(count), windowMinutes: 300,
                    limitWindowSeconds: nil, resetsAt: nil, resetAt: nil),
                secondary: nil, planType: nil)), sourceFile: URL(fileURLWithPath: "/fixture.jsonl"))
    }
    func read() -> LocalUsageSnapshot {
        lock.lock(); reads += 1; let count = reads; lock.unlock()
        if !blockQuota && count == 1 { _ = release.wait(timeout: .now() + 5) }
        return LocalUsageSnapshot(timestamp: Date(), sessionTotal: .zero,
            lastRequest: nil, contextWindow: nil, rateLimits: nil,
            sourceFile: URL(fileURLWithPath: "/fixture.jsonl"),
            averageOutputTokensPerSecond: count == 1 ? 3 : 6)
    }
}

private final class SpeedFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func fail() { lock.lock(); defer { lock.unlock() }; failed = true }
    func read() throws -> LocalUsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        if failed { throw UsageError.noTokenEvents }
        return LocalUsageSnapshot(timestamp: Date(),
            sessionTotal: TokenCounts(inputTokens: 12, cachedInputTokens: 0,
                cacheWriteInputTokens: 0, outputTokens: 30, reasoningOutputTokens: nil, totalTokens: 42),
            lastRequest: nil, contextWindow: nil, rateLimits: nil,
            sourceFile: URL(fileURLWithPath: "/fixture.jsonl"), averageOutputTokensPerSecond: 3)
    }
}
