import Foundation

struct QuotaResetNotice: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let windows: [String]
    var message: String { "本地记录疑似重置或账号切换：" + windows.joined(separator: "；") }
}

/// Inference from one local log source, never proof of account identity or a server reset.
struct QuotaResetDetector {
    private struct Window {
        let used: Double
        let seconds: Int
        let reset: TimeInterval
        init?(_ window: RateLimitWindow?) {
            guard let window, let used = window.usedPercent, used.isFinite, (0...100).contains(used),
                  let seconds = window.durationSeconds, seconds > 0,
                  let reset = window.resetDate?.timeIntervalSince1970, reset.isFinite else { return nil }
            self.used = used
            self.seconds = seconds
            self.reset = reset
        }
        var name: String {
            seconds >= 86_400 ? "\(seconds / 86_400) 天" : "\(seconds / 3_600) 小时"
        }
    }
    private struct Candidate {
        let before: Window
        let after: Window
        let timestamp: Date
    }
    private struct Signature {
        let slot: Int
        let seconds: Int
        let reset: TimeInterval
        func matches(slot: Int, window: Window) -> Bool {
            self.slot == slot && seconds == window.seconds && abs(reset - window.reset) <= 60
        }
    }
    private var source: String?
    private var previous: QuotaSnapshot?
    private var candidates: [Int: Candidate] = [:]
    private var delivered: [Signature] = []

    mutating func clear() { self = Self() }

    mutating func observe(_ snapshot: QuotaSnapshot, source: String) -> QuotaResetNotice? {
        guard snapshot.limits.isCodexQuota else { return nil }
        guard self.source == source, let previous,
              previous.limits.planType == snapshot.limits.planType,
              snapshot.timestamp.timeIntervalSince(previous.timestamp) <= 86_400 else {
            clear()
            self.source = source
            self.previous = snapshot
            return nil
        }
        guard snapshot.timestamp > previous.timestamp else { return nil }
        defer { self.previous = snapshot }
        let oldWindows = [previous.limits.primary, previous.limits.secondary]
        let newWindows = [snapshot.limits.primary, snapshot.limits.secondary]
        var messages: [String] = []
        for slot in 0..<2 {
            guard let old = Window(oldWindows[slot]), let new = Window(newWindows[slot]),
                  old.seconds == new.seconds, new.reset > snapshot.timestamp.timeIntervalSince1970 else {
                candidates[slot] = nil
                continue
            }
            if let candidate = candidates[slot] {
                let age = snapshot.timestamp.timeIntervalSince(candidate.timestamp)
                let crossedBoundary = candidate.before.reset <= candidate.timestamp.timeIntervalSince1970
                    && candidate.after.reset - candidate.before.reset > 60
                let remainsRestored = new.seconds == candidate.after.seconds
                    && abs(new.reset - candidate.after.reset) <= 60
                    && candidate.before.used - new.used >= 1
                    && (crossedBoundary || new.used <= 5)
                if remainsRestored && age < 10 { continue }
                candidates[slot] = nil
                if remainsRestored && age <= 120 {
                    if !delivered.contains(where: { $0.matches(slot: slot, window: new) }) {
                        messages.append("\(new.name)已用 \(Int(candidate.before.used))% → \(Int(new.used))%")
                        delivered.append(Signature(slot: slot, seconds: new.seconds, reset: new.reset))
                        delivered = Array(delivered.suffix(32))
                    }
                    continue
                }
            }
            let nearlyCleared = old.used >= 5 && new.used <= 1
            let advancedWindow = old.reset <= snapshot.timestamp.timeIntervalSince1970
                && new.reset - old.reset > 60 && old.used - new.used >= 1
            if nearlyCleared || advancedWindow {
                candidates[slot] = Candidate(before: old, after: new, timestamp: snapshot.timestamp)
            }
        }
        return messages.isEmpty ? nil : QuotaResetNotice(timestamp: snapshot.timestamp, windows: messages)
    }
}
