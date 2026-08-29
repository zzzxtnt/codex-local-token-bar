import Foundation
import Testing
@testable import CodexTokenBar

struct SessionUsageReaderTests {
    @Test func decodesLatestTokenEventAndDoesNotDoubleCountCache() throws {
        let earlier = """
        {"timestamp":"2026-08-29T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120},"model_context_window":258400}}}
        """
        let later = """
        {"timestamp":"2026-08-29T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":50,"total_tokens":350},"last_token_usage":{"input_tokens":200,"cached_input_tokens":160,"output_tokens":30,"total_tokens":230},"model_context_window":258400},"rate_limits":{"plan_type":"pro","primary":{"used_percent":12,"window_minutes":300,"resets_at":1788569023}}}}
        """
        let data = Data((earlier + "\n" + later + "\n").utf8)
        let source = URL(fileURLWithPath: "/tmp/test.jsonl")

        let snapshot = try #require(SessionUsageReader().decodeLatestTokenEvent(from: data, sourceFile: source))
        #expect(snapshot.sessionTotal.normalizedTotal == 350)
        #expect(snapshot.lastRequest?.normalizedTotal == 230)
        #expect(snapshot.lastRequest?.cachedInputTokens == 160)
        #expect(snapshot.rateLimits?.primary?.usedPercent == 12)
        #expect(snapshot.rateLimits?.primary?.durationSeconds == 18_000)
    }

    @Test func scansTemporaryCodexDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let dayDirectory = root
            .appendingPathComponent(String(format: "%04d", try #require(components.year)))
            .appendingPathComponent(String(format: "%02d", try #require(components.month)))
            .appendingPathComponent(String(format: "%02d", try #require(components.day)))
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = """
        {"timestamp":"2026-08-29T02:20:03.612Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":397215,"cached_input_tokens":327680,"output_tokens":2380,"reasoning_output_tokens":1213,"total_tokens":399595},"last_token_usage":{"input_tokens":63560,"cached_input_tokens":54016,"output_tokens":405,"reasoning_output_tokens":223,"total_tokens":63965},"model_context_window":258400}}}
        """
        try Data((fixture + "\n").utf8).write(to: dayDirectory.appendingPathComponent("rollout.jsonl"))

        let snapshot = try SessionUsageReader(sessionsRoot: root).latestSnapshot()
        #expect(snapshot.sessionTotal.normalizedTotal == 399_595)
        #expect(snapshot.lastRequest?.normalizedTotal == 63_965)
    }

    @Test func aggregatesLocalDayWithCCSwitchReplayAndDedupRules() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        let archived = temporaryRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let parentID = "11111111-1111-4111-8111-111111111111"
        let childID = "22222222-2222-4222-8222-222222222222"
        let otherID = "33333333-3333-4333-8333-333333333333"
        let parentEvents = [
            sessionMeta(id: parentID, timestamp: "2026-08-29T02:00:00Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastOutput: 10, timestamp: "2026-08-29T02:01:00Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastOutput: 10, timestamp: "2026-08-29T02:01:01Z"),
            tokenEvent(totalInput: 150, cached: 100, output: 15, lastInput: 50, lastOutput: 5, timestamp: "2026-08-29T02:02:00Z"),
        ]
        let childEvents = [
            sessionMeta(id: childID, parentID: parentID, timestamp: "2026-08-29T02:03:00Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastOutput: 10, timestamp: "2026-08-29T02:03:01Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastOutput: 10, timestamp: "2026-08-29T02:03:02Z"),
            tokenEvent(totalInput: 150, cached: 100, output: 15, lastInput: 50, lastOutput: 5, timestamp: "2026-08-29T02:03:03Z"),
            tokenEvent(totalInput: 190, cached: 125, output: 19, lastInput: 40, lastOutput: 4, timestamp: "2026-08-29T02:04:00Z"),
        ]
        let cumulativeOnlyEvents = [
            sessionMeta(id: otherID, timestamp: "2026-08-29T03:00:00Z"),
            tokenEvent(totalInput: 20, cached: 10, output: 2, timestamp: "2026-08-29T03:01:00Z"),
            tokenEvent(totalInput: 20, cached: 10, output: 2, timestamp: "2026-08-29T03:01:01Z"),
            tokenEvent(totalInput: 30, cached: 15, output: 3, timestamp: "2026-08-29T03:02:00Z"),
        ]

        try write(parentEvents, id: parentID, to: sessions)
        try write(parentEvents, id: parentID, to: archived)
        try write(childEvents, id: childID, to: sessions)
        try write(cumulativeOnlyEvents, id: otherID, to: sessions)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(CodexJSON.parseDate("2026-08-29T04:00:00Z"))
        let snapshot = try SessionUsageReader(
            sessionsRoot: sessions,
            archivedSessionsRoot: archived
        ).dailySnapshot(now: now, calendar: calendar)

        // 165 parent + 44 child live-only + 33 cumulative-only. Cached input is
        // informational and must not be added to the headline total.
        #expect(snapshot.todayTotal.normalizedTotal == 242)
        #expect(snapshot.todayTotal.inputTokens == 220)
        #expect(snapshot.todayTotal.outputTokens == 22)
        #expect(snapshot.todayRequestCount == 5)
        #expect(snapshot.scannedFileCount == 4)
        #expect(snapshot.deferredFileCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveCodexSnapshot() throws {
        let snapshot = try SessionUsageReader().dailySnapshot()
        #expect(snapshot.todayTotal.normalizedTotal > 0)
        print(
            "LIVE_SNAPSHOT today_total=\(snapshot.todayTotal.normalizedTotal) "
                + "requests=\(snapshot.todayRequestCount) "
                + "session_total=\(snapshot.sessionTotal.normalizedTotal) "
                + "last_request=\(snapshot.lastRequest?.normalizedTotal ?? 0) "
                + "file=\(snapshot.sourceFile.lastPathComponent)"
        )
    }


    private func sessionMeta(id: String, parentID: String? = nil, timestamp: String) -> String {
        let parent = parentID.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"\(parent)}}"
    }

    private func tokenEvent(
        totalInput: UInt64,
        cached: UInt64,
        output: UInt64,
        lastInput: UInt64? = nil,
        lastOutput: UInt64? = nil,
        timestamp: String
    ) -> String {
        let last: String
        if let lastInput, let lastOutput {
            last = ",\"last_token_usage\":{\"input_tokens\":\(lastInput),\"cached_input_tokens\":0,\"output_tokens\":\(lastOutput),\"total_tokens\":\(lastInput + lastOutput)}"
        } else {
            last = ""
        }
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(totalInput),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"total_tokens\":\(totalInput + output)}\(last)}}}"
    }

    private func write(_ lines: [String], id: String, to directory: URL) throws {
        let file = directory.appendingPathComponent("rollout-\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}
