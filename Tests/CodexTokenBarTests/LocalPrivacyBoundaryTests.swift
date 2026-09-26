import Foundation
import Testing

struct LocalPrivacyBoundaryTests {
    @Test func applicationHasNoNetworkOrCredentialReader() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexTokenBar")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "auth.json", "access_token", "refresh_token",
                              "SecItemCopyMatching", "import Network", "import Security", "Process()"] {
                let violatesBoundary = source.contains(forbidden)
                #expect(!violatesBoundary, "Privacy boundary: \(file.lastPathComponent) contains \(forbidden)")
            }
        }
    }
}
