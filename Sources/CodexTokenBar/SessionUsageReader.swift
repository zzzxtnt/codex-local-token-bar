import Foundation

struct SessionUsageReader: Sendable {
    private let sessionsRoot: URL
    private let archivedSessionsRoot: URL?
    private let maximumCandidateFiles: Int
    private let reverseScanLimit: UInt64

    init(
        sessionsRoot: URL? = nil,
        archivedSessionsRoot: URL? = nil,
        maximumCandidateFiles: Int = 48,
        reverseScanLimit: UInt64 = 32 * 1_024 * 1_024
    ) {
        let defaultCodexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = sessionsRoot
            ?? defaultCodexRoot.appendingPathComponent("sessions", isDirectory: true)
        self.archivedSessionsRoot = archivedSessionsRoot
            ?? (sessionsRoot == nil
                ? defaultCodexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
                : nil)
        self.maximumCandidateFiles = maximumCandidateFiles
        self.reverseScanLimit = reverseScanLimit
    }

    /// CC Switch-compatible daily total. Each billable token event is counted once,
    /// inherited child-session replay is removed, and cached input is not added twice.
    func dailySnapshot(now: Date = Date(), calendar: Calendar = .current) throws -> LocalUsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            throw UsageError.sessionsNotFound
        }

        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw UsageError.noTokenEvents
        }

        let allFiles = try allSessionFiles()
        let rolloutIndex = Dictionary(grouping: allFiles.compactMap { file -> (String, URL)? in
            guard let id = threadID(from: file) else { return nil }
            return (id, file)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        let selectedFiles = allFiles.filter { modificationDate(for: $0) >= dayStart }.sorted {
            $0.path < $1.path
        }
        var parsedCache: [URL: ParsedCodexFile] = [:]

        func parsed(_ file: URL) throws -> ParsedCodexFile {
            if let cached = parsedCache[file] { return cached }
            let value = try parseCodexFile(file)
            parsedCache[file] = value
            return value
        }

        var requestIDs = Set<String>()
        var dailyInput: UInt64 = 0
        var dailyCached: UInt64 = 0
        var dailyOutput: UInt64 = 0
        var deferredFiles = 0

        for file in selectedFiles {
            let fileData = try parsed(file)
            guard let rootID = fileData.rootThreadID,
                  fileData.rootMetaSeen,
                  !fileData.isDeferred
            else {
                deferredFiles += 1
                continue
            }

            var replayPrefix = 0
            if let parentID = fileData.parentThreadID {
                guard let cutoff = fileData.rootTimestamp,
                      let candidates = rolloutIndex[parentID],
                      !candidates.isEmpty
                else {
                    deferredFiles += 1
                    continue
                }

                let parentSnapshots = try candidates.map { candidate in
                    try parsed(candidate).events.compactMap { event -> TokenUsageSignature? in
                        guard let timestamp = event.timestamp, timestamp <= cutoff else { return nil }
                        return event.signature
                    }
                }
                guard let first = parentSnapshots.first,
                      parentSnapshots.dropFirst().allSatisfy({ $0 == first })
                else {
                    deferredFiles += 1
                    continue
                }
                replayPrefix = matchingReplayPrefix(child: fileData.events, parent: first)
            }

            for (index, event) in fileData.events.enumerated() {
                guard index >= replayPrefix,
                      let eventIndex = event.eventIndex,
                      let timestamp = event.timestamp,
                      timestamp >= dayStart,
                      timestamp < dayEnd
                else { continue }

                let requestID = "codex_session:thread-v1:\(rootID):\(eventIndex)"
                guard requestIDs.insert(requestID).inserted else { continue }
                dailyInput = dailyInput.addingClamped(event.delta.input)
                dailyCached = dailyCached.addingClamped(event.delta.cachedInput)
                dailyOutput = dailyOutput.addingClamped(event.delta.output)
            }
        }

        let latest = try latestSnapshot(now: now)
        return LocalUsageSnapshot(
            timestamp: latest.timestamp,
            todayTotal: TokenCounts(
                inputTokens: dailyInput,
                cachedInputTokens: dailyCached,
                cacheWriteInputTokens: 0,
                outputTokens: dailyOutput,
                reasoningOutputTokens: nil,
                totalTokens: dailyInput.addingClamped(dailyOutput)
            ),
            todayRequestCount: requestIDs.count,
            scannedFileCount: selectedFiles.count,
            deferredFileCount: deferredFiles,
            sessionTotal: latest.sessionTotal,
            lastRequest: latest.lastRequest,
            contextWindow: latest.contextWindow,
            rateLimits: latest.rateLimits,
            sourceFile: latest.sourceFile,
            quotaTimestamp: latest.quotaTimestamp
        )
    }

    func latestSnapshot(now: Date = Date()) throws -> LocalUsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            throw UsageError.sessionsNotFound
        }

        let candidates = try candidateFiles(now: now)
        var latest: LocalUsageSnapshot?

        for file in candidates.prefix(maximumCandidateFiles) {
            guard let snapshot = try latestTokenEvent(in: file) else { continue }
            if latest == nil || snapshot.timestamp > latest!.timestamp {
                latest = snapshot
            }
        }

        guard let latest else { throw UsageError.noTokenEvents }
        // Quota updates can have info=null and can follow a different model's
        // token snapshot. Select the ordinary Codex bucket independently.
        var quota: QuotaSnapshot?
        for file in candidates {
            if let quota, modificationDate(for: file) < quota.timestamp { break }
            let record = try reverseRecord(in: file) { data in
                decodeLatestQuota(from: data)
            }
            if let record, quota == nil || record.timestamp > quota!.timestamp {
                quota = record
            }
        }
        return LocalUsageSnapshot(
            timestamp: latest.timestamp,
            sessionTotal: latest.sessionTotal,
            lastRequest: latest.lastRequest,
            contextWindow: latest.contextWindow,
            rateLimits: quota?.limits,
            sourceFile: latest.sourceFile,
            quotaTimestamp: quota?.timestamp
        )
    }

    private func candidateFiles(now: Date) throws -> [URL] {
        // Folder dates describe session creation, not its latest activity.
        try allSessionFiles().sorted {
            modificationDate(for: $0) > modificationDate(for: $1)
        }
    }

    private func allSessionFiles() throws -> [URL] {
        let fileManager = FileManager.default
        let roots = [sessionsRoot, archivedSessionsRoot].compactMap { $0 }
        var files: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let file = enumerator?.nextObject() as? URL {
                if file.pathExtension == "jsonl" { files.append(file) }
            }
        }
        return files
    }

    private func modificationDate(for file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func latestTokenEvent(in file: URL) throws -> LocalUsageSnapshot? {
        try reverseRecord(in: file) { data in
            decodeLatestTokenEvent(from: data, sourceFile: file)
        }
    }

    private func reverseRecord<T>(in file: URL, decode: (Data) -> T?) throws -> T? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }

        let chunkSize: UInt64 = 256 * 1_024
        var cursor = size
        var scanned: UInt64 = 0
        var buffer = Data()

        while cursor > 0 && scanned < reverseScanLimit {
            let amount = min(chunkSize, cursor, reverseScanLimit - scanned)
            cursor -= amount
            try handle.seek(toOffset: cursor)
            let chunk = try handle.read(upToCount: Int(amount)) ?? Data()
            buffer = chunk + buffer
            scanned += UInt64(chunk.count)

            if let snapshot = decode(buffer) {
                return snapshot
            }
        }

        return nil
    }

    func decodeLatestQuota(from data: Data) -> QuotaSnapshot? {
        for line in data.split(separator: 0x0A).reversed() {
            let bytes = Data(line)
            guard bytes.range(of: Data("\"rate_limits\"".utf8)) != nil,
                  let event = try? CodexJSON.decoder.decode(CodexLogEvent.self, from: bytes),
                  event.type == "event_msg", event.payload?.type == "token_count",
                  let limits = event.payload?.rateLimits, limits.isCodexQuota,
                  let timestamp = CodexJSON.parseDate(event.timestamp)
            else { continue }
            return QuotaSnapshot(timestamp: timestamp, limits: limits)
        }
        return nil
    }

    func decodeLatestTokenEvent(from data: Data, sourceFile: URL) -> LocalUsageSnapshot? {
        let marker = Data("\"token_count\"".utf8)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)

        for line in lines.reversed() {
            let lineData = Data(line)
            guard lineData.range(of: marker) != nil,
                  let event = try? CodexJSON.decoder.decode(CodexLogEvent.self, from: lineData),
                  event.type == "event_msg",
                  event.payload?.type == "token_count",
                  let info = event.payload?.info,
                  let total = info.totalTokenUsage,
                  total.hasValues,
                  let timestamp = CodexJSON.parseDate(event.timestamp)
            else {
                continue
            }

            let last = info.lastTokenUsage.flatMap { $0.hasValues ? $0 : nil }
            return LocalUsageSnapshot(
                timestamp: timestamp,
                sessionTotal: total,
                lastRequest: last,
                contextWindow: info.modelContextWindow,
                rateLimits: event.payload?.rateLimits,
                sourceFile: sourceFile
            )
        }
        return nil
    }

    private func parseCodexFile(_ file: URL) throws -> ParsedCodexFile {
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        var result = ParsedCodexFile(rootThreadID: threadID(from: file))
        var highWater: DeltaTokens?
        var signaturesBySource: [String: TokenUsageSignature] = [:]
        var previousSignature: TokenUsageSignature?
        var eventIndex = 0

        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            let isSessionMeta = line.range(of: Self.sessionMetaMarker) != nil
            let isTokenEvent = line.range(of: Self.tokenCountMarker) != nil
            guard isSessionMeta || isTokenEvent,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            if type == "session_meta", !result.rootMetaSeen {
                result.rootMetaSeen = true
                result.rootTimestamp = CodexJSON.parseDate(object["timestamp"] as? String)
                let payload = object["payload"] as? [String: Any] ?? [:]
                let forked = nonEmptyString(payload["forked_from_id"])
                let source = payload["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawn = subagent?["thread_spawn"] as? [String: Any]
                let spawned = nonEmptyString(spawn?["parent_thread_id"])

                if let forked, let spawned, forked.lowercased() != spawned.lowercased() {
                    result.isDeferred = true
                } else {
                    result.parentThreadID = (forked ?? spawned)?.lowercased()
                }

                let metadataID = nonEmptyString(payload["id"])
                    ?? nonEmptyString(payload["thread_id"])
                    ?? nonEmptyString(payload["threadId"])
                if let metadataID, let rootID = result.rootThreadID,
                   metadataID.lowercased() != rootID {
                    result.isDeferred = true
                }
                if result.parentThreadID == result.rootThreadID {
                    result.isDeferred = true
                }
                continue
            }

            guard type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let signature = tokenSignature(from: info)
            else { continue }

            let total = deltaTokens(from: info["total_token_usage"])
            let last = deltaTokens(from: info["last_token_usage"])
            guard total != nil || last != nil else { continue }

            let rateLimits = payload["rate_limits"] as? [String: Any]
            let source = nonEmptyString(rateLimits?["limit_id"]) ?? "__default__"
            let isDuplicate = total != nil
                && (signaturesBySource[source] == signature || previousSignature == signature)
            if total != nil { signaturesBySource[source] = signature }
            previousSignature = signature

            var delta: DeltaTokens
            if isDuplicate {
                delta = .zero
            } else if let last {
                delta = last
            } else if let total, let highWater {
                delta = DeltaTokens(
                    input: total.input.subtractingFloor(highWater.input),
                    cachedInput: total.cachedInput.subtractingFloor(highWater.cachedInput),
                    output: total.output.subtractingFloor(highWater.output)
                )
            } else {
                delta = total ?? .zero
            }

            if let total {
                if let existing = highWater {
                    highWater = DeltaTokens(
                        input: max(existing.input, total.input),
                        cachedInput: max(existing.cachedInput, total.cachedInput),
                        output: max(existing.output, total.output)
                    )
                } else {
                    highWater = total
                }
            }

            delta.cachedInput = min(delta.cachedInput, delta.input)
            let billableIndex: Int?
            if delta.isZero {
                billableIndex = nil
            } else {
                eventIndex += 1
                billableIndex = eventIndex
            }
            result.events.append(ParsedTokenEvent(
                signature: signature,
                delta: delta,
                eventIndex: billableIndex,
                timestamp: CodexJSON.parseDate(object["timestamp"] as? String)
            ))
        }
        return result
    }

    private func matchingReplayPrefix(
        child: [ParsedTokenEvent],
        parent: [TokenUsageSignature]
    ) -> Int {
        var parentOffset = 0
        var matched = 0
        for event in child {
            guard let relativeIndex = parent[parentOffset...].firstIndex(of: event.signature) else {
                break
            }
            parentOffset = relativeIndex + 1
            matched += 1
        }
        return matched
    }

    private func threadID(from file: URL) -> String? {
        let name = file.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36)).lowercased()
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private func tokenSignature(from info: [String: Any]) -> TokenUsageSignature? {
        let total = countersSignature(from: info["total_token_usage"])
        let last = countersSignature(from: info["last_token_usage"])
        guard total != nil || last != nil else { return nil }
        return TokenUsageSignature(total: total, last: last)
    }

    private func countersSignature(from value: Any?) -> TokenCountersSignature? {
        guard let object = value as? [String: Any] else { return nil }
        let keys = [
            "input_tokens", "cached_input_tokens", "cache_read_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens",
        ]
        guard keys.contains(where: { object[$0] != nil }) else { return nil }
        return TokenCountersSignature(
            input: uint64(object["input_tokens"]),
            cachedInput: uint64(object["cached_input_tokens"] ?? object["cache_read_input_tokens"]),
            output: uint64(object["output_tokens"]),
            reasoningOutput: uint64(object["reasoning_output_tokens"]),
            total: uint64(object["total_tokens"])
        )
    }

    private func deltaTokens(from value: Any?) -> DeltaTokens? {
        guard let object = value as? [String: Any] else { return nil }
        let keys = [
            "input_tokens", "cached_input_tokens", "cache_read_input_tokens",
            "output_tokens", "reasoning_output_tokens", "total_tokens",
        ]
        guard keys.contains(where: { object[$0] != nil }) else { return nil }
        return DeltaTokens(
            input: uint64(object["input_tokens"]) ?? 0,
            cachedInput: uint64(object["cached_input_tokens"] ?? object["cache_read_input_tokens"]) ?? 0,
            output: uint64(object["output_tokens"]) ?? 0
        )
    }

    private func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
}

private struct TokenCountersSignature: Hashable {
    let input: UInt64?
    let cachedInput: UInt64?
    let output: UInt64?
    let reasoningOutput: UInt64?
    let total: UInt64?
}

private struct TokenUsageSignature: Hashable {
    let total: TokenCountersSignature?
    let last: TokenCountersSignature?
}

private struct DeltaTokens {
    var input: UInt64
    var cachedInput: UInt64
    var output: UInt64

    static let zero = DeltaTokens(input: 0, cachedInput: 0, output: 0)
    var isZero: Bool { input == 0 && cachedInput == 0 && output == 0 }
}

private struct ParsedTokenEvent {
    let signature: TokenUsageSignature
    let delta: DeltaTokens
    let eventIndex: Int?
    let timestamp: Date?
}

private struct ParsedCodexFile {
    var rootThreadID: String?
    var rootMetaSeen = false
    var rootTimestamp: Date?
    var parentThreadID: String?
    var isDeferred = false
    var events: [ParsedTokenEvent] = []
}

private extension UInt64 {
    func subtractingFloor(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }

    func addingClamped(_ other: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}
