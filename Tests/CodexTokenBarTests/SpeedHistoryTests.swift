import Foundation
import AppKit
import SwiftUI
import Testing
@testable import CodexTokenBar

struct SpeedHistoryTests {
    @Test func hoverSelectsRealSamplesAndPreservesUnknownAndZero() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = SpeedHistory()
        history.record(12.5, at: now.addingTimeInterval(-120))
        history.record(nil, at: now.addingTimeInterval(-90))
        history.record(0, at: now)
        #expect(history.sample(near: now.addingTimeInterval(-118), now: now)?.rate == 12.5)
        #expect(history.sample(near: now.addingTimeInterval(-89), now: now)?.date == now.addingTimeInterval(-90))
        #expect(history.sample(near: now.addingTimeInterval(-89), now: now)?.rate == nil)
        #expect(history.sample(near: now.addingTimeInterval(-45), now: now) == nil)
        #expect(history.sample(near: now, now: now)?.rate == 0)
        #expect(history.sample(near: now, now: now.addingTimeInterval(601)) == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"] != nil))
    @MainActor func renderTrendWithGap() throws {
        _ = NSApplication.shared
        var history = SpeedHistory()
        let now = Date()
        for (index, rate) in [10.0, 22, 18, 41, 32, 0, 7, 23, 50, 31, 12, 8].enumerated() {
            history.record(index == 5 ? nil : rate, at: now.addingTimeInterval(Double(index - 11) * 30))
        }
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, selection) in [("normal", nil as Date?), ("hover", now.addingTimeInterval(-90)),
                                  ("gap", now.addingTimeInterval(-180))] {
        for dark in [false, true] {
            let host = NSHostingView(rootView: SpeedTrendView(history: history, currentValue: "8.0 tok/s")
                .trend(now: now, selectionDate: selection)
                .padding(12).frame(width: 320).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("trend-\(name)-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
        }
    }
    @Test func failuresAndSleepCreateGapsButZeroIsValid() {
        let now = Date(timeIntervalSince1970: 1000)
        var history = SpeedHistory()
        history.record(10, at: now)
        history.record(0, at: now.addingTimeInterval(30))
        history.record(nil, at: now.addingTimeInterval(60))
        history.record(20, at: now.addingTimeInterval(90))
        history.record(30, at: now.addingTimeInterval(200))
        let segments = history.segments(now: now.addingTimeInterval(200))
        #expect(segments.map(\.count) == [2, 1, 1])
        #expect(segments[0][1].rate == 0)
    }

    @Test func historyIsBoundedAndInvalidValuesAreGaps() {
        var history = SpeedHistory()
        let now = Date(timeIntervalSince1970: 1000)
        for index in 0..<150 { history.record(Double(index), at: now.addingTimeInterval(Double(index))) }
        #expect(history.samples.count == 120)
        history.record(.nan, at: now.addingTimeInterval(150))
        #expect(history.samples.last?.rate == nil)
        #expect(history.segments(now: now.addingTimeInterval(1000)).isEmpty)
        history.record(1, at: now.addingTimeInterval(1000))
        #expect(history.samples.count == 1)
    }
}
