import Foundation
import Testing
@testable import CodexTokenBar

struct QuotaSelectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveCodexQuota() throws {
        let snapshot = try SessionUsageReader().latestSnapshot()
        let limits = try #require(snapshot.rateLimits)
        #expect(limits.isCodexQuota)
        print("LIVE_QUOTA bucket=\(limits.limitId ?? "legacy") primary=\(limits.primary?.usedPercent ?? -1) minutes=\(limits.primary?.windowMinutes ?? -1) timestamp=\(String(describing: snapshot.quotaTimestamp))")
    }

    private func event(_ time: String, bucket: String = "codex", used: Int, reset: Int = 1789352767) -> String {
        """
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"\(bucket)","primary":{"used_percent":\(used),"window_minutes":10080,"resets_at":\(reset)},"secondary":null}}}
        """
    }

    @Test func sparkDoesNotOverwriteCodexAndQuotaOnlyUpdatesAreRead() throws {
        let data = [
            event("2026-09-07T10:00:00Z", used: 16),
            event("2026-09-07T10:01:00Z", bucket: "codex_bengalfox", used: 0)
        ].joined(separator: "\n").data(using: .utf8)!
        let quota = try #require(SessionUsageReader().decodeLatestQuota(from: data))
        #expect(quota.limits.limitId == "codex")
        #expect(quota.limits.primary?.usedPercent == 16)
        #expect(quota.limits.secondary == nil)
    }

    @Test func missingCodexBucketDoesNotSubstituteSpark() {
        let data = Data(event("2026-09-07T10:00:00Z", bucket: "codex_bengalfox", used: 0).utf8)
        #expect(SessionUsageReader().decodeLatestQuota(from: data) == nil)
    }

    @Test func resumedOldSessionQuotaIsIndependentOfLatestTokenFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("2026/08/01")
        let recent = root.appendingPathComponent("2026/09/07")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try Data(event("2026-09-07T10:00:00Z", used: 16).utf8).write(to: old.appendingPathComponent("old.jsonl"))
        let tokens = """
        {"timestamp":"2026-09-07T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}},"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0}}}}
        """
        try Data(tokens.utf8).write(to: recent.appendingPathComponent("new.jsonl"))
        let result = try SessionUsageReader(sessionsRoot: root).latestSnapshot(now: #require(CodexJSON.parseDate("2026-09-07T11:00:00Z")))
        #expect(result.sessionTotal.normalizedTotal == 120)
        #expect(result.rateLimits?.primary?.usedPercent == 16)
        #expect(result.quotaTimestamp == CodexJSON.parseDate("2026-09-07T10:00:00Z"))
    }
}
