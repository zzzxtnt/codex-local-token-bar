import AppKit
import SwiftUI
import Testing
@testable import CodexTokenBar

@MainActor
struct PreferencesLayoutTests {
    /// Opt-in, deterministic UI fixtures. Never initializes the real usage model,
    /// notification service, login item service, or reads local Codex records.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"] != nil))
    func renderPreferencesStates() throws {
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UI_PREVIEW_DIR"]
        ))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let fixtures: [(String, Bool, String, Bool, String)] = [
            ("enabled", true, "已启用；横幅和声音受系统通知、专注模式控制", true, "已设置开机启动"),
            ("disabled", false, "已关闭系统提醒，仍在面板显示检测结果", false, "尚未设置开机启动"),
            ("permission", true, "通知未获允许，请在系统设置 → 通知中开启", false,
             "需要在系统设置的登录项中允许"),
            ("error", true, "系统通知发送失败；重置检测结果仍可在面板查看", false,
             "开机启动设置失败：无法完成操作，请在系统设置中检查登录项权限后重试。")
        ]
        for (name, notifications, message, login, loginMessage) in fixtures {
            for dark in [false, true] {
                let content = UsagePreferences(
                    resetNotificationsEnabled: .constant(notifications),
                    notificationMessage: message,
                    launchAtLoginEnabled: .constant(login),
                    launchAtLoginMessage: loginMessage
                )
                .padding(12)
                .frame(width: UsagePopover.panelWidth)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: UsagePopover.panelWidth, height: 250),
                    styleMask: .borderless, backing: .buffered, defer: false
                )
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                let size = host.fittingSize
                #expect(size.width == UsagePopover.panelWidth)
                #expect(size.height >= 70 && size.height < 260)
                if name == "enabled" || name == "disabled" {
                    #expect(size.height < 100)
                }
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
    }
}
