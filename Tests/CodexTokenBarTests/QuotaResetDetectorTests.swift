import Foundation
import Testing
@testable import CodexTokenBar

struct QuotaResetDetectorTests {
    private func snapshot(_ used: Double, time: Double, reset: Double = 10_000,
                          secondary: Double? = nil, plan: String = "pro", duration: Int = 18_000) -> QuotaSnapshot {
        func window(_ value: Double, seconds: Int) -> RateLimitWindow {
            RateLimitWindow(usedPercent: value, windowMinutes: nil, limitWindowSeconds: seconds,
                            resetsAt: nil, resetAt: reset)
        }
        return QuotaSnapshot(timestamp: Date(timeIntervalSince1970: time), limits: SessionRateLimits(
            limitId: "codex", primary: window(used, seconds: duration),
            secondary: secondary.map { window($0, seconds: 604_800) }, planType: plan))
    }

    @Test func confirmsEarlyResetOnceAndCombinesWindows() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(80, time: 100, secondary: 60), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130, secondary: 0), source: "A") == nil)
        let notice = detector.observe(snapshot(1, time: 160, secondary: 1), source: "A")
        #expect(notice?.windows.count == 2)
        #expect(detector.observe(snapshot(1, time: 190, secondary: 1), source: "A") == nil)
        // A stale high snapshot followed by the same low snapshot must not re-alert.
        #expect(detector.observe(snapshot(80, time: 220, secondary: 60), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 250, secondary: 0), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 280, secondary: 0), source: "A") == nil)
    }

    @Test func detectsNewWindowEvenIfUsageAlreadyResumed() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(50, time: 100, reset: 120), source: "A") == nil)
        #expect(detector.observe(snapshot(4, time: 130, reset: 18_120), source: "A") == nil)
        #expect(detector.observe(snapshot(5, time: 160, reset: 18_120), source: "A") != nil)
    }

    @Test func sourceSwitchClearAndPlanChangesDoNotAlert() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(90, time: 100), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130), source: "B") == nil)
        #expect(detector.observe(snapshot(0, time: 160), source: "B") == nil)
        detector.clear()
        #expect(detector.observe(snapshot(90, time: 190), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 220, plan: "plus"), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 250, plan: "plus"), source: "A") == nil)
    }

    @Test func countdownMinorCorrectionAndTransientZeroDoNotAlert() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(50, time: 100, reset: 120), source: "A") == nil)
        #expect(detector.observe(snapshot(50, time: 130, reset: 120), source: "A") == nil)
        #expect(detector.observe(snapshot(49, time: 160, reset: 10_000), source: "A") == nil)
        #expect(detector.observe(snapshot(50, time: 190), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 220), source: "A") == nil)
        #expect(detector.observe(snapshot(50, time: 250), source: "A") == nil)
        #expect(detector.observe(snapshot(50, time: 280), source: "A") == nil)
    }

    @Test func staleAndLongGapSnapshotsCannotConfirm() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(90, time: 100), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 120), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 90_000, reset: 100_000), source: "A") == nil)
    }

    @Test func durationChangesAndInvalidValuesCannotTriggerReset() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(90, time: 100), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130, duration: 604_800), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 160, duration: 604_800), source: "A") == nil)
        #expect(detector.observe(snapshot(.nan, time: 190), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 220), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 250), source: "A") == nil)
    }

    @Test func aLaterResetWindowCanNotifyAgain() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(90, time: 100, reset: 120), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 130, reset: 18_120), source: "A") == nil)
        #expect(detector.observe(snapshot(1, time: 160, reset: 18_120), source: "A") != nil)
        #expect(detector.observe(snapshot(70, time: 18_100, reset: 18_120), source: "A") == nil)
        #expect(detector.observe(snapshot(0, time: 18_130, reset: 36_120), source: "A") == nil)
        #expect(detector.observe(snapshot(1, time: 18_160, reset: 36_120), source: "A") != nil)
    }

    @Test func temporaryZeroFollowedByNearlyOriginalUsageIsNotConfirmation() {
        var detector = QuotaResetDetector()
        #expect(detector.observe(snapshot(80, time: 100), source: "one") == nil)
        #expect(detector.observe(snapshot(0, time: 130), source: "one") == nil)
        #expect(detector.observe(snapshot(79, time: 160), source: "one") == nil)
        #expect(detector.observe(snapshot(79, time: 190), source: "one") == nil)
    }
}
