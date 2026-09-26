import Foundation
import Testing
@testable import CodexTokenBar

struct LocalQuotaModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveLocalQuotaOnly() throws {
        let value = try SessionUsageReader().latestQuotaRecord()
        let record = try #require(value)
        #expect(record.quota.limits.isCodexQuota)
        print("LOCAL_QUOTA_READ_OK; no network or credentials used")
    }
    private func record(_ used: Double, at time: Double, source: String = "one") -> LocalQuotaRecord {
        LocalQuotaRecord(quota: QuotaSnapshot(timestamp: Date(timeIntervalSince1970: time),
            limits: SessionRateLimits(limitId: "codex", primary: RateLimitWindow(usedPercent: used,
                windowMinutes: 300, limitWindowSeconds: nil, resetsAt: 10_000, resetAt: nil),
                secondary: nil, planType: "pro")), sourceFile: URL(fileURLWithPath: "/\(source).jsonl"))
    }

    private func preferences() -> UserDefaults {
        UserDefaults(suiteName: "LocalQuotaTests." + UUID().uuidString)!
    }

    @Test @MainActor func newLocalRecordsConfirmOnceButRereadsDoNot() async {
        let box = LocalRecordBox(record(90, at: 100))
        let model = UsageModel(startAutomatically: false, readQuota: { try box.read() }, preferences: preferences())
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 100))
        box.set(record(0, at: 130))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 130))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 160))
        #expect(model.resetNotice == nil)
        box.set(record(1, at: 170))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 170))
        let id = model.resetNotice?.id
        #expect(id != nil)
        #expect(model.resetNotice?.message.contains("账号切换") == true)
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 180))
        #expect(model.resetNotice?.id == id)
        box.set(record(0, at: 200, source: "two"))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 200))
        #expect(model.resetNotice == nil)
    }

    @Test @MainActor func discardCutoffSurvivesRestartAndKeepsTokens() async {
        let box = LocalRecordBox(record(90, at: 100))
        let prefs = preferences()
        let model = UsageModel(startAutomatically: false, readLocal: {
            LocalUsageSnapshot(timestamp: Date(), sessionTotal: .zero, lastRequest: nil,
                contextWindow: nil, rateLimits: nil, sourceFile: URL(fileURLWithPath: "/tokens.jsonl"))
        }, readQuota: { try box.read() }, preferences: prefs)
        await model.refresh()
        #expect(model.statusValue == "0")
        model.discardOldQuota(now: Date(timeIntervalSince1970: 150))
        #expect(model.localQuota == nil)
        #expect(model.statusValue == "0")
        let restarted = UsageModel(startAutomatically: false, readQuota: { try box.read() }, preferences: prefs)
        await restarted.refreshLocalQuota(now: Date(timeIntervalSince1970: 160))
        #expect(restarted.localQuota == nil)
        box.set(record(1, at: 170))
        await restarted.refreshLocalQuota(now: Date(timeIntervalSince1970: 170))
        #expect(restarted.effectivePrimaryWindow?.usedPercent == 1)
        #expect(restarted.resetNotice == nil)
    }

    @Test @MainActor func staleHistoryAndReadErrorsDoNotNotify() async {
        let box = LocalRecordBox(record(90, at: 100))
        let model = UsageModel(startAutomatically: false, readQuota: { try box.read() }, preferences: preferences())
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 1_000))
        box.set(record(0, at: 130))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 1_030))
        box.set(record(1, at: 160))
        await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 1_060))
        #expect(model.resetNotice == nil)
        #expect(model.localQuota != nil) // explicitly labelled as history
        box.set(nil)
        await model.refreshLocalQuota()
        #expect(model.localQuota == nil)
        #expect(model.resetNotice == nil)
    }

    @Test func quotaOnlyReaderPreservesSourceAndSkipsSpark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quota.jsonl")
        let ordinary = #"{"timestamp":"2026-09-26T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":76}}}}"#
        let spark = ordinary.replacingOccurrences(of: "codex\"", with: "codex_bengalfox\"")
        try Data((ordinary + "\n" + spark).utf8).write(to: file)
        let record = try SessionUsageReader(sessionsRoot: root).latestQuotaRecord()
        let result = try #require(record)
        #expect(result.sourceFile.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(result.quota.limits.limitId == "codex")
        #expect(result.quota.limits.primary?.usedPercent == 76)
    }

    @Test @MainActor func clearingWhileReadingRejectsLateOldResult() async throws {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let old = record(90, at: 100)
        let model = UsageModel(startAutomatically: false, readQuota: {
            started.signal()
            guard finish.wait(timeout: .now() + 3) == .success else { throw CocoaError(.fileReadUnknown) }
            return old
        }, preferences: preferences())
        let reading = Task { await model.refreshLocalQuota(now: Date(timeIntervalSince1970: 100)) }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 3) == .success)
            }
        }
        model.discardOldQuota(now: Date(timeIntervalSince1970: 150))
        finish.signal()
        await reading.value
        #expect(didStart)
        #expect(model.localQuota == nil)
        #expect(model.resetNotice == nil)
        #expect(model.quotaMessage.contains("额度待确认"))
    }
}

private final class LocalRecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalQuotaRecord?
    init(_ value: LocalQuotaRecord?) { self.value = value }
    func set(_ value: LocalQuotaRecord?) { lock.withLock { self.value = value } }
    func read() throws -> LocalQuotaRecord? { lock.withLock { value } }
}
