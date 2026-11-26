import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var dataSource: UsageDataSource
    @Published private(set) var localUsage: LocalUsageSnapshot?
    @Published private(set) var speedHistory = SpeedHistory()
    @Published var showingSettings = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var manualRefreshCount = 0
    var isManuallyRefreshing: Bool { manualRefreshCount > 0 }
    var supportsLocalQuota: Bool { dataSource.supportsLocalQuota }
    private var tokenReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var quotaReadWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var localError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var localQuota: LocalQuotaRecord?
    @Published private(set) var quotaMessage = "正在读取本地额度记录…"
    @Published private(set) var resetNotice: QuotaResetNotice?
    private var resetDetector = QuotaResetDetector()
    private var speedHistories: [UsageDataSource: SpeedHistory] = [:]
    private var lastQuotaPollAt: [UsageDataSource: Date] = [:]
    private var refreshLoop: Task<Void, Never>?
    private var quotaLoop: Task<Void, Never>?
    private var isReadingQuota = false
    private var sourceGeneration = UUID()
    private var quotaGeneration = UUID()
    private var ignoreQuotaThroughBySource: [UsageDataSource: Date] = [:]
    private let preferences: UserDefaults
    private let readLocal: @Sendable () throws -> LocalUsageSnapshot
    private let readAntigravity: @Sendable () throws -> LocalUsageSnapshot
    private let readQuota: @Sendable () throws -> LocalQuotaRecord?
    private let readAntigravityQuota: @Sendable () throws -> LocalQuotaRecord?

    init(startAutomatically: Bool = true,
         readLocal: @escaping @Sendable () throws -> LocalUsageSnapshot = { try SessionUsageReader().dailySnapshot() },
         readAntigravity: @escaping @Sendable () throws -> LocalUsageSnapshot = { try AntigravityUsageReader().dailySnapshot() },
         readQuota: @escaping @Sendable () throws -> LocalQuotaRecord? = { try SessionUsageReader().latestQuotaRecord() },
         readAntigravityQuota: @escaping @Sendable () throws -> LocalQuotaRecord? = { try AntigravityQuotaReader().latestQuotaRecord() },
         preferences: UserDefaults = .standard) {
        self.readLocal = readLocal
        self.readAntigravity = readAntigravity
        self.readQuota = readQuota
        self.readAntigravityQuota = readAntigravityQuota
        self.preferences = preferences
        let initialSource = preferences.string(forKey: "usageDataSource")
            .flatMap(UsageDataSource.init(rawValue:)) ?? .codex
        self.dataSource = initialSource
        self.quotaMessage = initialSource == .codex
            ? "正在读取本地额度记录…"
            : "正在查询 Antigravity 额度…"
        if let cutoff = preferences.object(forKey: "ignoreQuotaThrough") as? Double {
            ignoreQuotaThroughBySource[.codex] = Date(timeIntervalSince1970: cutoff)
        }
        if let agyCutoff = preferences.object(forKey: "ignoreAntigravityQuotaThrough") as? Double {
            ignoreQuotaThroughBySource[.antigravity] = Date(timeIntervalSince1970: agyCutoff)
        }
        guard startAutomatically else { return }
        quotaLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollQuotaIfDue()
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

    func setDataSource(_ newSource: UsageDataSource) {
        guard newSource != dataSource else { return }
        speedHistories[dataSource] = speedHistory
        dataSource = newSource
        preferences.set(newSource.rawValue, forKey: "usageDataSource")
        sourceGeneration = UUID()
        quotaGeneration = UUID()
        localUsage = nil
        localError = nil
        lastUpdated = nil
        clearQuotaState()
        quotaMessage = newSource == .codex
            ? "正在读取本地额度记录…"
            : "正在查询 Antigravity 额度…"
        speedHistory = speedHistories[newSource] ?? SpeedHistory()
    }

    func switchDataSource(_ newSource: UsageDataSource) async {
        guard newSource != dataSource else { return }
        setDataSource(newSource)
        await refresh()
    }

    var menuTitle: String {
        guard let localUsage else { return "\(dataSource.displayName) —" }
        let total = TokenFormatter.compact(localUsage.todayTotal.normalizedTotal)
        return "\(dataSource.displayName) \(total)，近 1 分钟平均输出 \(speedValue)"
    }

    var statusBarTooltip: String {
        guard let localUsage else {
            return "\(dataSource.shortTitle) Bar 正在读取数据"
        }
        let exactTotal = TokenFormatter.exact(localUsage.todayTotal.normalizedTotal)
        switch dataSource {
        case .codex:
            return "Codex 今日合计：\(exactTotal) tokens\n近 1 分钟平均输出：\(speedValue)\n按本地记录统计，每 30 秒自动更新；点击刷新会重新读取总量、额度和速度。包含空闲及工具等待，不是实时生成速度。— 表示读取失败、尚无数据或近期记录无法安全归属。"
        case .antigravity:
            return "Antigravity 今日合计：\(exactTotal) tokens\n近 1 分钟平均输出：\(speedValue)\n按本地会话日志统计，每 30 秒自动更新；额度通过本机 agy /usage 每 5 分钟自动查询。包含空闲及工具等待，无新输出时归零。"
        }
    }

    var speedValue: String {
        guard localError == nil, localUsage?.outputSpeedIsPartial != true,
              let rate = localUsage?.averageOutputTokensPerSecond,
              rate.isFinite, rate >= 0 else { return "— tok/s" }
        return String(format: "%.1f tok/s", rate)
    }

    var statusBarValue: String { "\(statusValue) · \(speedValue)" }

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

    var additionalWindows: [NamedRateLimitWindow] {
        localQuota?.quota.limits.additional ?? []
    }

    var planType: String? {
        localQuota?.quota.limits.planType
    }

    private func pollQuotaIfDue(now: Date = Date()) async {
        if let last = lastQuotaPollAt[dataSource],
           now.timeIntervalSince(last) < dataSource.quotaRefreshInterval {
            return
        }
        await refreshLocalQuota(now: now)
    }

    private func ignoreQuotaKey(for source: UsageDataSource) -> String {
        source == .codex ? "ignoreQuotaThrough" : "ignoreAntigravityQuotaThrough"
    }

    /// Read quota for the active source. Codex reads local JSONL history; Antigravity queries local `agy /usage`.
    func refreshLocalQuota(now: Date? = nil, waitForCurrent: Bool = false) async {
        if waitForCurrent {
            while isReadingQuota {
                await withCheckedContinuation { quotaReadWaiters.append($0) }
            }
        }
        guard !isReadingQuota else { return }
        let explicitNow = now
        let startNow = explicitNow ?? Date()
        let activeSource = dataSource
        isReadingQuota = true
        lastQuotaPollAt[activeSource] = startNow
        defer {
            isReadingQuota = false
            let waiters = quotaReadWaiters
            quotaReadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let generation = quotaGeneration
        let cutoff = ignoreQuotaThroughBySource[activeSource]
        let reader = activeSource == .codex ? readQuota : readAntigravityQuota
        do {
            let record = try await Task.detached(priority: .utility) { try reader() }.value
            guard generation == quotaGeneration, activeSource == dataSource else { return }
            let completedAt = explicitNow ?? Date()
            guard let record,
                  record.quota.timestamp <= completedAt.addingTimeInterval(5),
                  cutoff.map({ record.quota.timestamp > $0 }) ?? true else {
                clearQuotaState()
                quotaMessage = cutoff == nil
                    ? (activeSource == .codex ? "没有可用的本地额度记录" : "没有可用的 Antigravity 额度记录")
                    : "额度待确认：等待清除操作之后的新记录"
                return
            }
            if let existing = localQuota, existing.quota.timestamp > record.quota.timestamp { return }
            if localQuota?.sourceFile != record.sourceFile {
                resetDetector.clear()
                resetNotice = nil
            }
            localQuota = record
            quotaMessage = activeSource == .codex
                ? "本地历史记录，无法确认是否属于当前账号"
                : "通过本机 agy /usage 读取，每 5 分钟自动更新"
            // Only fresh, distinct log events can form a detection. Re-reading a
            // file is not confirmation, and startup must not replay old resets.
            if completedAt.timeIntervalSince(record.quota.timestamp) <= 120 {
                if let notice = resetDetector.observe(record.quota, source: record.sourceFile.path) {
                    resetNotice = notice
                }
            } else {
                resetDetector.clear()
            }
        } catch {
            guard generation == quotaGeneration, activeSource == dataSource else { return }
            clearQuotaState()
            quotaMessage = activeSource == .codex
                ? "本地额度读取失败：\(error.localizedDescription)"
                : "Antigravity 额度读取失败：\(error.localizedDescription)"
        }
    }

    /// Explicit user action; no account data is inspected or stored.
    func discardOldQuota(now: Date = Date()) {
        quotaGeneration = UUID()
        ignoreQuotaThroughBySource[dataSource] = now
        preferences.set(now.timeIntervalSince1970, forKey: ignoreQuotaKey(for: dataSource))
        clearQuotaState()
        quotaMessage = "额度待确认：等待清除操作之后的新记录"
    }

    private func clearQuotaState() {
        localQuota = nil
        resetDetector.clear()
        resetNotice = nil
    }

    func refresh() async {
        manualRefreshCount += 1
        defer { manualRefreshCount -= 1 }
        async let quota: Void = refreshLocalQuota(waitForCurrent: true)
        await refreshTokens(waitForCurrent: true)
        await quota
    }

    private func refreshTokens(waitForCurrent: Bool = false) async {
        if waitForCurrent {
            while isRefreshing {
                await withCheckedContinuation { tokenReadWaiters.append($0) }
            }
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = tokenReadWaiters
            tokenReadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let activeSource = dataSource
        let generation = sourceGeneration
        let reader = activeSource == .codex ? readLocal : readAntigravity
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try reader()
            }.value
            guard generation == sourceGeneration else { return }
            localUsage = snapshot
            localError = nil
            lastUpdated = Date()
            speedHistory.record(snapshot.outputSpeedIsPartial ? nil : snapshot.averageOutputTokensPerSecond, at: Date())
            speedHistories[activeSource] = speedHistory
        } catch {
            guard generation == sourceGeneration else { return }
            localError = error.localizedDescription
            speedHistory.record(nil, at: Date())
            speedHistories[activeSource] = speedHistory
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
