import Foundation
import SQLite3
import Testing
@testable import CodexTokenBar

struct AntigravityUsageReaderTests {
    @Test func aggregatesDailyTokensAndWeightedNativeSpeedMatchingCCSwitch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cliRoot = root.appendingPathComponent("antigravity-cli", isDirectory: true)
        let ideRoot = root.appendingPathComponent("antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: cliRoot.appendingPathComponent("brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideRoot.appendingPathComponent("brain"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideRoot.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Session 1 in CLI root: rewritten step, incomplete step, yesterday step, small step (<200), eligible step.
        try writeTranscript([
            #"{"step_index":0,"type":"USER_INPUT","status":"DONE","created_at":"2026-11-26T02:00:00Z","content":"hello"}"#,
            // Yesterday (Asia/Shanghai 2026-11-25 23:00 = UTC 2026-11-25T15:00:00Z)
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-25T15:00:00Z","input_tokens":500,"output_tokens":300,"cache_read_tokens":200}"#,
            // Rewritten step_index 2: initial RUNNING then final DONE with updated counters
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-26T02:01:00Z","input_tokens":10,"output_tokens":10}"#,
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:01:05Z","input_tokens":1000,"output_tokens":400,"cache_read_tokens":3000,"cache_write_tokens":500}"#,
            // Small output (< 200): counts in daily tokens, excluded from speed
            #"{"step_index":3,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:02:00Z","input_tokens":200,"output_tokens":50,"cache_read_tokens":800}"#,
            // Still running: ignored
            #"{"step_index":4,"type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-11-26T02:03:00Z","input_tokens":999,"output_tokens":999}"#,
        ], sessionID: "sess-1", under: cliRoot)

        // Duplicate session ID in IDE root must be ignored (first root wins, matching CC Switch)
        try writeTranscript([
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:01:05Z","input_tokens":99999,"output_tokens":99999}"#,
        ], sessionID: "sess-1", under: ideRoot)

        // Subagent session in IDE root with eligible speed step
        try writeTranscript([
            #"{"step_index":0,"type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-26T03:00:00Z","content":"subagent"}"#,
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T03:00:10Z","input_tokens":500,"output_tokens":600,"cache_read_tokens":1500}"#,
        ], sessionID: "subagent-1", under: ideRoot)

        // Native timing DB for sess-1:
        // step 2 -> generation 0 (default omitted index 0): first_token=2000ms, streaming=3000ms => latency=5000ms
        // step 3 -> generation 1: first_token=500ms, streaming=1500ms => latency=2000ms (excluded by output<200)
        try writeNativeDB(
            at: cliRoot.appendingPathComponent("conversations/sess-1.db"),
            entries: [
                (step: 2, generation: 0, firstTokenMs: 2_000, streamingMs: 3_000),
                (step: 3, generation: 1, firstTokenMs: 500, streamingMs: 1_500),
            ]
        )
        // Native timing DB for subagent-1:
        // step 1 -> generation 4: first_token=1000ms, streaming=4000ms => latency=5000ms
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
        let snapshot = try reader.dailySnapshot(now: now, calendar: calendar)

        // Fresh input: 1000 + 200 + 500 = 1700
        // Cache read:  3000 + 800 + 1500 = 5300
        // Cache write: 500 + 0 + 0 = 500
        // Cacheable input (= inputTokens): 1700 + 5300 + 500 = 7500
        // Output: 400 + 50 + 600 = 1050
        // Real total: 7500 + 1050 = 8550
        #expect(snapshot.todayRequestCount == 3)
        #expect(snapshot.todayTotal.inputTokens == 7_500)
        #expect(snapshot.todayTotal.cachedInputTokens == 5_300)
        #expect(snapshot.todayTotal.cacheWriteInputTokens == 500)
        #expect(snapshot.todayTotal.outputTokens == 1_050)
        #expect(snapshot.todayTotal.normalizedTotal == 8_550)
        #expect(abs(snapshot.todayTotal.cacheHitRate - (5_300.0 / 7_500.0)) < 0.000001)

        // Weighted speed (CC Switch formula): (400 + 600) / ((5000 + 5000) / 1000) = 100.0 tok/s
        #expect(abs(try #require(snapshot.averageOutputTokensPerSecond) - 100.0) < 0.0001)
        #expect(!snapshot.outputSpeedIsPartial)
    }

    @Test func nativeTimingEnforcesThresholdsAndRejectsMalformedOrSymlinkEscape() throws {
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

        // Speed eligibility boundary checks
        #expect(!AntigravityUsageReader.isSpeedEligible(outputTokens: 199, latencyMs: 5_000))
        #expect(!AntigravityUsageReader.isSpeedEligible(outputTokens: 200, latencyMs: 999))
        #expect(AntigravityUsageReader.isSpeedEligible(outputTokens: 200, latencyMs: 1_000))
        #expect(!AntigravityUsageReader.isSpeedEligible(outputTokens: 10_001, latencyMs: 1_000))
        #expect(AntigravityUsageReader.isSpeedEligible(outputTokens: 10_000, latencyMs: 1_000))

        // Wait-only duration (missing field 12) and malformed wire types return nil
        let waitOnlyResponse = encodeMessage(field: 11, payload: encodeDuration(seconds: 2, nanos: 0))
        let waitOnlyGen = encodeMessage(field: 1, payload: waitOnlyResponse)
        #expect(AntigravityNativeTimingReader.decodeTiming(fromGenerationMetadata: waitOnlyGen) == nil)

        let badWireGen = encodeMessage(field: 1, payload: Data([0x58, 0x07])) // field 11 as varint
        #expect(AntigravityNativeTimingReader.decodeTiming(fromGenerationMetadata: badWireGen) == nil)
        #expect(AntigravityNativeTimingReader.decodeGenerationIndex(fromStepMetadata: Data([0x80])) == nil)
        #expect(AntigravityNativeTimingReader.decodeGenerationIndex(fromStepMetadata: Data()) == nil)

        // Symlinked DB pointing outside Antigravity root must be rejected
        let externalDB = outside.appendingPathComponent("escape.db")
        try writeNativeDB(at: externalDB, entries: [(step: 1, generation: 0, firstTokenMs: 1_000, streamingMs: 1_000)])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("conversations/escape.db"),
            withDestinationURL: externalDB
        )
        try writeTranscript([
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-26T02:00:00Z","input_tokens":100,"output_tokens":300}"#,
        ], sessionID: "escape", under: root)

        let now = try #require(CodexJSON.parseDate("2026-11-26T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try AntigravityUsageReader(brainRoots: [root.appendingPathComponent("brain")])
            .dailySnapshot(now: now, calendar: calendar)
        #expect(snapshot.todayTotal.outputTokens == 300)
        #expect(snapshot.averageOutputTokensPerSecond == nil)
    }

    @Test func zeroTodayTokensStillSucceedsWhenHistoricalTranscriptExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("brain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTranscript([
            #"{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-20T02:00:00Z","input_tokens":100,"output_tokens":50}"#,
        ], sessionID: "old-sess", under: root)

        let now = try #require(CodexJSON.parseDate("2026-11-26T04:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try AntigravityUsageReader(brainRoots: [root.appendingPathComponent("brain")])
            .dailySnapshot(now: now, calendar: calendar)
        #expect(snapshot.todayTotal.normalizedTotal == 0)
        #expect(snapshot.todayRequestCount == 0)
        #expect(snapshot.averageOutputTokensPerSecond == nil)
    }

    @Test @MainActor func switchingDataSourcePersistsSelectionIsolatesStateAndRejectsStaleReads() async throws {
        let suite = "AntigravitySwitchTests.\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }

        let codexStarted = DispatchSemaphore(value: 0)
        let releaseCodex = DispatchSemaphore(value: 0)
        let quotaReads = LockedCounter()

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
            averageOutputTokensPerSecond: 84.2
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
                quotaReads.increment()
                return LocalQuotaRecord(
                    quota: QuotaSnapshot(
                        timestamp: Date(),
                        limits: SessionRateLimits(
                            limitId: "codex",
                            primary: RateLimitWindow(usedPercent: 25, windowMinutes: 300, limitWindowSeconds: nil, resetsAt: nil, resetAt: nil),
                            secondary: nil,
                            planType: "pro"
                        )
                    ),
                    sourceFile: URL(fileURLWithPath: "/codex.jsonl")
                )
            },
            preferences: prefs
        )

        #expect(model.dataSource == .codex)
        #expect(model.supportsLocalQuota)

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
        #expect(!model.supportsLocalQuota)

        let quotaCountBeforeAgy = quotaReads.value
        await model.refresh()
        #expect(quotaReads.value == quotaCountBeforeAgy)
        #expect(model.statusBarValue == "5.00K · 84.2 tok/s")
        #expect(model.menuTitle.contains("Antigravity"))
        #expect(model.speedHistory.samples.last?.rate == 84.2)

        // Restarting loads persisted Antigravity selection.
        let restored = UsageModel(startAutomatically: false, readLocal: { codexSnapshot }, readAntigravity: { agySnapshot }, readQuota: { nil }, preferences: prefs)
        #expect(restored.dataSource == .antigravity)

        // Switching back to Codex loads Codex data and keeps independent speed history.
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
            // StepMetadata { GenerationReference generation = 20 { uint64 index = 3; } }
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

            // GenerationTiming { ResponseTiming response = 1 { Duration first_token = 11; Duration streaming = 12; } }
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
