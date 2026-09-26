import AppKit
import Combine
import SwiftUI

@main
enum CodexTokenBarApp {
    @MainActor
    static func main() {
        // This is a menu-bar-only app. A placeholder SwiftUI Settings scene
        // still registers a real, empty window that activation can present.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = UsageModel()
    private let resetNotifications = ResetNotificationController(sender: SystemResetNotifications())
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observations = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        configureButton(item.button)

        // Own dismissal so a status-button click cannot auto-close on mouse-down
        // and then reopen the same popover on mouse-up.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let controller = UsagePopoverController(
            model: model,
            notifications: resetNotifications,
            onClose: { [weak self] in self?.closePopover() }
        )
        controller.attach(to: popover)

        model.$localUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observations)
        model.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observations)

        model.$resetNotice
            .compactMap { $0 }
            .sink { [weak self] notice in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.resetNotifications.deliver(notice) { [weak self] in
                        self?.model.resetNotice?.id == notice.id
                    }
                }
            }
            .store(in: &observations)

        updateButton()
        model.updateLaunchAtLoginStatus()
        Task { await resetNotifications.prepare() }
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
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installDismissalMonitors()
    }

    private func installDismissalMonitors() {
        removeDismissalMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.closePopover()
                    return nil
                }
            } else if event.window !== self.popover.contentViewController?.view.window {
                // Leave status-button events for togglePopover, including mouse-up.
                if let button = self.statusItem?.button,
                   event.window === button.window,
                   button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.closePopover()
            }
            return event
        }
        // Mouse-only monitoring needs no keyboard or accessibility permission.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        removeDismissalMonitors()
        if popover.isShown { popover.close() }
    }

    private func removeDismissalMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissalMonitors()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePopover()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening the app must never manufacture a standalone window.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeDismissalMonitors()
    }
}
