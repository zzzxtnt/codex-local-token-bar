import Foundation
import Testing
@testable import CodexTokenBar

@MainActor
struct OutputSpeedTests {
    @Test func menuBarShowsAverageAfterTotalAndHidesSpeedOnReadFailure() async {
        let source = SpeedFixture()
        let model = UsageModel(startAutomatically: false, readLocal: { try source.read() }, readQuota: { nil })
        #expect(model.statusBarValue == "— · — tok/s")
        await model.refresh()
        #expect(model.statusBarValue == "42 · 3.0 tok/s")
        #expect(model.menuTitle.contains("近 5 分钟平均输出"))
        source.fail()
        await model.refresh()
        #expect(model.statusBarValue == "42 · — tok/s")
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
