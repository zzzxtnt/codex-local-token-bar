import AppKit
import Combine
import Foundation

@MainActor
final class UpdateController: ObservableObject {
    let currentVersion: String
    @Published private(set) var release: UpdateRelease?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published var notesExpanded = false
    private let fetch: @Sendable (URL, Int) async throws -> Data
    private let install: @MainActor (Data, UpdateRelease, String) async throws -> Void

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版",
         fetch: @escaping @Sendable (URL, Int) async throws -> Data = { try await GitHubUpdateClient().get($0, limit: $1) },
         install: @escaping @MainActor (Data, UpdateRelease, String) async throws -> Void = UpdateController.installApp) {
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.install = install
        // Deliberately no startup task, timer, or background check.
    }

    func check() async {
        guard !busy else { return }
        busy = true
        release = nil
        notesExpanded = false
        message = "正在检查 GitHub…"
        defer { busy = false }
        do {
            let data = try await fetch(UpdateRelease.endpoint, 1_048_576)
            release = try UpdateRelease.parse(data, currentVersion: currentVersion)
            message = release.map { "发现新版 v\($0.version)" } ?? "已是最新正式版"
        } catch { message = "检查失败：\(error.localizedDescription)" }
    }

    func downloadAndInstall() async {
        guard !busy, let release else { return }
        busy = true
        message = "正在下载安装包…"
        defer { busy = false }
        do {
            let sums = try await fetch(release.checksumURL, 65_536)
            let data = try await fetch(release.dmgURL, release.size)
            try release.verify(dmg: data, checksums: sums)
            message = "正在验证签名，完成后将重启…"
            try await install(data, release, currentVersion)
        } catch { message = "更新失败，旧版保留：\(error.localizedDescription)" }
    }

    private static func installApp(_ data: Data, _ release: UpdateRelease, _ version: String) async throws {
        let destination = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let work = try await Task.detached(priority: .utility) {
            try UpdateInstaller.prepare(dmg: data, release: release, destination: destination,
                                        currentVersion: version, parentPID: pid)
        }.value
        let helper = Process()
        helper.executableURL = work.appendingPathComponent("Installer")
        helper.arguments = ["--apply-update", work.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        let deadline = Date().addingTimeInterval(150)
        while helper.isRunning && Date() < deadline {
            if FileManager.default.fileExists(atPath: work.appendingPathComponent("ready").path) {
                NSApplication.shared.terminate(nil)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if helper.isRunning { helper.terminate() }
        throw UpdateFailure("安装进程未就绪，当前应用未退出。")
    }
}
