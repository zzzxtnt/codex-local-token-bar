import Foundation
import SQLite3
import Testing
@testable import CodexTokenBar

struct AntigravityUsageReaderTests {
    @Test func aggregatesDailyTokensAndTrailing60sSpeedDropsToZeroWhenIdle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cliRoot = root.appendingPathComponent("antigravity-cli", isDirectory: true)
        let ideRoot = root.appendingPathComponent("antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: cliRoot.appendingPathComponent("brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideRoot.appendingPathComponent("brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Session 1 in CLI root: rewritten step, incomplete step, yesterday step, older today step, recent step.
        try writeTranscript([
            #"{"step_index":0,"type":"USER_INPUT","status":"DONE","created_at":"2026-11-26T02:00:00Z","content":"hello"}"#,
            // Yesterday (Asia/Shanghai 2026-11-25 23:00 = UTC 2026-11-25T15:00:00Z)
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T15:00:00Z","input_tokens":500,"output_tokens":300,"cache_read_tokens":200}"#,
            // Rewritten step_index 2: earlier today (02:01:05Z), outside 60s speed window at 04:00:00Z
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-26T02:01:00Z","input_tokens":10,"output_tokens":10}"#,
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:01:05Z","input_tokens":1000,"output_tokens":400,"cache_read_tokens":3000,"cache_write_tokens":500}"#,
            // Started 80s before `now` (03:58:40Z), took 30s (finished 03:59:10Z -> inside trailing 60s window!)
            #"{"step_index":3,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T03:58:40Z","input_tokens":200,"output_tokens":600,"cache_read_tokens":800}"#,
            // Still running: ignored
            #"{"step_index":4,"type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-26T03:59:50Z","input_tokens":999,"output_tokens":999}"#,
        ], sessionID: "sess-1", under: cliRoot)

        // Duplicate session ID in IDE root must be ignored (first root wins, matching CC Switch)
        try writeTranscript([
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:01:05Z","input_tokens":99999,"output_tokens":99999}"#,
        ], sessionID: "sess-1", under: ideRoot)

        // Subagent session in IDE root: completed 20s before `now` (03:59:40Z, latency 5s -> finished 03:59:45Z)
        try writeTranscript([
            #"{"step_index":0,"type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-26T03:59:30Z","content":"subagent"}"#,
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T03:59:40Z","input_tokens":500,"output_tokens":300,"cache_read_tokens":1500}"#,
        ], sessionID: "subagent-1", under: ideRoot)

        // Native timing DB for sess-1:
        // step 3 -> generation 0 (omitted default index 0): first_token=10s, streaming=20s => latency=30s
        try writeNativeDB(
            at: cliRoot.appendingPathComponent("conversations/sess-1.db"),
            entries: [
                (step: 3, generation: 0, firstTokenMs: 10_000, streamingMs: 20_000),
            ]
        )
        // Native timing DB for subagent-1:
        // step 1 -> generation 4: first_token=1s, streaming=4s => latency=5s
        try writeNativeDB(
            at: ideRoot.appendingPathComponent("conversations/subagent-1.db"),
            entries: [
                (step: 1, generation: 4, firstTokenMs: 1_000, streamingMs: 4_000),
            ]
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(CodexJSON.parseDate("2026-11-26T04:00:00Z"))

        let reader = AntigravityUsageReader(brainRoots: [
            cliRoot.appendingPathComponent("brain", isDirectory: true),
            ideRoot.appendingPathComponent("brain", isDirectory: true),
        ])
        let active = try reader.dailySnapshot(now: now, calendar: calendar)

        // Fresh input: 1000 + 200 + 500 = 1700
        // Cache read:  3000 + 800 + 1500 = 5300
        // Cache write: 500 + 0 + 0 = 500
        // Cacheable input (= inputTokens): 1700 + 5300 + 500 = 7500
        // Output: 400 + 600 + 300 = 1300
        // Real total: 7500 + 1300 = 8800
        #expect(active.todayRequestCount == 3)
        #expect(active.todayTotal.inputTokens == 7_500)
        #expect(active.todayTotal.cachedInputTokens == 5_300)
        #expect(active.todayTotal.cacheWriteInputTokens == 500)
        #expect(active.todayTotal.outputTokens == 1_300)
        #expect(active.todayTotal.normalizedTotal == 8_800)
        #expect(abs(active.todayTotal.cacheHitRate - (5_300.0 / 7_500.0)) < 0.000001)

        // Trailing 60s window (03:59:00Z, 04:00:00Z]:
        // step 3 (finished 03:59:10Z, output 600) + subagent step 1 (finished 03:59:45Z, output 300) = 900 / 60 = 15.0 tok/s
        #expect(abs(try #require(active.averageOutputTokensPerSecond) - 15.0) < 0.0001)
        #expect(!active.outputSpeedIsPartial)

        // After 2 minutes idle with no new activity, speed must drop to 0.0 tok/s (never stay stuck!)
        let idle = try reader.dailySnapshot(now: now.addingTimeInterval(120), calendar: calendar)
        #expect(idle.todayTotal.normalizedTotal == 8_800)
        #expect(idle.averageOutputTokensPerSecond == 0)
    }

    @Test func nativeTimingHandlesMalformedProtobufAndSymlinkEscapeSafely() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        // Wait-only duration (missing field 12) and malformed wire types return nil
        let waitOnlyResponse = encodeMessage(field: 11, payload: encodeDuration(seconds: 2, nanos: 0))
        let waitOnlyGen = encodeMessage(field: 1, payload: waitOnlyResponse)
        #expect(AntigravityNativeTimingReader.decodeTiming(fromGenerationMetadata: waitOnlyGen) == nil)

        let badWireGen = encodeMessage(field: 1, payload: Data([0x58, 0x07])) // field 11 as varint
        #expect(AntigravityNativeTimingReader.decodeTiming(fromGenerationMetadata: badWireGen) == nil)
        #expect(AntigravityNativeTimingReader.decodeGenerationIndex(fromStepMetadata: Data([0x80])) == nil)
        #expect(AntigravityNativeTimingReader.decodeGenerationIndex(fromStepMetadata: Data()) == nil)

        // Symlinked DB pointing outside Antigravity root must be rejected (step falls back to created_at)
        let externalDB = outside.appendingPathComponent("escape.db")
        try writeNativeDB(at: externalDB, entries: [(step: 1, generation: 0, firstTokenMs: 40_000, streamingMs: 40_000)])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("conversations/escape.db"),
            withDestinationURL: externalDB
        )
        // Created 90s before `now`: without DB latency (rejected symlink), it is outside the 60s window -> 0.0 tok/s
        try writeTranscript([
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T03:58:30Z","input_tokens":100,"output_tokens":300}"#,
        ], sessionID: "escape", under: root)

        let now = try #require(CodexJSON.parseDate("2026-11-26T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try AntigravityUsageReader(brainRoots: [root.appendingPathComponent("brain")])
            .dailySnapshot(now: now, calendar: calendar)
        #expect(snapshot.todayTotal.outputTokens == 300)
        #expect(snapshot.averageOutputTokensPerSecond == 0)
    }

    @Test func zeroTodayTokensStillSucceedsAndSpeedCrossesMidnight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("brain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript([
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T15:59:40Z","input_tokens":100,"output_tokens":300}"#,
        ], sessionID: "midnight-sess", under: root)
        let transcript = root.appendingPathComponent("brain/midnight-sess/.system_generated/logs/transcript_full.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: try #require(CodexJSON.parseDate("2026-11-25T15:59:41Z"))],
            ofItemAtPath: transcript.path
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        // 2026-11-26 00:00:20+08:00 = 2026-11-25T16:00:20Z (20s after midnight)
        let now = try #require(CodexJSON.parseDate("2026-11-25T16:00:20Z"))
        let snapshot = try AntigravityUsageReader(brainRoots: [root.appendingPathComponent("brain")])
            .dailySnapshot(now: now, calendar: calendar)
        #expect(snapshot.todayTotal.normalizedTotal == 0)
        #expect(snapshot.todayRequestCount == 0)
        #expect(snapshot.averageOutputTokensPerSecond == 5)
    }

    @Test func parsesAntigravityFiveHourAndWeeklyQuotaOutput() throws {
        let sample = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.90, "reset_time": "2026-12-03T10:47:22Z"},
                    {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.60, "reset_time": "2026-11-26T15:47:22Z"},
                    {"id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.80, "reset_time": "2026-12-03T18:00:00Z"}
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z"},
                    {"id": "3p-5h", "window": "5h", "remaining_fraction": 0.75, "reset_time": "2026-11-26T16:00:00Z"}
                  ]
                }
              ]
            }
          }
        }
        """
        let now = try #require(CodexJSON.parseDate("2026-11-26T13:00:00Z"))
        let record = try #require(AntigravityQuotaReader.parseUsageOutput(Data(sample.utf8), now: now))
        #expect(record.quota.limits.limitId == "antigravity")
        #expect(record.quota.limits.isAntigravityQuota)
        #expect(record.quota.limits.isTrackedQuota)
        #expect(!record.quota.limits.isCodexQuota)

        #expect(abs(try #require(record.quota.limits.primary?.usedPercent) - 40.0) < 0.001)
        #expect(record.quota.limits.primary?.durationSeconds == 18_000)
        #expect(record.quota.limits.primary?.resetDate == CodexJSON.parseDate("2026-11-26T15:47:22Z"))

        #expect(abs(try #require(record.quota.limits.secondary?.usedPercent) - 10.0) < 0.001)
        #expect(record.quota.limits.secondary?.durationSeconds == 604_800)
        #expect(record.quota.limits.secondary?.resetDate == CodexJSON.parseDate("2026-12-03T10:47:22Z"))

        // Argon weekly + used 3p-5h included; unused 3p-weekly omitted.
        let additional = try #require(record.quota.limits.additional)
        #expect(additional.map(\.label) == ["Argon 7天", "三方 5h"])
        #expect(abs(try #require(additional[0].window.usedPercent) - 20.0) < 0.001)
        #expect(abs(try #require(additional[1].window.usedPercent) - 25.0) < 0.001)

        // Epoch-zero reset_time must decode as nil resetDate (never 1970-01-01)
        let epochResetSample = """
        {"status":"SUCCESS","command":{"data":{"groups":[{"buckets":[{"id":"gemini-5h","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"}]}]}}}
        """
        let epochRecord = try #require(AntigravityQuotaReader.parseUsageOutput(Data(epochResetSample.utf8), now: now))
        #expect(epochRecord.quota.limits.primary?.resetDate == nil)

        // Invalid or error payloads return nil
        #expect(AntigravityQuotaReader.parseUsageOutput(Data("not json".utf8)) == nil)
        #expect(AntigravityQuotaReader.parseUsageOutput(Data(#"{"status":"ERROR"}"#.utf8)) == nil)
        #expect(AntigravityQuotaReader.parseUsageOutput(Data(#"{"status":"SUCCESS","command":{"data":{"groups":[]}}}"#.utf8)) == nil)
    }

    @Test @MainActor func switchingDataSourcePersistsSelectionLoadsEachQuotaAndRejectsStaleReads() async throws {
        let suite = "AntigravitySwitchTests.\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }

        let codexStarted = DispatchSemaphore(value: 0)
        let releaseCodex = DispatchSemaphore(value: 0)
        let codexQuotaReads = LockedCounter()
        let agyQuotaReads = LockedCounter()

        let codexSnapshot = LocalUsageSnapshot(
            timestamp: Date(),
            todayTotal: TokenCounts(inputTokens: 1_000, cachedInputTokens: 500, cacheWriteInputTokens: 0, outputTokens: 200, reasoningOutputTokens: nil, totalTokens: 1_200),
            todayRequestCount: 2,
            sessionTotal: .zero,
            lastRequest: nil,
            contextWindow: nil,
            rateLimits: nil,
            sourceFile: URL(fileURLWithPath: "/codex.jsonl"),
            averageOutputTokensPerSecond: 12.5
        )
        let agySnapshot = LocalUsageSnapshot(
            timestamp: Date(),
            todayTotal: TokenCounts(inputTokens: 4_000, cachedInputTokens: 3_000, cacheWriteInputTokens: 0, outputTokens: 1_000, reasoningOutputTokens: nil, totalTokens: 5_000),
            todayRequestCount: 5,
            sessionTotal: .zero,
            lastRequest: nil,
            contextWindow: nil,
            rateLimits: nil,
            sourceFile: URL(fileURLWithPath: "/agy.jsonl"),
            averageOutputTokensPerSecond: 0
        )

        let blockFirstCodex = LockedFlag(true)
        let model = UsageModel(
            startAutomatically: false,
            readLocal: {
                if blockFirstCodex.consumeTrue() {
                    codexStarted.signal()
                    _ = releaseCodex.wait(timeout: .now() + 3)
                }
                return codexSnapshot
            },
            readAntigravity: { agySnapshot },
            readQuota: {
                codexQuotaReads.increment()
                return LocalQuotaRecord(
                    quota: QuotaSnapshot(
                        timestamp: Date(),
                        limits: SessionRateLimits(
                            limitId: "codex",
                            primary: RateLimitWindow(usedPercent: 25, windowMinutes: 300, limitWindowSeconds: 18_000, resetsAt: nil, resetAt: nil),
                            secondary: nil,
                            planType: "pro"
                        )
                    ),
                    sourceFile: URL(fileURLWithPath: "/codex.jsonl")
                )
            },
            readAntigravityQuota: {
                agyQuotaReads.increment()
                return LocalQuotaRecord(
                    quota: QuotaSnapshot(
                        timestamp: Date(),
                        limits: SessionRateLimits(
                            limitId: "antigravity",
                            primary: RateLimitWindow(usedPercent: 40, windowMinutes: 300, limitWindowSeconds: 18_000, resetsAt: nil, resetAt: nil),
                            secondary: RateLimitWindow(usedPercent: 10, windowMinutes: 10_080, limitWindowSeconds: 604_800, resetsAt: nil, resetAt: nil),
                            planType: nil
                        )
                    ),
                    sourceFile: URL(fileURLWithPath: "/usr/local/bin/agy")
                )
            },
            preferences: prefs
        )

        #expect(model.dataSource == .codex)

        // Start a slow Codex refresh, then switch to Antigravity before it completes.
        let slowCodex = Task { await model.refresh() }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: codexStarted.wait(timeout: .now() + 3) == .success)
            }
        }
        #expect(started)

        model.setDataSource(.antigravity)
        releaseCodex.signal()
        await slowCodex.value

        // Stale Codex result must not overwrite Antigravity state.
        #expect(model.dataSource == .antigravity)
        #expect(model.localUsage == nil)
        #expect(model.localQuota == nil)

        let codexQuotaBeforeAgy = codexQuotaReads.value
        await model.refresh()
        #expect(codexQuotaReads.value == codexQuotaBeforeAgy)
        #expect(agyQuotaReads.value == 1)
        #expect(model.statusBarValue == "5.00K · 0.0 tok/s")
        #expect(model.menuTitle.contains("Antigravity"))
        #expect(model.effectivePrimaryWindow?.usedPercent == 40)
        #expect(model.effectiveSecondaryWindow?.usedPercent == 10)

        // Restarting loads persisted Antigravity selection.
        let restored = UsageModel(startAutomatically: false, readLocal: { codexSnapshot }, readAntigravity: { agySnapshot }, readQuota: { nil }, readAntigravityQuota: { nil }, preferences: prefs)
        #expect(restored.dataSource == .antigravity)

        // Switching back to Codex loads Codex data & Codex quota cleanly.
        await model.switchDataSource(.codex)
        #expect(model.dataSource == .codex)
        #expect(model.statusBarValue == "1.20K · 12.5 tok/s")
        #expect(model.effectivePrimaryWindow?.usedPercent == 25)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveAntigravitySnapshot() throws {
        let snapshot = try AntigravityUsageReader().dailySnapshot()
        print(
            "LIVE_AGY_SNAPSHOT today_total=\(snapshot.todayTotal.normalizedTotal) "
                + "requests=\(snapshot.todayRequestCount) "
                + "cache_hit=\(String(format: "%.1f%%", snapshot.todayTotal.cacheHitRate * 100)) "
                + "speed=\(String(describing: snapshot.averageOutputTokensPerSecond))"
        )
        #expect(snapshot.todayTotal.normalizedTotal >= 0)
        #expect(snapshot.averageOutputTokensPerSecond != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_LIVE_TEST"] == "1"))
    func readsLiveAntigravityQuota() throws {
        let record = try #require(try AntigravityQuotaReader().latestQuotaRecord())
        #expect(record.quota.limits.isAntigravityQuota)
        print(
            "LIVE_AGY_QUOTA 5h=\(String(describing: record.quota.limits.primary?.usedPercent)) "
                + "weekly=\(String(describing: record.quota.limits.secondary?.usedPercent))"
        )
    }

    // MARK: - Fixture helpers

    private func writeTranscript(_ lines: [String], sessionID: String, under antigravityRoot: URL) throws {
        let logsDir = antigravityRoot
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let file = logsDir.appendingPathComponent("transcript_full.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }

    private func writeNativeDB(
        at url: URL,
        entries: [(step: Int64, generation: UInt64, firstTokenMs: Int64, streamingMs: Int64)]
    ) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let conn = try #require(db)
        defer { sqlite3_close(conn) }

        let schema = """
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB);
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        """
        #expect(sqlite3_exec(conn, schema, nil, nil, nil) == SQLITE_OK)

        for entry in entries {
            let genRefPayload = entry.generation == 0 ? Data() : encodeVarintField(field: 3, value: entry.generation)
            let stepMeta = encodeMessage(field: 20, payload: genRefPayload)

            var stepStmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(conn, "INSERT INTO steps VALUES (?1, 15, ?2)", -1, &stepStmt, nil) == SQLITE_OK)
            sqlite3_bind_int64(stepStmt, 1, entry.step)
            stepMeta.withUnsafeBytes { ptr in
                _ = sqlite3_bind_blob(stepStmt, 2, ptr.baseAddress, Int32(stepMeta.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            #expect(sqlite3_step(stepStmt) == SQLITE_DONE)
            sqlite3_finalize(stepStmt)

            var response = Data()
            response.append(encodeMessage(field: 11, payload: encodeDuration(millis: entry.firstTokenMs)))
            response.append(encodeMessage(field: 12, payload: encodeDuration(millis: entry.streamingMs)))
            let genData = encodeMessage(field: 1, payload: response)

            var genStmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(conn, "INSERT INTO gen_metadata VALUES (?1, ?2)", -1, &genStmt, nil) == SQLITE_OK)
            sqlite3_bind_int64(genStmt, 1, Int64(entry.generation))
            genData.withUnsafeBytes { ptr in
                _ = sqlite3_bind_blob(genStmt, 2, ptr.baseAddress, Int32(genData.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            #expect(sqlite3_step(genStmt) == SQLITE_DONE)
            sqlite3_finalize(genStmt)
        }
    }

    private func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func encodeVarintField(field: UInt64, value: UInt64) -> Data {
        var out = encodeVarint((field << 3) | 0)
        out.append(encodeVarint(value))
        return out
    }

    private func encodeMessage(field: UInt64, payload: Data) -> Data {
        var out = encodeVarint((field << 3) | 2)
        out.append(encodeVarint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private func encodeDuration(millis: Int64) -> Data {
        encodeDuration(seconds: millis / 1_000, nanos: Int32((millis % 1_000) * 1_000_000))
    }

    private func encodeDuration(seconds: Int64, nanos: Int32) -> Data {
        var out = Data()
        if seconds != 0 {
            out.append(encodeVarintField(field: 1, value: UInt64(bitPattern: seconds)))
        }
        if nanos != 0 {
            out.append(encodeVarintField(field: 2, value: UInt64(bitPattern: Int64(nanos))))
        }
        return out
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ initial: Bool) { self.flag = initial }
    func consumeTrue() -> Bool {
        lock.withLock {
            guard flag else { return false }
            flag = false
            return true
        }
    }
}
