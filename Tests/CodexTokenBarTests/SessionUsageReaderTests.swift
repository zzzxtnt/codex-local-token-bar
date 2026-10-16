import Foundation
import Testing
@testable import CodexTokenBar

struct SessionUsageReaderTests {
    @Test func appendedFileIdentifierKeepsSessionAndMergesContinuation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        let suffix = "22222222-2222-4222-8222-222222222222"
        let now = try #require(CodexJSON.parseDate("2026-10-16T00:05:00Z"))
        let meta = sessionMeta(id: id, timestamp: "2026-10-16T00:00:00Z")
        let first = tokenEvent(totalInput: 100, cached: 0, output: 300, timestamp: "2026-10-16T00:01:00Z")
        let second = tokenEvent(totalInput: 200, cached: 0, output: 600, timestamp: "2026-10-16T00:04:00Z")
        try write([meta, first], id: id, to: root)
        try write([meta, second], id: "\(id)_\(suffix)", to: root)
        let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
        #expect(value.deferredFileCount == 0)
        #expect(!value.outputSpeedIsPartial)
        #expect(value.averageOutputTokensPerSecond == 2)
        #expect(value.todayTotal.outputTokens == 600)
        #expect(value.todayRequestCount == 2)
        // A copied prefix must not double count; nor may repeated per-file
        // event indexes discard the continuation's first new request.
        try write([meta, first, second], id: "\(id)_\(suffix)", to: root)
        let copied = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
        #expect(copied.averageOutputTokensPerSecond == 2)
        #expect(copied.todayRequestCount == 2)
    }
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
        #expect(snapshot.lastRequest?.cacheHitRate == 0.8)
        #expect(snapshot.rateLimits?.primary?.usedPercent == 12)
        #expect(snapshot.rateLimits?.primary?.durationSeconds == 18_000)
    }

    @Test func continuationUsesOlderBaselineAndResolvesForkParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = "11111111-1111-4111-8111-111111111111"
        let suffix = "22222222-2222-4222-8222-222222222222"
        let child = "33333333-3333-4333-8333-333333333333"
        let meta = sessionMeta(id: parent, timestamp: "2026-10-15T10:00:00Z")
        try write([meta, tokenEvent(totalInput: 100, cached: 0, output: 300,
                                   timestamp: "2026-10-15T10:00:01Z")], id: parent, to: root)
        try FileManager.default.setAttributes([.modificationDate: try #require(CodexJSON.parseDate("2026-10-15T10:01:00Z"))],
            ofItemAtPath: root.appendingPathComponent("rollout-\(parent).jsonl").path)
        let recent = tokenEvent(totalInput: 200, cached: 0, output: 600, timestamp: "2026-10-16T00:01:00Z")
        try write([meta, recent], id: "\(parent)_\(suffix)", to: root)
        try write([sessionMeta(id: child, parentID: parent, timestamp: "2026-10-16T00:02:00Z"),
                   tokenEvent(totalInput: 200, cached: 0, output: 600, timestamp: "2026-10-16T00:02:01Z"),
                   tokenEvent(totalInput: 300, cached: 0, output: 900, timestamp: "2026-10-16T00:03:00Z")], id: child, to: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(
            now: try #require(CodexJSON.parseDate("2026-10-16T00:04:00Z")), calendar: calendar)
        #expect(value.deferredFileCount == 0)
        #expect(value.todayTotal.outputTokens == 600)
        #expect(value.todayRequestCount == 2)
        #expect(value.averageOutputTokensPerSecond == 2)
    }

    @Test func continuationDoesNotBorrowMissingOrConflictingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        let suffix = "22222222-2222-4222-8222-222222222222"
        let event = tokenEvent(totalInput: 100, cached: 0, output: 300, timestamp: "2026-10-16T00:01:00Z")
        try write([sessionMeta(id: id, timestamp: "2026-10-16T00:00:00Z"), event], id: id, to: root)
        let now = try #require(CodexJSON.parseDate("2026-10-16T00:04:00Z"))
        for lines in [[event], [sessionMeta(id: suffix, timestamp: "2026-10-16T00:00:00Z"), event]] {
            try write(lines, id: "\(id)_\(suffix)", to: root)
            let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
            #expect(value.averageOutputTokensPerSecond == nil)
            #expect(value.outputSpeedIsPartial)
        }
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
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastCached: 70, lastOutput: 10, timestamp: "2026-08-29T02:01:00Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastCached: 70, lastOutput: 10, timestamp: "2026-08-29T02:01:01Z"),
            tokenEvent(totalInput: 150, cached: 100, output: 15, lastInput: 50, lastCached: 30, lastOutput: 5, timestamp: "2026-08-29T02:02:00Z"),
        ]
        let childEvents = [
            sessionMeta(id: childID, parentID: parentID, timestamp: "2026-08-29T02:03:00Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastCached: 70, lastOutput: 10, timestamp: "2026-08-29T02:03:01Z"),
            tokenEvent(totalInput: 100, cached: 70, output: 10, lastInput: 100, lastCached: 70, lastOutput: 10, timestamp: "2026-08-29T02:03:02Z"),
            tokenEvent(totalInput: 150, cached: 100, output: 15, lastInput: 50, lastCached: 30, lastOutput: 5, timestamp: "2026-08-29T02:03:03Z"),
            tokenEvent(totalInput: 190, cached: 125, output: 19, lastInput: 40, lastCached: 25, lastOutput: 4, timestamp: "2026-08-29T02:04:00Z"),
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
        #expect(snapshot.todayTotal.cachedInputTokens == 140)
        #expect(snapshot.todayTotal.cacheHitRate == 140.0 / 220.0)
        #expect(snapshot.todayTotal.outputTokens == 22)
        #expect(snapshot.todayRequestCount == 5)
        #expect(snapshot.scannedFileCount == 4)
        #expect(snapshot.deferredFileCount == 0)
        #expect(snapshot.averageOutputTokensPerSecond == 0)
        let active = try SessionUsageReader(sessionsRoot: sessions, archivedSessionsRoot: archived)
            .dailySnapshot(now: try #require(CodexJSON.parseDate("2026-08-29T02:05:00Z")), calendar: calendar)
        // 19 output tokens, excluding archived copies, repeated snapshots and child replay.
        #expect(abs(try #require(active.averageOutputTokensPerSecond) - 19.0 / 300) < 0.000001)
    }

    @Test func outputSpeedCrossesMidnightAndExpiresWithoutCountingInputOrFutureEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        try write([
            sessionMeta(id: id, timestamp: "2026-10-14T15:00:00Z"),
            tokenEvent(totalInput: 1000, cached: 900, output: 900, timestamp: "2026-10-14T15:56:00Z"),
            tokenEvent(totalInput: 2000, cached: 1800, output: 1200, timestamp: "2026-10-14T15:59:00Z"),
            tokenEvent(totalInput: 3000, cached: 2700, output: 1800, timestamp: "2026-10-14T16:00:00Z"),
            tokenEvent(totalInput: 4000, cached: 3600, output: 2100, timestamp: "2026-10-14T16:02:00Z")
        ], id: id, to: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let reader = SessionUsageReader(sessionsRoot: root)
        let now = try #require(CodexJSON.parseDate("2026-10-14T16:01:00Z"))
        let value = try reader.dailySnapshot(now: now, calendar: calendar)
        // (300 before midnight + 600 after midnight) / 300 seconds. Lower bound excluded.
        #expect(value.averageOutputTokensPerSecond == 3)
        let idle = try reader.dailySnapshot(now: now.addingTimeInterval(600), calendar: calendar)
        #expect(idle.averageOutputTokensPerSecond == 0)
    }

    @Test func speedIsMarkedPartialWhenSessionCannotBeAttributed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try write([tokenEvent(totalInput: 1, cached: 0, output: 300,
                             timestamp: ISO8601DateFormatter().string(from: now))],
                  id: "11111111-1111-4111-8111-111111111111", to: root)
        let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
        #expect(value.averageOutputTokensPerSecond == nil)
        #expect(value.outputSpeedIsPartial)
    }

    @Test func oldUnattributedEventsDoNotHideCurrentSpeed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let id = "11111111-1111-4111-8111-111111111111"
        try write([sessionMeta(id: id, timestamp: formatter.string(from: now.addingTimeInterval(-600))),
                   tokenEvent(totalInput: 1, cached: 0, output: 300,
                              timestamp: formatter.string(from: now.addingTimeInterval(-10)))], id: id, to: root)
        try write([tokenEvent(totalInput: 1, cached: 0, output: 600,
                             timestamp: formatter.string(from: now.addingTimeInterval(-600)))],
                  id: "22222222-2222-4222-8222-222222222222", to: root)
        let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
        #expect(value.deferredFileCount == 1)
        #expect(value.averageOutputTokensPerSecond == 1)
        #expect(!value.outputSpeedIsPartial)
        // Same failure pattern as the real logs: a filename/metadata mismatch
        // with recent output must not suppress other safely attributed sessions.
        try write([sessionMeta(id: id, timestamp: formatter.string(from: now)),
                   tokenEvent(totalInput: 1, cached: 0, output: 600,
                              timestamp: formatter.string(from: now.addingTimeInterval(-10)))],
                  id: "22222222-2222-4222-8222-222222222222", to: root)
        let partial = try SessionUsageReader(sessionsRoot: root).dailySnapshot(now: now)
        #expect(partial.averageOutputTokensPerSecond == nil)
        #expect(partial.outputSpeedIsPartial)
        #expect(partial.todayTotal.normalizedTotal == value.todayTotal.normalizedTotal)
    }

    @Test func speedIncludesFileLastModifiedBeforeMidnight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        try write([sessionMeta(id: id, timestamp: "2026-10-14T15:00:00Z"),
                   tokenEvent(totalInput: 1000, cached: 900, output: 300,
                              timestamp: "2026-10-14T15:59:00Z")], id: id, to: root)
        try FileManager.default.setAttributes([.modificationDate:
            try #require(CodexJSON.parseDate("2026-10-14T15:59:01Z"))],
            ofItemAtPath: root.appendingPathComponent("rollout-\(id).jsonl").path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let value = try SessionUsageReader(sessionsRoot: root).dailySnapshot(
            now: try #require(CodexJSON.parseDate("2026-10-14T16:01:00Z")), calendar: calendar)
        #expect(value.todayTotal.normalizedTotal == 0)
        #expect(value.averageOutputTokensPerSecond == 1)
    }

    @Test func cacheHitRateHandlesEmptyAndMalformedCounts() {
        let empty = TokenCounts.zero
        #expect(empty.cacheHitRate == 0)

        let oversizedCache = TokenCounts(
            inputTokens: 100,
            cachedInputTokens: 140,
            cacheWriteInputTokens: nil,
            outputTokens: 0,
            reasoningOutputTokens: nil,
            totalTokens: 100
        )
        #expect(oversizedCache.cacheHitRate == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveCodexSnapshot() throws {
        let snapshot = try SessionUsageReader().dailySnapshot()
        print("SPEED_CHECK deferred=\(snapshot.deferredFileCount) speed=\(String(describing: snapshot.averageOutputTokensPerSecond))")
        #expect(snapshot.averageOutputTokensPerSecond != nil)
        let partial = snapshot.outputSpeedIsPartial
        #expect(!partial)
        #expect(snapshot.todayTotal.normalizedTotal > 0)
        print(
            "LIVE_SNAPSHOT today_total=\(snapshot.todayTotal.normalizedTotal) "
                + "requests=\(snapshot.todayRequestCount) "
                + "cached_input=\(snapshot.todayTotal.cachedInputTokens ?? 0) "
                + "cache_hit=\(String(format: "%.1f%%", snapshot.todayTotal.cacheHitRate * 100)) "
                + "session_total=\(snapshot.sessionTotal.normalizedTotal) "
                + "last_request=\(snapshot.lastRequest?.normalizedTotal ?? 0) "
                + "local_only=true"
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
        lastCached: UInt64? = nil,
        lastOutput: UInt64? = nil,
        timestamp: String
    ) -> String {
        let last: String
        if let lastInput, let lastOutput {
            last = ",\"last_token_usage\":{\"input_tokens\":\(lastInput),\"cached_input_tokens\":\(lastCached ?? 0),\"output_tokens\":\(lastOutput),\"total_tokens\":\(lastInput + lastOutput)}"
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
