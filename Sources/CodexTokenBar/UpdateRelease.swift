import Foundation
import CryptoKit

struct ReleaseVersion: Comparable, Sendable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count), components.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && Int($0) != nil
        }) else { return nil }
        parts = components.map { Int($0)! } + Array(repeating: 0, count: 3 - components.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct UpdateFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UpdateRelease: Sendable {
    static let repository = "zzzxtnt/codex-local-token-bar"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    let version: String
    let notes: String
    let dmgURL: URL
    let checksumURL: URL
    let size: Int

    static func parse(_ data: Data, currentVersion: String) throws -> Self? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int; let state: String }
        struct Release: Decodable {
            let tag_name: String; let body: String?; let draft: Bool; let prerelease: Bool; let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease,
              let version = ReleaseVersion(release.tag_name), let current = ReleaseVersion(currentVersion)
        else { throw UpdateFailure("版本信息不受支持，请到 GitHub 手动下载。") }
        guard version > current else { return nil }
        let numeric = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let name = "CodexTokenBar-v\(numeric)-universal.dmg"
        let dmgs = release.assets.filter { $0.name == name && $0.state == "uploaded" }
        let sums = release.assets.filter { $0.name == "SHA256SUMS.txt" && $0.state == "uploaded" }
        guard dmgs.count == 1, sums.count == 1, let dmg = dmgs.first, let sum = sums.first,
              (1...64 * 1024 * 1024).contains(dmg.size), (1...65536).contains(sum.size) else {
            throw UpdateFailure("新版尚无完整安装包或校验文件，请稍后重试。")
        }
        for asset in [dmg, sum] {
            let expected = "https://github.com/\(repository)/releases/download/\(release.tag_name)/\(asset.name)"
            guard asset.browser_download_url.absoluteString == expected else {
                throw UpdateFailure("下载地址不属于本项目，已拒绝更新。")
            }
        }
        return Self(version: numeric, notes: String((release.body ?? "暂无更新说明").prefix(8000)),
                    dmgURL: dmg.browser_download_url, checksumURL: sum.browser_download_url, size: dmg.size)
    }

    func verify(dmg: Data, checksums: Data) throws {
        guard dmg.count == size, let text = String(data: checksums, encoding: .utf8) else {
            throw UpdateFailure("下载文件大小不符，请重新下载。")
        }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]) == dmgURL.lastPathComponent else { return nil }
            return String(fields[0]).lowercased()
        }
        let actual = SHA256.hash(data: dmg).map { String(format: "%02x", $0) }.joined()
        guard matches.count == 1, matches[0] == actual else {
            throw UpdateFailure("安装包 SHA-256 校验失败，旧版未改动。")
        }
    }
}

/// Only this type performs HTTP. No session reader, account data or credentials enter it.
final class GitHubUpdateClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        switch url.host {
        case "api.github.com": return url.path == UpdateRelease.endpoint.path && url.query == nil
        case "github.com": return url.path.hasPrefix("/\(UpdateRelease.repository)/releases/download/")
        case "release-assets.githubusercontent.com", "objects.githubusercontent.com": return true
        default: return false
        }
    }

    func get(_ url: URL, limit: Int) async throws -> Data {
        guard Self.permits(url) else { throw UpdateFailure("更新地址被安全策略拒绝。") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("CodexTokenBar-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateFailure("GitHub 暂时不可用或请求受限，请稍后重试。")
        }
        guard response.expectedContentLength <= limit else { throw UpdateFailure("更新文件超出大小限制。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw UpdateFailure("更新文件超出大小限制。") }
            data.append(byte)
        }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.permits) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Let macOS validate TLS normally; never answer HTTP/client-certificate credential challenges.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
