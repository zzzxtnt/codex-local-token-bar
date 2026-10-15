import Foundation
import Testing

struct LocalPrivacyBoundaryTests {
    @Test func onlyManualUpdaterMayUseNetworkOrProcessesAndNoCredentialsAreRead() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexTokenBar")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let updaterFiles = ["UpdateRelease.swift", "UpdateInstaller.swift", "UpdateController.swift"]
            let forbiddenEverywhere = ["auth.json", "access_token", "refresh_token", "SecItemCopyMatching"]
            let forbiddenInStatistics = ["URLSession", "URLRequest", "import Network", "import Security", "Process()"]
            for forbidden in forbiddenEverywhere + (updaterFiles.contains(file.lastPathComponent) ? [] : forbiddenInStatistics) {
                let violatesBoundary = source.contains(forbidden)
                #expect(!violatesBoundary, "Privacy boundary: \(file.lastPathComponent) contains \(forbidden)")
            }
        }
    }
}
