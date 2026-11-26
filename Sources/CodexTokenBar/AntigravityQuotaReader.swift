import Foundation

/// Queries Antigravity 5-hour and weekly quota via the locally installed `agy` CLI
/// (`agy --print /usage --output-format json`), adapted from CC Switch's `subscription_agy.rs`.
/// This app reads no credentials or Keychain items and makes no direct HTTP requests.
struct AntigravityQuotaReader: Sendable {
    private let binaryOverride: URL?
    private let timeoutSeconds: TimeInterval

    init(binaryOverride: URL? = nil, timeoutSeconds: TimeInterval = 30) {
        self.binaryOverride = binaryOverride
        self.timeoutSeconds = timeoutSeconds
    }

    func latestQuotaRecord(now: Date = Date()) throws -> LocalQuotaRecord? {
        guard let binary = binaryOverride ?? Self.locateAgyBinary() else {
            throw UsageError.antigravityCLIMissing
        }
        let output = try Self.runUsageCommand(binary: binary, timeout: timeoutSeconds)
        guard let record = Self.parseUsageOutput(output, sourceFile: binary, now: now) else {
            throw UsageError.antigravityQuotaUnavailable
        }
        return record
    }

    static func locateAgyBinary(
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let pathEnv, !pathEnv.isEmpty {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                candidates.append(URL(fileURLWithPath: String(dir), isDirectory: true)
                    .appendingPathComponent("agy", isDirectory: false))
            }
        }
        candidates.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin/agy", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/agy", isDirectory: false),
            homeDirectory.appendingPathComponent(".gemini/antigravity-cli/bin/agy", isDirectory: false),
            homeDirectory.appendingPathComponent(".antigravity/bin/agy", isDirectory: false),
        ])

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.path
            guard seen.insert(path).inserted else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: path) {
                return candidate
            }
        }
        return nil
    }

    static func parseUsageOutput(
        _ data: Data,
        sourceFile: URL = URL(fileURLWithPath: "/usr/local/bin/agy"),
        now: Date = Date()
    ) -> LocalQuotaRecord? {
        struct UsageBucket: Decodable {
            let id: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        struct UsageGroup: Decodable {
            let buckets: [UsageBucket]?
        }
        struct UsageData: Decodable {
            let groups: [UsageGroup]?
        }
        struct UsageCommand: Decodable {
            let data: UsageData?
        }
        struct UsageOutput: Decodable {
            let status: String?
            let command: UsageCommand?
        }

        guard let decoded = try? CodexJSON.decoder.decode(UsageOutput.self, from: data),
              decoded.status == "SUCCESS",
              let groups = decoded.command?.data?.groups
        else { return nil }

        var bucketsByID: [String: RateLimitWindow] = [:]
        for group in groups {
            for bucket in group.buckets ?? [] {
                guard let id = bucket.id,
                      let remaining = bucket.remainingFraction,
                      remaining.isFinite
                else { continue }
                guard let durationSeconds = Self.durationSeconds(for: id) else { continue }
                let clampedRemaining = min(1.0, max(0.0, remaining))
                let usedPercent = (1.0 - clampedRemaining) * 100.0
                let resetEpoch: TimeInterval? = CodexJSON.parseDate(bucket.resetTime)
                    .map(\.timeIntervalSince1970)
                    .flatMap { $0 > 0 ? $0 : nil }
                bucketsByID[id] = RateLimitWindow(
                    usedPercent: usedPercent,
                    windowMinutes: durationSeconds / 60,
                    limitWindowSeconds: durationSeconds,
                    resetsAt: resetEpoch,
                    resetAt: nil
                )
            }
        }

        let primary = bucketsByID["gemini-5h"] ?? bucketsByID["3p-5h"]
        let secondary = bucketsByID["gemini-weekly"] ?? bucketsByID["3p-weekly"]
        guard primary != nil || secondary != nil else { return nil }

        var additional: [NamedRateLimitWindow] = []
        if let argonWeekly = bucketsByID["gemini-argon-wtu-weekly"] {
            additional.append(NamedRateLimitWindow(label: "Argon 7天", window: argonWeekly))
        }
        let usedGeminiGroup = bucketsByID["gemini-5h"] != nil || bucketsByID["gemini-weekly"] != nil
        if usedGeminiGroup {
            if let thirdParty5h = bucketsByID["3p-5h"], (thirdParty5h.usedPercent ?? 0) > 0.05 {
                additional.append(NamedRateLimitWindow(label: "三方 5h", window: thirdParty5h))
            }
            if let thirdPartyWeekly = bucketsByID["3p-weekly"], (thirdPartyWeekly.usedPercent ?? 0) > 0.05 {
                additional.append(NamedRateLimitWindow(label: "三方 7天", window: thirdPartyWeekly))
            }
        }

        let limits = SessionRateLimits(
            limitId: "antigravity",
            primary: primary,
            secondary: secondary,
            planType: nil,
            additional: additional.isEmpty ? nil : additional
        )
        return LocalQuotaRecord(
            quota: QuotaSnapshot(timestamp: now, limits: limits),
            sourceFile: sourceFile
        )
    }

    private static func durationSeconds(for bucketID: String) -> Int? {
        switch bucketID {
        case "gemini-5h", "3p-5h":
            return 18_000
        case "gemini-weekly", "gemini-argon-wtu-weekly", "3p-weekly":
            return 604_800
        default:
            return nil
        }
    }

    private static func runUsageCommand(binary: URL, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--print", "/usage", "--output-format", "json"]

        var env = ProcessInfo.processInfo.environment
        // Always query official signed-in account, matching CC Switch's subscription_agy.rs.
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_GEMINI_BASE_URL")
        process.environment = env

        let stdoutPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let box = DataBox()
        let readerGroup = DispatchGroup()
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readerGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            _ = readerGroup.wait(timeout: .now() + 2)
            throw UsageError.antigravityQuotaTimedOut
        }

        _ = readerGroup.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else {
            throw UsageError.antigravityQuotaUnavailable
        }
        return box.data
    }
}
