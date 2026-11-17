import Foundation

/// 版本号（spec U-03）：去掉开头的 v，按数字逐段比较；带后缀（-beta 等）或解析不了的不认
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let pieces = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for p in pieces {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// 界面上显示的样子：v0.3.1
    var display: String { "v" + description }

    static var current: AppVersion { AppVersion(AppInfo.version) ?? AppVersion("0")! }
}

/// GitHub 上一个正式发布的信息（会存进设置，下次启动不联网也能提醒，spec U2-06）
struct ReleaseInfo: Codable, Equatable, Sendable {
    /// 规范化后的版本号，例如 0.3.1
    let version: String
    let tag: String
    /// 发布页正文（Markdown）
    let notes: String
    let pageURL: URL
    let published: Date?

    var appVersion: AppVersion? { AppVersion(version) }
}

/// 一次检查的结果
enum ReleaseCheckResult: Equatable, Sendable {
    case newer(ReleaseInfo)
    case upToDate
    case failed(String)
}

/// 发请求的方式（测试里换成假的，不联网）
protocol ReleaseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 真的联网：ephemeral 会话，不存 Cookie、不留缓存（spec U-01）
struct URLSessionTransport: ReleaseTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// 读取一览自己仓库最新的正式发布（技术方案 4.6）
enum ReleaseClient {
    /// 仓库地址只在这里出现一次
    static let repository = "paddychenc75/yilan"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// 请求头只有这三个：不带语言、系统版本、程序版本等任何信息（实测 URLSession 默认会带语言和系统版本）
    static func request(url: URL = latestURL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.httpShouldHandleCookies = false
        r.setValue("Yilan-Update-Check", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        return r
    }

    static func check(current: AppVersion, transport: ReleaseTransport) async -> ReleaseCheckResult {
        do {
            let (data, response) = try await transport.send(request())
            return interpret(status: response.statusCode, data: data, current: current)
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    private struct Payload: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// 解释服务器的回答（spec U-02 ~ U-04）
    static func interpret(status: Int, data: Data, current: AppVersion) -> ReleaseCheckResult {
        switch status {
        case 200: break
        case 404: return .upToDate                  // 还没有任何发布
        default: return .failed("HTTP \(status)")   // 403 限流等
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return .failed("JSON") }
        // 草稿、预发布不算；版本号认不出来也不算
        if p.draft == true || p.prerelease == true { return .upToDate }
        guard let version = AppVersion(p.tag_name), let url = URL(string: p.html_url),
              url.scheme == "https" || url.scheme == "http" else { return .upToDate }
        guard version > current else { return .upToDate }
        let date = p.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return .newer(ReleaseInfo(version: version.description, tag: p.tag_name, notes: p.body ?? "",
                                  pageURL: url, published: date))
    }
}
