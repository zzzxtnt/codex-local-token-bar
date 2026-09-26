import Foundation
import Testing
@testable import CodexTokenBar

@MainActor
struct ResetNotificationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexTokenBarTests." + UUID().uuidString)!
    }

    @Test func grantedPermissionDeliversOnceAndDisabledPreferencePersists() async {
        let sender = FakeNotificationSender()
        let defaults = defaults()
        let controller = ResetNotificationController(sender: sender, defaults: defaults)
        await controller.prepare()
        #expect(sender.permissionRequests == 1)
        let notice = QuotaResetNotice(timestamp: Date(), windows: ["5 小时已用 90% → 0%"])
        await controller.deliver(notice)
        await controller.deliver(notice)
        #expect(sender.sent.count == 1)
        await controller.setEnabled(false)
        await controller.deliver(QuotaResetNotice(timestamp: Date(), windows: ["7 天"]))
        #expect(sender.sent.count == 1)
        #expect(!ResetNotificationController(sender: sender, defaults: defaults).enabled)
    }

    @Test func deniedPermissionIsVisibleAndDoesNotSend() async {
        let sender = FakeNotificationSender()
        sender.grant = false
        let controller = ResetNotificationController(sender: sender, defaults: defaults())
        await controller.prepare()
        await controller.deliver(QuotaResetNotice(timestamp: Date(), windows: ["5 小时"]))
        #expect(sender.sent.isEmpty)
        #expect(controller.message.contains("未获允许"))
    }

    @Test func noStaleNotificationAfterSwitchAndFailureIsVisible() async {
        let sender = FakeNotificationSender()
        sender.status = .allowed
        let controller = ResetNotificationController(sender: sender, defaults: defaults())
        let notice = QuotaResetNotice(timestamp: Date(), windows: ["5 小时"])
        await controller.deliver(notice, isCurrent: { false })
        #expect(sender.sent.isEmpty)
        sender.fail = true
        await controller.deliver(notice)
        #expect(controller.message.contains("发送失败"))
    }

    @Test func noticeWaitsForPendingPermissionAndRechecksCurrentState() async {
        let sender = FakeNotificationSender()
        sender.suspendPermission = true
        let controller = ResetNotificationController(sender: sender, defaults: defaults())
        let preparing = Task { await controller.prepare() }
        while sender.permissionContinuation == nil { await Task.yield() }
        let notice = QuotaResetNotice(timestamp: Date(), windows: ["5 小时"])
        let sending = Task { await controller.deliver(notice) }
        // Let deliver observe the still-undetermined permission.
        for _ in 0..<10 { await Task.yield() }
        sender.status = .allowed
        sender.permissionContinuation?.resume(returning: true)
        await preparing.value
        await sending.value
        #expect(sender.sent.count == 1)
    }
}

@MainActor
private final class FakeNotificationSender: ResetNotificationSending {
    var status = ResetNotificationPermission.undetermined
    var grant = true
    var fail = false
    var permissionRequests = 0
    var sent: [QuotaResetNotice] = []
    var suspendPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    func permission() async -> ResetNotificationPermission { status }
    func requestPermission() async throws -> Bool {
        permissionRequests += 1
        if suspendPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        status = grant ? .allowed : .denied
        return grant
    }
    func send(_ notice: QuotaResetNotice) async throws {
        if fail { throw CocoaError(.fileReadUnknown) }
        sent.append(notice)
    }
}
