import AppKit
import SwiftUI
import Testing
@testable import CodexTokenBar

@MainActor
struct PopoverLayoutTests {
    @Test func menuBarApplicationDoesNotRegisterEmptySettingsScene() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entry = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexTokenBar/CodexTokenBarApp.swift"), encoding: .utf8)
        // Structural guard: this app has inline preferences, no Settings window.
        #expect(!entry.contains("Settings {"), "A Settings scene registers an unwanted standalone window")
        #expect(!entry.contains("WindowGroup {"))
    }
    @Test func hidesTechnicalMetadataFromPopover() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodexTokenBar/UsagePopover.swift"), encoding: .utf8)
        for field in ["usage.sourceFile", "usage.scannedFileCount", "usage.deferredFileCount",
                      "usage.contextWindow", "usage.sessionTotal"] {
            #expect(!source.contains(field))
        }
        #expect(UsagePopover.panelWidth == 320)
    }

    /// Uses injected fixture readers and an in-memory notification sender only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"] != nil))
    func renderCompactPopoverStates() async throws {
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"]
        ))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let now = Date()
        let source = URL(fileURLWithPath: "/fixture/hidden-session-id.jsonl")
        let tokens = TokenCounts(inputTokens: 111_140_000, cachedInputTokens: 95_224_800,
                                 cacheWriteInputTokens: nil, outputTokens: 2_860_000,
                                 reasoningOutputTokens: nil, totalTokens: 114_000_000)
        let usage = LocalUsageSnapshot(timestamp: now, todayTotal: tokens, todayRequestCount: 326,
            scannedFileCount: 1_024, deferredFileCount: 16, sessionTotal: tokens, lastRequest: nil,
            contextWindow: 258_000, rateLimits: nil, sourceFile: source)

        for state in ["loaded", "expired", "empty", "read-error", "permission", "long-error"] {
            let defaultsName = "PopoverLayoutTests." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let record = LocalQuotaRecord(quota: QuotaSnapshot(timestamp: now,
                limits: SessionRateLimits(limitId: "codex",
                    primary: RateLimitWindow(usedPercent: 16, windowMinutes: 300,
                        limitWindowSeconds: nil, resetsAt: now.addingTimeInterval(
                            state == "expired" ? -60 : 7_200).timeIntervalSince1970, resetAt: nil),
                    secondary: RateLimitWindow(usedPercent: 48, windowMinutes: 10_080,
                        limitWindowSeconds: nil, resetsAt: now.addingTimeInterval(86_400).timeIntervalSince1970,
                        resetAt: nil), planType: "fixture")), sourceFile: source)
            let model = UsageModel(startAutomatically: false, readLocal: {
                if state == "read-error" { throw UsageError.noTokenEvents }
                return usage
            }, readQuota: {
                if state == "long-error" {
                    throw NSError(domain: "LayoutFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        String(repeating: "这是一段用于验证长错误说明仍可滚动阅读的测试文本。", count: 30)])
                }
                return state == "empty" || state == "read-error" ? nil : record
            }, preferences: defaults)
            await model.refresh()
            let notifications = ResetNotificationController(
                sender: LayoutNotificationSender(denied: state == "permission"), defaults: defaults)
            await notifications.prepare()
            let popover = UsagePopover(model: model, notifications: notifications)
            let layout = NSHostingView(rootView: popover.content.frame(width: UsagePopover.panelWidth))
            let contentHeight = layout.fittingSize.height
            #expect(contentHeight > 200)
            if state == "loaded" || state == "expired" {
                #expect(contentHeight <= 410,
                        "Routine content must fit without scrolling: \(contentHeight)")
            }
            if state == "long-error" { #expect(contentHeight > UsagePopover.maximumHeight) }
            let expectedHeight = min(contentHeight, UsagePopover.maximumHeight)
            let controller = UsagePopoverController(model: model, notifications: notifications)
            let nativePopover = NSPopover()
            controller.attach(to: nativePopover)
            controller.view.layoutSubtreeIfNeeded()
            #expect(abs(controller.preferredContentSize.height - expectedHeight) <= 1)
            #expect(abs(nativePopover.contentSize.height - expectedHeight) <= 1)
            for dark in [false, true] {
                let host = NSHostingView(rootView: popover
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                    width: UsagePopover.panelWidth, height: expectedHeight),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                // AppKit's native control fitting sizes can settle by a few points
                // after attaching to a window. Neither state may add a blank tail.
                #expect(host.fittingSize.height <= expectedHeight + 1
                        && host.fittingSize.height >= expectedHeight - 8,
                        "Panel must not reserve empty space below its content: \(state), panel \(host.fittingSize.height), content \(contentHeight)")
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("popover-\(state)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }

            if state == "loaded" {
                let previousHeight = nativePopover.contentSize.height
                // The same mounted controller must shrink after a real model update.
                model.discardOldQuota(now: now)
                for _ in 0..<30 {
                    controller.view.layoutSubtreeIfNeeded()
                    if nativePopover.contentSize.height < previousHeight - 30 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let updatedLayout = NSHostingView(rootView: popover.content.frame(width: UsagePopover.panelWidth))
                #expect(nativePopover.contentSize.height < previousHeight - 30)
                #expect(abs(nativePopover.contentSize.height - updatedLayout.fittingSize.height) <= 1)
            }
        }
    }
}

@MainActor
private final class LayoutNotificationSender: ResetNotificationSending {
    let denied: Bool
    init(denied: Bool) { self.denied = denied }
    func permission() async -> ResetNotificationPermission { denied ? .denied : .allowed }
    func requestPermission() async throws -> Bool { !denied }
    func send(_ notice: QuotaResetNotice) async throws {}
}
