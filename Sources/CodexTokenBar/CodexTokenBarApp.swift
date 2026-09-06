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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = UsageModel()
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
        popover.contentSize = NSSize(width: 350, height: 430)
        popover.contentViewController = NSHostingController(rootView: UsagePopover(
            model: model,
            onClose: { [weak self] in self?.closePopover() }
        ))

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

    func applicationWillTerminate(_ notification: Notification) {
        removeDismissalMonitors()
    }
}
