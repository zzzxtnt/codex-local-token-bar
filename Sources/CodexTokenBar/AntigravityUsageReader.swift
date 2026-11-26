import Foundation
import SQLite3

/// Local-only reader for Antigravity (`agy` CLI / IDE / ACP) session transcripts and
/// companion conversation databases, adapted from CC Switch's `session_usage_agy.rs`
/// and `usage_stats.rs`. Reads no credentials, spawns no subprocesses, and makes no
/// network requests.
struct AntigravityUsageReader: Sendable {
    /// Matches CC Switch's `usage_stats.rs` thresholds for `agy_session` speed.
    static let speedMinOutputTokens: UInt64 = 200
    static let speedMinDurationMs: Int64 = 1_000
    static let speedMaxTokensPerSecond: UInt64 = 10_000

    private let brainRoots: [URL]

    init(brainRoots: [URL]? = nil) {
        self.brainRoots = brainRoots ?? Self.defaultBrainRoots()
    }

    static func defaultBrainRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        t3CodeHomeEnv: String? = ProcessInfo.processInfo.environment["T3CODE_HOME"]
    ) -> [URL] {
        let gemini = homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
        var roots: [URL] = [
            gemini.appendingPathComponent("antigravity-cli/brain", isDirectory: true),
            gemini.appendingPathComponent("antigravity/brain", isDirectory: true),
            gemini.appendingPathComponent("antigravity-acp/brain", isDirectory: true),
        ]

        let keyProfilesRoot = homeDirectory.appendingPathComponent(".cc-switch/agy", isDirectory: true)
        for profile in sortedSubdirectories(in: keyProfilesRoot) {
            roots.append(profile.appendingPathComponent("antigravity-cli/brain", isDirectory: true))
        }

        for t3Home in collectT3CodeHomes(homeDirectory: homeDirectory, envHome: t3CodeHomeEnv) {
            for stateDir in ["userdata", "dev"] {
                let instancesRoot = t3Home
                    .appendingPathComponent(stateDir, isDirectory: true)
                    .appendingPathComponent("providers/antigravity", isDirectory: true)
                for instance in sortedSubdirectories(in: instancesRoot) {
                    roots.append(instance.appendingPathComponent("antigravity-acp/brain", isDirectory: true))
                }
            }
        }
        return roots
    }

    func dailySnapshot(now: Date = Date(), calendar: Calendar = .current) throws -> LocalUsageSnapshot {
        let fileManager = FileManager.default
        let existingRoots = brainRoots.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingRoots.isEmpty else {
            throw UsageError.antigravitySessionsNotFound
        }

        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw UsageError.noAntigravityTokenEvents
        }

        let transcripts = discoverTranscripts(in: existingRoots)
        guard !transcripts.isEmpty else {
            throw UsageError.noAntigravityTokenEvents
        }

        let speedStart = now.addingTimeInterval(-60)
        // Include steps that started up to 15 minutes before speedStart so long-running
        // generations whose completion falls inside the trailing 60s window are attributed
        // accurately using native conversation DB latency.
        let timingLookbackStart = speedStart.addingTimeInterval(-900)
        let selectionCutoff = min(dayStart, speedStart)

        let selected = transcripts.filter { entry in
            latestRelevantModificationDate(for: entry.transcript) >= selectionCutoff
        }

        var requestIDs = Set<String>()
        var speedRequestIDs = Set<String>()
        var dailyFreshInput: UInt64 = 0
        var dailyCacheRead: UInt64 = 0
        var dailyCacheWrite: UInt64 = 0
        var dailyOutput: UInt64 = 0
        var recentOutput: UInt64 = 0
        var latestEventTimestamp: Date?
        var latestSourceFile: URL?
        var latestRequestCounts: TokenCounts?
        var sawAnyBillableStep = false

        for entry in selected {
            let steps = parseTranscript(at: entry.transcript)
            guard !steps.isEmpty else { continue }
            sawAnyBillableStep = true

            // Only open the companion SQLite DB for steps close enough to the trailing 60s
            // window that their completion timestamp could land in (speedStart, now].
            let timingCandidates = steps.compactMap { step -> UInt64? in
                guard step.output > 0,
                      let ts = step.timestamp,
                      ts >= timingLookbackStart,
                      ts <= now
                else { return nil }
                return step.stepIndex
            }
            let timings = timingCandidates.isEmpty
                ? [:]
                : AntigravityNativeTimingReader.readTimings(
                    forTranscript: entry.transcript,
                    stepIndices: timingCandidates
                )

            for step in steps {
                guard let timestamp = step.timestamp else { continue }
                let completedAt: Date
                if let timing = timings[step.stepIndex] {
                    let finish = timestamp.addingTimeInterval(Double(timing.latencyMs) / 1_000.0)
                    // Completed steps cannot finish in the future; clamp tiny clock skew to now.
                    completedAt = timestamp <= now ? min(finish, now) : finish
                } else {
                    completedAt = timestamp
                }

                if latestEventTimestamp == nil || completedAt > latestEventTimestamp! {
                    latestEventTimestamp = completedAt
                    latestSourceFile = entry.transcript
                    latestRequestCounts = step.asTokenCounts
                }

                let requestID = "agy:\(entry.sessionID):\(step.stepIndex)"
                if completedAt > speedStart, completedAt <= now,
                   speedRequestIDs.insert(requestID).inserted {
                    recentOutput = recentOutput.addingClamped(step.output)
                }

                if timestamp >= dayStart, timestamp < dayEnd,
                   requestIDs.insert(requestID).inserted {
                    dailyFreshInput = dailyFreshInput.addingClamped(step.freshInput)
                    dailyCacheRead = dailyCacheRead.addingClamped(step.cacheRead)
                    dailyCacheWrite = dailyCacheWrite.addingClamped(step.cacheWrite)
                    dailyOutput = dailyOutput.addingClamped(step.output)
                }
            }
        }

        if !sawAnyBillableStep {
            let fallback = latestBillableEvent(in: transcripts)
            guard let fallback else {
                throw UsageError.noAntigravityTokenEvents
            }
            latestEventTimestamp = fallback.timestamp
            latestSourceFile = fallback.sourceFile
            latestRequestCounts = fallback.lastRequest
        }

        // Antigravity reports input_tokens excluding cache reads/writes, while output_tokens
        // already includes thinking tokens. Match CC Switch's real_total_tokens and
        // cache_hit_rate = cache_read / (fresh_input + cache_write + cache_read).
        let cacheableInput = dailyFreshInput
            .addingClamped(dailyCacheRead)
            .addingClamped(dailyCacheWrite)
        let totalTokens = cacheableInput.addingClamped(dailyOutput)
        let todayTotal = TokenCounts(
            inputTokens: cacheableInput,
            cachedInputTokens: dailyCacheRead,
            cacheWriteInputTokens: dailyCacheWrite,
            outputTokens: dailyOutput,
            reasoningOutputTokens: nil,
            totalTokens: totalTokens
        )

        return LocalUsageSnapshot(
            timestamp: latestEventTimestamp ?? now,
            todayTotal: todayTotal,
            todayRequestCount: requestIDs.count,
            scannedFileCount: selected.count,
            deferredFileCount: 0,
            sessionTotal: todayTotal,
            lastRequest: latestRequestCounts,
            contextWindow: nil,
            rateLimits: nil,
            sourceFile: latestSourceFile ?? transcripts[0].transcript,
            quotaTimestamp: nil,
            averageOutputTokensPerSecond: Double(recentOutput) / 60.0,
            outputSpeedIsPartial: false
        )
    }

    static func isSpeedEligible(outputTokens: UInt64, latencyMs: Int64) -> Bool {
        guard outputTokens >= speedMinOutputTokens,
              latencyMs >= speedMinDurationMs
        else { return false }
        let lhs = outputTokens.multipliedReportingOverflow(by: 1_000)
        let rhs = UInt64(latencyMs).multipliedReportingOverflow(by: speedMaxTokensPerSecond)
        if lhs.overflow { return false }
        if rhs.overflow { return true }
        return lhs.partialValue <= rhs.partialValue
    }

    // MARK: - Transcript discovery & parsing

    private struct TranscriptEntry {
        let sessionID: String
        let transcript: URL
    }

    private struct ParsedAntigravityStep {
        let stepIndex: UInt64
        let freshInput: UInt64
        let output: UInt64
        let cacheRead: UInt64
        let cacheWrite: UInt64
        let timestamp: Date?

        var asTokenCounts: TokenCounts {
            let cacheable = freshInput.addingClamped(cacheRead).addingClamped(cacheWrite)
            return TokenCounts(
                inputTokens: cacheable,
                cachedInputTokens: cacheRead,
                cacheWriteInputTokens: cacheWrite,
                outputTokens: output,
                reasoningOutputTokens: nil,
                totalTokens: cacheable.addingClamped(output)
            )
        }
    }

    private func discoverTranscripts(in roots: [URL]) -> [TranscriptEntry] {
        let fileManager = FileManager.default
        var seenSessions = Set<String>()
        var result: [TranscriptEntry] = []

        for root in roots {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let sortedChildren = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in sortedChildren {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let sessionID = child.lastPathComponent
                guard Self.isValidSessionID(sessionID) else { continue }
                let candidate = child
                    .appendingPathComponent(".system_generated/logs/transcript_full.jsonl", isDirectory: false)
                guard fileManager.fileExists(atPath: candidate.path) else { continue }
                let isRegular = (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard Self.isPath(canonicalCandidate, inside: canonicalRoot) else { continue }
                if seenSessions.insert(sessionID).inserted {
                    result.append(TranscriptEntry(sessionID: sessionID, transcript: candidate))
                }
            }
        }
        return result
    }

    private func latestBillableEvent(
        in transcripts: [TranscriptEntry]
    ) -> (timestamp: Date, sourceFile: URL, lastRequest: TokenCounts)? {
        let ordered = transcripts.sorted {
            modificationDate(for: $0.transcript) > modificationDate(for: $1.transcript)
        }
        for entry in ordered {
            let steps = parseTranscript(at: entry.transcript)
            guard !steps.isEmpty else { continue }
            let latestStep = steps.max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            guard let latestStep else { continue }
            return (
                timestamp: latestStep.timestamp ?? modificationDate(for: entry.transcript),
                sourceFile: entry.transcript,
                lastRequest: latestStep.asTokenCounts
            )
        }
        return nil
    }

    private func parseTranscript(at file: URL) -> [ParsedAntigravityStep] {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return [] }
        // The export can rewrite steps as they finish; the latest record for a step_index wins.
        var latestByStep: [UInt64: [String: Any]] = [:]
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            guard line.range(of: Self.stepIndexMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stepIndex = Self.uint64(object["step_index"])
            else { continue }
            latestByStep[stepIndex] = object
        }

        var parsed: [ParsedAntigravityStep] = []
        for stepIndex in latestByStep.keys.sorted() {
            guard let row = latestByStep[stepIndex],
                  row["type"] as? String == "PLANNER_RESPONSE",
                  row["status"] as? String == "DONE"
            else { continue }
            let freshInput = Self.uint64(row["input_tokens"]) ?? 0
            let output = Self.uint64(row["output_tokens"]) ?? 0
            let cacheRead = Self.uint64(row["cache_read_tokens"]) ?? 0
            let cacheWrite = Self.uint64(row["cache_write_tokens"]) ?? 0
            if freshInput == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 {
                continue
            }
            parsed.append(ParsedAntigravityStep(
                stepIndex: stepIndex,
                freshInput: freshInput,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                timestamp: Self.parseTimestamp(row["created_at"])
            ))
        }
        return parsed
    }

    private func latestRelevantModificationDate(for transcript: URL) -> Date {
        var latest = modificationDate(for: transcript)
        if let dbURL = AntigravityNativeTimingReader.nativeDatabaseURL(forTranscript: transcript) {
            latest = max(latest, modificationDate(for: dbURL))
            let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
            latest = max(latest, modificationDate(for: walURL))
        }
        return latest
    }

    private func modificationDate(for file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x2D // -
        }
    }

    static func isPath(_ candidate: URL, inside root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }

    private static func sortedSubdirectories(in directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }

    private static func collectT3CodeHomes(homeDirectory: URL, envHome: String?) -> [URL] {
        var candidates: [URL] = []
        if let raw = envHome?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            candidates.append(URL(fileURLWithPath: raw, isDirectory: true))
        }
        candidates.append(homeDirectory.appendingPathComponent(".t3", isDirectory: true))

        var homes: [URL] = []
        var seenCanonical = Set<String>()
        for candidate in candidates {
            if homes.contains(candidate) { continue }
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            if !seenCanonical.insert(canonical).inserted { continue }
            homes.append(candidate)
        }
        return homes
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let string = value as? String {
            if let date = CodexJSON.parseDate(string) { return date }
            if let numeric = Double(string) { return dateFromEpoch(numeric) }
            return nil
        }
        if let number = value as? NSNumber {
            return dateFromEpoch(number.doubleValue)
        }
        return nil
    }

    private static func dateFromEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // Distinguish milliseconds (>= 1e12) from seconds.
        let seconds = value >= 1_000_000_000_000 ? value / 1_000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            if number.int64Value < 0 { return nil }
            return number.uint64Value
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    private static let stepIndexMarker = Data("\"step_index\"".utf8)
}

// MARK: - Native Conversation Database Timing Reader

struct AntigravityStepTiming: Equatable, Sendable {
    let latencyMs: Int64
    let firstTokenMs: Int64
}

enum AntigravityNativeTimingReader {
    static func nativeDatabaseURL(forTranscript transcript: URL) -> URL? {
        // brain/<id>/.system_generated/logs/transcript_full.jsonl
        // -> conversations/<id>.db under the same Antigravity root.
        let session = transcript
            .deletingLastPathComponent() // logs
            .deletingLastPathComponent() // .system_generated
            .deletingLastPathComponent() // <id>
        let brain = session.deletingLastPathComponent()
        guard brain.lastPathComponent == "brain" else { return nil }
        let root = brain.deletingLastPathComponent()
        let sessionID = session.lastPathComponent
        guard AntigravityUsageReader.isValidSessionID(sessionID) else { return nil }
        let candidate = root
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(sessionID).db", isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: candidate.path) else { return nil }
        let isRegular = (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isRegular else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard AntigravityUsageReader.isPath(canonicalCandidate, inside: canonicalRoot) else {
            return nil
        }
        return canonicalCandidate
    }

    static func readTimings(
        forTranscript transcript: URL,
        stepIndices: [UInt64]
    ) -> [UInt64: AntigravityStepTiming] {
        guard !stepIndices.isEmpty,
              let dbURL = nativeDatabaseURL(forTranscript: transcript)
        else { return [:] }
        return readTimings(fromDatabase: dbURL, stepIndices: stepIndices)
    }

    static func readTimings(
        fromDatabase dbURL: URL,
        stepIndices: [UInt64]
    ) -> [UInt64: AntigravityStepTiming] {
        guard let db = openReadOnlyDatabase(at: dbURL) else { return [:] }
        defer { sqlite3_close(db) }

        var stepStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT metadata FROM steps WHERE idx = ?1 AND step_type = 15",
            -1,
            &stepStmt,
            nil
        ) == SQLITE_OK, let stepStmt else { return [:] }
        defer { sqlite3_finalize(stepStmt) }

        var genStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT data FROM gen_metadata WHERE idx = ?1",
            -1,
            &genStmt,
            nil
        ) == SQLITE_OK, let genStmt else { return [:] }
        defer { sqlite3_finalize(genStmt) }

        var timings: [UInt64: AntigravityStepTiming] = [:]
        for step in stepIndices {
            guard let stepInt64 = Int64(exactly: step) else { continue }
            sqlite3_reset(stepStmt)
            sqlite3_clear_bindings(stepStmt)
            sqlite3_bind_int64(stepStmt, 1, stepInt64)
            guard sqlite3_step(stepStmt) == SQLITE_ROW,
                  let metadata = readBlob(statement: stepStmt, column: 0),
                  let generationIndex = decodeGenerationIndex(fromStepMetadata: metadata),
                  let genInt64 = Int64(exactly: generationIndex)
            else { continue }

            sqlite3_reset(genStmt)
            sqlite3_clear_bindings(genStmt)
            sqlite3_bind_int64(genStmt, 1, genInt64)
            guard sqlite3_step(genStmt) == SQLITE_ROW,
                  let genData = readBlob(statement: genStmt, column: 0),
                  let timing = decodeTiming(fromGenerationMetadata: genData)
            else { continue }

            timings[step] = timing
        }
        return timings
    }

    private static func openReadOnlyDatabase(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openCode = sqlite3_open_v2(url.path, &db, flags, nil)
        if openCode == SQLITE_OK, let db {
            sqlite3_busy_timeout(db, 0)
            let probeCode = probeReadable(db)
            if probeCode == SQLITE_OK {
                return db
            }
            sqlite3_close(db)
            if probeCode != SQLITE_CANTOPEN {
                return nil
            }
        } else {
            if let db { sqlite3_close(db) }
            if openCode != SQLITE_CANTOPEN {
                return nil
            }
        }
        return openImmutableFallback(at: url, flags: flags)
    }

    /// Fallback for checkpointed WAL databases without a `-shm` sibling.
    /// Never opens with `immutable=1` when a non-empty `-wal` exists.
    private static func openImmutableFallback(at url: URL, flags: Int32) -> OpaquePointer? {
        if hasNonEmptyWAL(for: url) { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, flags | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 0)
        guard probeReadable(db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func probeReadable(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &stmt, nil)
        if let stmt { sqlite3_finalize(stmt) }
        return code
    }

    private static func hasNonEmptyWAL(for url: URL) -> Bool {
        let walPath = url.path + "-wal"
        guard FileManager.default.fileExists(atPath: walPath) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attrs[.size] as? NSNumber
        else { return true }
        return size.uint64Value > 0
    }

    private static func readBlob(statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let ptr = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: ptr, count: length)
    }

    // MARK: - Minimal Protobuf Wire Decoder

    /// StepMetadata { optional GenerationReference generation = 20; }
    /// GenerationReference { uint64 index = 3; } (defaults to 0 when field 20 is present)
    static func decodeGenerationIndex(fromStepMetadata data: Data) -> UInt64? {
        var reader = ProtobufReader(data)
        var foundGeneration = false
        var generationIndex: UInt64 = 0
        while !reader.isAtEnd {
            guard let (fieldNumber, wireType) = reader.readTag() else { return nil }
            if fieldNumber == 20 {
                guard wireType == 2, let slice = reader.readLengthDelimited() else { return nil }
                foundGeneration = true
                var sub = ProtobufReader(slice)
                while !sub.isAtEnd {
                    guard let (subField, subWire) = sub.readTag() else { return nil }
                    if subField == 3 {
                        guard subWire == 0, let value = sub.readVarint() else { return nil }
                        generationIndex = value
                    } else if !sub.skipField(wireType: subWire) {
                        return nil
                    }
                }
            } else if !reader.skipField(wireType: wireType) {
                return nil
            }
        }
        return foundGeneration ? generationIndex : nil
    }

    /// GenerationTiming { optional ResponseTiming response = 1; }
    /// ResponseTiming { optional Duration first_token = 11; optional Duration streaming = 12; }
    /// Duration { int64 seconds = 1; int32 nanos = 2; }
    static func decodeTiming(fromGenerationMetadata data: Data) -> AntigravityStepTiming? {
        var reader = ProtobufReader(data)
        var firstToken: DurationAccumulator?
        var streaming: DurationAccumulator?

        while !reader.isAtEnd {
            guard let (fieldNumber, wireType) = reader.readTag() else { return nil }
            if fieldNumber == 1 {
                guard wireType == 2, let responseSlice = reader.readLengthDelimited() else { return nil }
                var responseReader = ProtobufReader(responseSlice)
                while !responseReader.isAtEnd {
                    guard let (respField, respWire) = responseReader.readTag() else { return nil }
                    if respField == 11 {
                        guard respWire == 2, let durSlice = responseReader.readLengthDelimited() else { return nil }
                        var acc = firstToken ?? DurationAccumulator()
                        guard acc.merge(from: durSlice) else { return nil }
                        firstToken = acc
                    } else if respField == 12 {
                        guard respWire == 2, let durSlice = responseReader.readLengthDelimited() else { return nil }
                        var acc = streaming ?? DurationAccumulator()
                        guard acc.merge(from: durSlice) else { return nil }
                        streaming = acc
                    } else if !responseReader.skipField(wireType: respWire) {
                        return nil
                    }
                }
            } else if !reader.skipField(wireType: wireType) {
                return nil
            }
        }

        guard let firstTokenMs = firstToken?.millis(),
              let streamingMs = streaming?.millis()
        else { return nil }
        let (latencyMs, overflow) = firstTokenMs.addingReportingOverflow(streamingMs)
        guard !overflow, latencyMs > 0 else { return nil }
        return AntigravityStepTiming(latencyMs: latencyMs, firstTokenMs: firstTokenMs)
    }

    private struct DurationAccumulator {
        var seconds: Int64 = 0
        var nanos: Int32 = 0

        mutating func merge(from slice: Data) -> Bool {
            var reader = ProtobufReader(slice)
            while !reader.isAtEnd {
                guard let (fieldNumber, wireType) = reader.readTag() else { return false }
                switch fieldNumber {
                case 1:
                    guard wireType == 0, let raw = reader.readVarint() else { return false }
                    seconds = Int64(bitPattern: raw)
                case 2:
                    guard wireType == 0, let raw = reader.readVarint() else { return false }
                    nanos = Int32(truncatingIfNeeded: raw)
                default:
                    if !reader.skipField(wireType: wireType) { return false }
                }
            }
            return true
        }

        func millis() -> Int64? {
            let (secMs, mulOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
            guard !mulOverflow else { return nil }
            let (total, addOverflow) = secMs.addingReportingOverflow(Int64(nanos) / 1_000_000)
            guard !addOverflow, total >= 0 else { return nil }
            return total
        }
    }

    private struct ProtobufReader {
        private let bytes: [UInt8]
        private var offset: Int = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return result
                }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        mutating func readTag() -> (fieldNumber: UInt64, wireType: UInt64)? {
            guard let tag = readVarint(), tag > 0 else { return nil }
            let fieldNumber = tag >> 3
            guard fieldNumber > 0 else { return nil }
            return (fieldNumber, tag & 0x07)
        }

        mutating func readLengthDelimited() -> Data? {
            guard let length = readVarint(),
                  length <= UInt64(bytes.count - offset)
            else { return nil }
            let end = offset + Int(length)
            let slice = Data(bytes[offset..<end])
            offset = end
            return slice
        }

        mutating func skipField(wireType: UInt64) -> Bool {
            switch wireType {
            case 0:
                return readVarint() != nil
            case 1:
                guard bytes.count - offset >= 8 else { return false }
                offset += 8
                return true
            case 2:
                return readLengthDelimited() != nil
            case 5:
                guard bytes.count - offset >= 4 else { return false }
                offset += 4
                return true
            default:
                return false
            }
        }
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}
