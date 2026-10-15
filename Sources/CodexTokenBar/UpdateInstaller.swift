import AppKit
import Foundation

enum UpdateInstaller {
    static let bundleID = "io.github.zzzxtnt.codexlocaltokenbar"
    static let requirement = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"N54QD9JH4V\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    struct Plan: Codable, Sendable {
        let destination: URL
        let version: String
        let oldVersion: String
        let parentPID: Int32
    }

    /// No shell, no privilege elevation, fixed system executables only.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw UpdateFailure("安装验证超时，旧版仍保留。")
        }
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("安装验证失败（\(URL(fileURLWithPath: path).lastPathComponent)），旧版仍保留。")
        }
    }

    static func validateApp(_ app: URL, version: String) throws {
        guard app.resolvingSymlinksInPath().path == app.standardizedFileURL.path,
              let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "CodexTokenBar",
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              let minimumVersion = ReleaseVersion(minimum) else {
            throw UpdateFailure("安装包的应用身份或版本不匹配。")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let system = ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
              minimumVersion <= system else { throw UpdateFailure("新版需要更高版本的 macOS。") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path])
        // Validate Apple trust/notarization without weakening Gatekeeper or removing quarantine.
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }

    static func validateDestination(_ destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let allowed = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        guard destination.lastPathComponent == "Codex Token Bar.app",
              allowed.contains(parent.path),
              destination.resolvingSymlinksInPath().path == destination.standardizedFileURL.path,
              fm.isWritableFile(atPath: parent.path) else {
            throw UpdateFailure("请先将应用安装到可写的 Applications 文件夹；此位置请手动更新。")
        }
    }

    /// Stages next to the installed app (same volume); never edits the live bundle.
    static func prepare(dmg: Data, release: UpdateRelease, destination: URL,
                        currentVersion: String, parentPID: Int32) throws -> URL {
        try validateDestination(destination)
        try validateApp(destination, version: currentVersion)
        let fm = FileManager.default
        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".CodexTokenBar-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? fm.removeItem(at: work) } }
        let image = work.appendingPathComponent("Update.dmg")
        try dmg.write(to: image, options: .atomic)
        try run("/usr/bin/hdiutil", ["verify", image.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", image.path])
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        do {
            let source = mount.appendingPathComponent("Codex Token Bar.app")
            try validateApp(source, version: release.version)
            let staged = work.appendingPathComponent("New.app")
            try fm.copyItem(at: source, to: staged)
            try validateApp(staged, version: release.version)
            try run("/usr/bin/hdiutil", ["detach", mount.path])
        } catch {
            // Never recursively remove an update directory while it still contains a mounted volume.
            do { try run("/usr/bin/hdiutil", ["detach", mount.path]) }
            catch { keep = true }
            throw error
        }
        let plan = Plan(destination: destination, version: release.version,
                        oldVersion: currentVersion, parentPID: parentPID)
        try JSONEncoder().encode(plan).write(to: work.appendingPathComponent("plan.json"), options: .atomic)
        // Use the currently trusted executable's installer, not code from release notes or a shell script.
        try fm.copyItem(at: destination.appendingPathComponent("Contents/MacOS/CodexTokenBar"),
                        to: work.appendingPathComponent("Installer"))
        keep = true
        return work
    }

    /// Testable transaction. On any failure the previous bundle remains at destination or backup.
    static func replace(staged: URL, destination: URL, backup: URL,
                        launch: (URL) throws -> Void) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backup.path) else { throw UpdateFailure("更新备份已存在，已停止。") }
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staged, to: destination)
            try launch(destination)
        } catch {
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: staged)
            }
            try fm.moveItem(at: backup, to: destination)
            throw error
        }
    }

    @MainActor static func helper(work: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            let fm = FileManager.default
            guard work.lastPathComponent.hasPrefix(".CodexTokenBar-update-"),
                  work.resolvingSymlinksInPath().path == work.standardizedFileURL.path else {
                throw UpdateFailure("安装工作目录不受支持。")
            }
            let attributes = try fm.attributesOfItem(atPath: work.path)
            guard attributes[.posixPermissions] as? Int == 0o700,
                  attributes[.ownerAccountID] as? UInt32 == getuid() else {
                throw UpdateFailure("安装工作目录权限不安全。")
            }
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: work.appendingPathComponent("plan.json")))
            try validateDestination(plan.destination)
            let lockURL = plan.destination.deletingLastPathComponent().appendingPathComponent(".CodexTokenBar-update.lock")
            let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { throw UpdateFailure("无法取得更新锁，请检查安装目录权限。") }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw UpdateFailure("另一个更新正在进行，请稍后重试。") }
            guard work.deletingLastPathComponent() == plan.destination.deletingLastPathComponent(),
                  let next = ReleaseVersion(plan.version), let old = ReleaseVersion(plan.oldVersion), next > old,
                  let parent = NSRunningApplication(processIdentifier: plan.parentPID),
                  parent.bundleURL?.standardizedFileURL == plan.destination.standardizedFileURL else {
                throw UpdateFailure("更新进程或版本已改变，请重试。")
            }
            let staged = work.appendingPathComponent("New.app")
            try validateApp(staged, version: plan.version)
            try validateApp(plan.destination, version: plan.oldVersion)
            try Data().write(to: work.appendingPathComponent("ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while !parent.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            guard parent.isTerminated else { throw UpdateFailure("旧版未退出，取消替换。") }
            // Another installer must not have changed the target while we waited.
            try validateApp(plan.destination, version: plan.oldVersion)
            try validateApp(staged, version: plan.version)
            let backup = work.appendingPathComponent("Previous.app")
            do {
                try replace(staged: staged, destination: plan.destination, backup: backup) { target in
                    try run("/usr/bin/open", ["-n", target.path])
                    let until = Date().addingTimeInterval(15)
                    var started = false
                    while Date() < until {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                            .contains(where: { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL && $0.isFinishedLaunching && !$0.isTerminated }) {
                            started = true
                            break
                        }
                    }
                    guard started else {
                        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                            .filter { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL && !$0.isTerminated }
                        for process in running { process.forceTerminate() }
                        let stopDeadline = Date().addingTimeInterval(5)
                        while running.contains(where: { !$0.isTerminated }) && Date() < stopDeadline {
                            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        }
                        throw UpdateFailure("新版未能启动，已尝试恢复旧版。")
                    }
                }
            } catch {
                try? run("/usr/bin/open", [plan.destination.path])
                throw error
            }
            // Preserve Previous.app for manual recovery; remove only our downloaded image.
            try? fm.removeItem(at: work.appendingPathComponent("Update.dmg"))
        } catch {
            let alert = NSAlert()
            alert.messageText = "更新未完成"
            alert.informativeText = error.localizedDescription + "\n旧版仍保留在原安装位置或更新备份目录：\n" + work.path
            app.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
