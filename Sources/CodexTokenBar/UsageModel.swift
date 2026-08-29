import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var localUsage: LocalUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var localError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginMessage: String?

    private var refreshLoop: Task<Void, Never>?

    init() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    deinit {
        refreshLoop?.cancel()
    }

    var menuTitle: String {
        guard let localUsage else { return "Codex —" }
        return "Codex \(TokenFormatter.compact(localUsage.todayTotal.normalizedTotal))"
    }

    var statusValue: String {
        guard let localUsage else { return "—" }
        return TokenFormatter.compact(localUsage.todayTotal.normalizedTotal)
    }

    var effectivePrimaryWindow: RateLimitWindow? {
        localUsage?.rateLimits?.primary
    }

    var effectiveSecondaryWindow: RateLimitWindow? {
        localUsage?.rateLimits?.secondary
    }

    var planType: String? {
        localUsage?.rateLimits?.planType
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try SessionUsageReader().dailySnapshot()
            }.value
            localUsage = snapshot
            localError = nil
            lastUpdated = Date()
        } catch {
            localError = error.localizedDescription
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            updateLaunchAtLoginStatus()
        } catch {
            updateLaunchAtLoginStatus()
            launchAtLoginMessage = "开机启动设置失败：\(error.localizedDescription)"
        }
    }

    func updateLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginMessage = "已设置开机启动"
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "需要在系统设置的登录项中允许"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "尚未设置开机启动"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "系统未找到登录项"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "无法确认开机启动状态"
        }
    }
}

enum TokenFormatter {
    static func compact(_ value: UInt64) -> String {
        switch value {
        case 1_000_000_000...:
            return decimal(Double(value) / 1_000_000_000) + "B"
        case 100_000_000...:
            return decimal(Double(value) / 100_000_000) + "亿"
        case 1_000_000...:
            return decimal(Double(value) / 1_000_000) + "M"
        case 1_000...:
            return decimal(Double(value) / 1_000) + "K"
        default:
            return value.formatted()
        }
    }

    static func exact(_ value: UInt64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func decimal(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
