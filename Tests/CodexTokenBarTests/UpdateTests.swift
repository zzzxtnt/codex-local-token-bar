import CryptoKit
import Foundation
import Testing
@testable import CodexTokenBar

struct UpdateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_UPDATE_LIVE_TEST"] == "1"))
    func publicGitHubReleaseCanBeDownloadedAndVerifiedWithoutInstallation() async throws {
        let client = GitHubUpdateClient()
        let data = try await client.get(UpdateRelease.endpoint, limit: 1_048_576)
        let result = try UpdateRelease.parse(data, currentVersion: "0.0.0")
        let release = try #require(result)
        let checksum = try await client.get(release.checksumURL, limit: 65_536)
        let dmg = try await client.get(release.dmgURL, limit: release.size)
        try release.verify(dmg: dmg, checksums: checksum)
        print("PUBLIC_UPDATE_DOWNLOAD_VERIFIED version=\(release.version); no installation or Codex data access")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_SIGNED_APP"] != nil))
    func signedAppMatchesPinnedDeveloperAndRejectsWrongVersion() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CODEX_TOKEN_BAR_SIGNED_APP"])
        let app = URL(fileURLWithPath: path)
        let version = try #require(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        try UpdateInstaller.validateApp(app, version: version)
        #expect(throws: (any Error).self) { try UpdateInstaller.validateApp(app, version: "999.0.0") }
    }

    private func metadata(tag: String = "v0.1.7", draft: Bool = false, prerelease: Bool = false,
                          host: String = "github.com", includeChecksum: Bool = true) throws -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = ["CodexTokenBar-v\(version)-universal.dmg"] + (includeChecksum ? ["SHA256SUMS.txt"] : [])
        return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": "Notes",
            "draft": draft, "prerelease": prerelease, "assets": names.map {
                ["name": $0, "size": 3, "state": "uploaded",
                 "browser_download_url": "https://\(host)/\(UpdateRelease.repository)/releases/download/\(tag)/\($0)"] as [String: Any]
            }])
    }

    @Test func stableVersionOrderingAndAssetPolicy() throws {
        #expect(ReleaseVersion("v0.1.10")! > ReleaseVersion("0.1.9")!)
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
        for invalid in ["", "1..0", "1.0-beta", "../../1", "1.2.3.4", "９.0"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
        #expect(try UpdateRelease.parse(metadata(tag: "v0.1.5"), currentVersion: "0.1.6") == nil)
        #expect(try UpdateRelease.parse(metadata(tag: "v0.1.6"), currentVersion: "0.1.6") == nil)
        #expect(try UpdateRelease.parse(metadata(), currentVersion: "0.1.6")?.version == "0.1.7")
        for data in [try metadata(draft: true), try metadata(prerelease: true),
                     try metadata(host: "evil.example"), try metadata(includeChecksum: false)] {
            #expect(throws: (any Error).self) { try UpdateRelease.parse(data, currentVersion: "0.1.6") }
        }
    }

    @Test func checksumMustMatchExactAssetOnce() throws {
        let parsed = try UpdateRelease.parse(metadata(), currentVersion: "0.1.6")
        let release = try #require(parsed)
        let bytes = Data("abc".utf8)
        let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  \(release.dmgURL.lastPathComponent)\n"
        try release.verify(dmg: bytes, checksums: Data(checksum.utf8))
        for text in [checksum + checksum, checksum.replacingOccurrences(of: "ba7816", with: "000000"),
                     checksum.replacingOccurrences(of: release.dmgURL.lastPathComponent, with: "other.dmg")] {
            #expect(throws: (any Error).self) { try release.verify(dmg: bytes, checksums: Data(text.utf8)) }
        }
        #expect(throws: (any Error).self) { try release.verify(dmg: Data("abcd".utf8), checksums: Data(checksum.utf8)) }
    }

    @Test func redirectsRejectOtherHostsAndCredentials() {
        #expect(GitHubUpdateClient.permits(UpdateRelease.endpoint))
        #expect(GitHubUpdateClient.permits(URL(string: "https://release-assets.githubusercontent.com/asset?sig=public")!))
        for text in ["http://github.com/a", "https://github.com.evil.example/a", "https://api.github.com/user",
                     "https://github.com/other/repo/releases/download/v1/a.dmg", "file:///tmp/a",
                     "https://user:pass@release-assets.githubusercontent.com/a", "https://github.com:123/a"] {
            #expect(!GitHubUpdateClient.permits(URL(string: text)!))
        }
    }

    @Test @MainActor func noNetworkUntilClickAndNoInstallOnBadChecksum() async throws {
        let counter = RequestCounter()
        let metadata = try metadata()
        let controller = UpdateController(currentVersion: "0.1.6", fetch: { url, _ in
            await counter.increment()
            if url == UpdateRelease.endpoint { return metadata }
            return Data("abc".utf8)
        }, install: { _, _, _ in Issue.record("Invalid download must never reach installer") })
        #expect(await counter.count == 0)
        #expect(controller.release == nil)
        await controller.check()
        #expect(await counter.count == 1)
        #expect(controller.release?.version == "0.1.7")
        await controller.downloadAndInstall()
        #expect(await counter.count == 3)
        #expect(controller.message.contains("校验失败"))
        #expect(!controller.busy)
    }

    @Test func transactionKeepsOldBundleOnMoveOrLaunchFailure() throws {
        for failMove in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = root.appendingPathComponent("Current.app"), next = root.appendingPathComponent("New.app")
            let backup = root.appendingPathComponent("Previous.app")
            try Data("old".utf8).write(to: old)
            if !failMove { try Data("new".utf8).write(to: next) }
            #expect(throws: (any Error).self) {
                try UpdateInstaller.replace(staged: next, destination: old, backup: backup) { _ in
                    throw UpdateFailure("Synthetic launch failure")
                }
            }
            #expect(try String(contentsOf: old, encoding: .utf8) == "old")
        }
    }

    @Test func successfulTransactionPreservesBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Current.app"), next = root.appendingPathComponent("New.app")
        let backup = root.appendingPathComponent("Previous.app")
        try Data("old".utf8).write(to: old); try Data("new".utf8).write(to: next)
        var launched = false
        try UpdateInstaller.replace(staged: next, destination: old, backup: backup) { url in
            #expect(url == old); launched = true
        }
        #expect(launched)
        #expect(try String(contentsOf: old, encoding: .utf8) == "new")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
    }

    @Test func unsignedBundleAndWrongInstallLocationAreRejected() throws {
        #expect(throws: (any Error).self) {
            try UpdateInstaller.validateApp(URL(fileURLWithPath: "/private/tmp/missing.app"), version: "0.1.7")
        }
        #expect(throws: (any Error).self) {
            try UpdateInstaller.validateDestination(URL(fileURLWithPath: "/Volumes/Download/Codex Token Bar.app"))
        }
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
