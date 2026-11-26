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
            let processAllowedFiles = updaterFiles + ["AntigravityQuotaReader.swift"]
            let forbiddenEverywhere = ["auth.json", "access_token", "refresh_token", "SecItemCopyMatching"]
            let forbiddenNetworkOrSecurity = ["URLSession", "URLRequest", "import Network", "import Security"]
            var forbidden = forbiddenEverywhere
            if !updaterFiles.contains(file.lastPathComponent) {
                forbidden.append(contentsOf: forbiddenNetworkOrSecurity)
            }
            if !processAllowedFiles.contains(file.lastPathComponent) {
                forbidden.append("Process()")
            }
            for token in forbidden {
                let violatesBoundary = source.contains(token)
                #expect(!violatesBoundary, "Privacy boundary: \(file.lastPathComponent) contains \(token)")
            }
        }
    }
}
