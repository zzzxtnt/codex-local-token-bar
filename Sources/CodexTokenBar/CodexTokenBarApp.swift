import AppKit
import Combine
import SwiftUI

@main
struct CodexTokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = UsageModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observations = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        configureButton(item.button)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 430)
        popover.contentViewController = NSHostingController(rootView: UsagePopover(model: model))

        model.$localUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observations)
        model.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observations)

        updateButton()
        model.updateLaunchAtLoginStatus()
    }

    private func configureButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        let image = NSImage(systemSymbolName: "number.circle.fill", accessibilityDescription: "Codex Token")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        button.title = " \(model.statusValue)"
        button.toolTip = model.localUsage.map {
            "Codex 今日合计：\(TokenFormatter.exact($0.todayTotal.normalizedTotal)) tokens"
        } ?? "Codex Token Bar 正在读取数据"
        button.setAccessibilityLabel(model.menuTitle)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
