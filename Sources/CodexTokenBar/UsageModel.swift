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
    @Published private(set) var localQuota: LocalQuotaRecord?
    @Published private(set) var quotaMessage = "正在读取本地额度记录…"
    @Published private(set) var resetNotice: QuotaResetNotice?
    private var resetDetector = QuotaResetDetector()
    private var refreshLoop: Task<Void, Never>?
    private var quotaLoop: Task<Void, Never>?
    private var isReadingQuota = false
    private var quotaGeneration = UUID()
    private var ignoreQuotaThrough: Date?
    private let preferences: UserDefaults
    private let readLocal: @Sendable () throws -> LocalUsageSnapshot
    private let readQuota: @Sendable () throws -> LocalQuotaRecord?

    init(startAutomatically: Bool = true,
         readLocal: @escaping @Sendable () throws -> LocalUsageSnapshot = { try SessionUsageReader().dailySnapshot() },
         readQuota: @escaping @Sendable () throws -> LocalQuotaRecord? = { try SessionUsageReader().latestQuotaRecord() },
         preferences: UserDefaults = .standard) {
        self.readLocal = readLocal
        self.readQuota = readQuota
        self.preferences = preferences
        if let cutoff = preferences.object(forKey: "ignoreQuotaThrough") as? Double {
            ignoreQuotaThrough = Date(timeIntervalSince1970: cutoff)
        }
        guard startAutomatically else { return }
        quotaLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLocalQuota()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTokens()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    deinit {
        refreshLoop?.cancel()
        quotaLoop?.cancel()
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
        localQuota?.quota.limits.primary
    }

    var effectiveSecondaryWindow: RateLimitWindow? {
        localQuota?.quota.limits.secondary
    }

    var planType: String? {
        localQuota?.quota.limits.planType
    }

    /// Read only usage logs. This data cannot identify the currently signed-in account.
    func refreshLocalQuota(now: Date = Date()) async {
        guard !isReadingQuota else { return }
        isReadingQuota = true
        defer { isReadingQuota = false }
        let generation = quotaGeneration
        do {
            let reader = readQuota
            let record = try await Task.detached(priority: .utility) { try reader() }.value
            guard generation == quotaGeneration else { return }
            guard let record,
                  record.quota.timestamp <= now.addingTimeInterval(5),
                  ignoreQuotaThrough.map({ record.quota.timestamp > $0 }) ?? true else {
                clearQuotaState()
                quotaMessage = ignoreQuotaThrough == nil ? "没有可用的本地额度记录" : "额度待确认：等待清除操作之后的新记录"
                return
            }
            if let existing = localQuota, existing.quota.timestamp > record.quota.timestamp { return }
            if localQuota?.sourceFile != record.sourceFile {
                resetDetector.clear()
                resetNotice = nil
            }
            localQuota = record
            quotaMessage = "本地历史记录，无法确认是否属于当前账号"
            // Only fresh, distinct log events can form a detection. Re-reading a
            // file is not confirmation, and startup must not replay old resets.
            if now.timeIntervalSince(record.quota.timestamp) <= 120 {
                if let notice = resetDetector.observe(record.quota, source: record.sourceFile.path) {
                    resetNotice = notice
                }
            } else {
                resetDetector.clear()
            }
        } catch {
            guard generation == quotaGeneration else { return }
            clearQuotaState()
            quotaMessage = "本地额度读取失败：\(error.localizedDescription)"
        }
    }

    /// Explicit user action; no account data is inspected or stored.
    func discardOldQuota(now: Date = Date()) {
        quotaGeneration = UUID()
        ignoreQuotaThrough = now
        preferences.set(now.timeIntervalSince1970, forKey: "ignoreQuotaThrough")
        clearQuotaState()
        quotaMessage = "额度待确认：等待清除操作之后的新记录"
    }

    private func clearQuotaState() {
        localQuota = nil
        resetDetector.clear()
        resetNotice = nil
    }

    func refresh() async {
        async let quota: Void = refreshLocalQuota()
        await refreshTokens()
        await quota
    }

    private func refreshTokens() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let reader = readLocal
            let snapshot = try await Task.detached(priority: .utility) {
                try reader()
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
