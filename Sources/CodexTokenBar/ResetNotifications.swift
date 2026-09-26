import Combine
import Foundation
import UserNotifications

enum ResetNotificationPermission: Sendable { case undetermined, allowed, denied }

@MainActor
protocol ResetNotificationSending {
    func permission() async -> ResetNotificationPermission
    func requestPermission() async throws -> Bool
    func send(_ notice: QuotaResetNotice) async throws
}

@MainActor
final class SystemResetNotifications: NSObject, ResetNotificationSending, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func permission() async -> ResetNotificationPermission {
        // Older SDKs do not make UNNotificationSettings Sendable. Read it on
        // the callback's queue and transfer only our value across the actor.
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let permission: ResetNotificationPermission
                switch settings.authorizationStatus {
                case .authorized, .provisional: permission = .allowed
                case .notDetermined: permission = .undetermined
                default: permission = .denied
                }
                continuation.resume(returning: permission)
            }
        }
    }

    func requestPermission() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func send(_ notice: QuotaResetNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Codex 本地额度变化提醒"
        content.body = notice.message
        content.sound = .default
        let request = UNNotificationRequest(identifier: "quota-reset-" + notice.id.uuidString,
                                            content: content, trigger: nil)
        // Keep all notification-center calls on the main actor even with SDKs
        // whose async imports transfer the non-Sendable center to another queue.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@MainActor
final class ResetNotificationController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var message = "重置提醒需要允许系统通知"
    private let sender: any ResetNotificationSending
    private let defaults: UserDefaults
    private var sentIDs = Set<UUID>()
    private var authorizationTask: Task<Bool, Error>?

    init(sender: any ResetNotificationSending, defaults: UserDefaults = .standard) {
        self.sender = sender
        self.defaults = defaults
        enabled = defaults.object(forKey: "quotaResetNotificationsEnabled") as? Bool ?? true
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        defaults.set(value, forKey: "quotaResetNotificationsEnabled")
        await prepare()
    }

    func prepare() async {
        guard enabled else {
            message = "已关闭系统提醒，仍在面板显示检测结果"
            return
        }
        do {
            var permission = await sender.permission()
            if permission == .undetermined {
                if authorizationTask == nil {
                    authorizationTask = Task { try await sender.requestPermission() }
                }
                permission = try await authorizationTask!.value ? .allowed : .denied
                authorizationTask = nil
            }
            guard enabled else { return }
            message = permission == .allowed
                ? "已启用；横幅和声音受系统通知、专注模式控制"
                : "通知未获允许，请在系统设置 → 通知中开启"
        } catch {
            authorizationTask = nil
            message = "无法申请通知权限，请检查系统通知设置"
        }
    }

    func deliver(_ notice: QuotaResetNotice, isCurrent: () -> Bool = { true }) async {
        guard enabled, !sentIDs.contains(notice.id) else { return }
        var permission = await sender.permission()
        if permission == .undetermined, let pending = authorizationTask {
            permission = (try? await pending.value) == true ? .allowed : .denied
        }
        guard enabled, isCurrent(), !sentIDs.contains(notice.id) else { return }
        guard permission == .allowed else {
            message = "检测到本地额度变化，但通知未获允许；请查看面板"
            return
        }
        // Reserve before awaiting the system to prevent concurrent duplicate delivery.
        sentIDs.insert(notice.id)
        if sentIDs.count > 128 { sentIDs = [notice.id] }
        do { try await sender.send(notice) }
        catch { message = "系统通知发送失败；重置检测结果仍可在面板查看" }
    }
}
