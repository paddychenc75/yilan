import Foundation
import Testing
@testable import Yilan

// 更新提醒（spec 第 13 节）：全部用假的网络回答，不联网

/// 假的网络：按顺序返回事先准备好的回答，并记下请求
final class FakeTransport: ReleaseTransport, @unchecked Sendable {
    enum Reply { case http(Int, String), error(URLError.Code) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? Reply.error(.notConnectedToInternet) : replies.removeFirst()
        }
        switch reply {
        case .http(let status, let body):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), r)
        case .error(let code):
            throw URLError(code)
        }
    }
}

private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, body: String = "notes") -> String {
    let notes = (try? String(data: JSONEncoder().encode(body), encoding: .utf8)) ?? "\"\""
    return """
    {"tag_name":"\(tag)","name":"Yilan \(tag)","body":\(notes),"html_url":"https://github.com/paddychenc75/yilan/releases/tag/\(tag)",
     "published_at":"2026-11-24T08:00:00Z","draft":\(draft),"prerelease":\(prerelease),"assets":[]}
    """
}

@Suite("版本号和服务器回答")
struct ReleaseClientTests {
    let current = AppVersion("0.3.0")!

    @Test("逐段比较：0.10.0 新于 0.9.0；0.3 等于 0.3.0；带后缀的不认")
    func versions() {
        #expect(AppVersion("v0.10.0")! > AppVersion("0.9.0")!)
        #expect(AppVersion("0.3")! == AppVersion("0.3.0")!)
        #expect(AppVersion("v0.4.0-beta") == nil)
        #expect(AppVersion("abc") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("v0.3.1")!.display == "v0.3.1")
    }

    @Test("新版本、相同、更旧")
    func newerSameOlder() async {
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("v0.3.1"))]))
                    .isNewer(version: "0.3.1"))
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("v0.3.0"))])) == .upToDate)
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("v0.2.1"))])) == .upToDate)
    }

    @Test("草稿、预发布、认不出的版本号都不算新版本")
    func ignored() async {
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("v9.0.0", draft: true))])) == .upToDate)
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("v9.0.0", prerelease: true))])) == .upToDate)
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, release("nightly-2026"))])) == .upToDate)
    }

    @Test("404 视为已是最新；403、超时、JSON 坏了算失败")
    func failures() async {
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(404, "{}")])) == .upToDate)
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(403, "{}")])) == .failed("HTTP 403"))
        if case .failed = await ReleaseClient.check(current: current, transport: FakeTransport([.error(.timedOut)])) {} else {
            Issue.record("超时应该算失败")
        }
        #expect(await ReleaseClient.check(current: current, transport: FakeTransport([.http(200, "not json")])) == .failed("JSON"))
    }

    @Test("请求头不带语言、系统版本等信息（spec U-01）")
    func headers() async {
        let t = FakeTransport([.http(404, "{}")])
        _ = await ReleaseClient.check(current: current, transport: t)
        let r = t.requests[0]
        #expect(r.url == ReleaseClient.latestURL)
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "Yilan-Update-Check")
        #expect(r.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(r.allHTTPHeaderFields?.count == 3)
        #expect(!r.httpShouldHandleCookies)
    }
}

@Suite("更新说明取段和 Markdown")
struct ReleaseNotesTests {
    /// 仓库里的说明文件；scripts/run-tests.sh 会把它们镜像到 YILAN_DOCS_DIR（避开读桌面时等系统授权）
    private func file(_ relative: String) throws -> String {
        let root = ProcessInfo.processInfo.environment["YILAN_DOCS_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("固定格式：中文界面只要中文段，英文界面只要英文段，都不要安装段")
    func standardFormat() throws {
        let body = (try? file("changes/release-notes-template.md")) ?? Self.template
        let zh = ReleaseNotes.section(of: body, language: .simplifiedChinese)
        let en = ReleaseNotes.section(of: body, language: .english)
        #expect(zh.contains("### 新功能") && !zh.contains("### New") && !zh.contains("系统要求") && !zh.contains("## 中文"))
        #expect(en.contains("### New") && !en.contains("### 新功能") && !en.contains("Requirements"))
    }

    @Test("旧格式（v0.2.1，没有安装段）原样显示全文")
    func oldFormat() throws {
        let body = (try? file("dist/RELEASE_NOTES.md")) ?? "# 一览 Yilan v0.2.1\n\n## 中文\n\n修复\n\n## English\n\nFixes\n"
        #expect(ReleaseNotes.section(of: body, language: .simplifiedChinese) == body)
        #expect(ReleaseNotes.section(of: "随手写的说明", language: .english) == "随手写的说明")
    }

    @Test("块：标题、列表、段落；图片不加载，非 http 链接不放行")
    func blocks() {
        let b = ReleaseNotes.blocks("### 修复\n\n- **A**：b\n1. 第一\n普通一行\n接着一行\n\n![图](https://x/y.png)")
        #expect(b == [.heading(level: 3, text: "修复"), .bullet("**A**：b"), .ordered(1, "第一"),
                      .paragraph("普通一行 接着一行"), .paragraph("![图](https://x/y.png)")])
        #expect(String(ReleaseNotes.inline("![图](https://x/y.png)").characters).contains("!"))
        #expect(ReleaseNotes.isAllowedLink(URL(string: "https://github.com")!))
        #expect(!ReleaseNotes.isAllowedLink(URL(string: "file:///etc/passwd")!))
        #expect(!ReleaseNotes.isAllowedLink(URL(string: "javascript:alert(1)")!))
    }

    static let template = "## 中文\n\n### 新功能\n\n- a\n\n## English\n\n### New\n\n- a\n\n## 安装 / Install\n\n**Requirements**: macOS 26\n"
}

@Suite("更新提醒的策略", .serialized)
@MainActor
struct UpdatePolicyTests {
    private func make(_ replies: [FakeTransport.Reply], auto: Bool = true) -> (UpdateChecker, FakeTransport, UserDefaults) {
        let name = "yilan-update-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: d)
        settings.autoCheckUpdates = auto
        let t = FakeTransport(replies)
        let u = UpdateChecker(settings: settings, defaults: d, transport: t, current: AppVersion("0.3.0")!)
        u.openURL = { _ in }
        return (u, t, d)
    }

    @Test("发现新版本出提示；24 小时内再启动不联网但仍提醒（用保存的信息）")
    func remindAndThrottle() async {
        let (u, t, d) = make([.http(200, release("v0.3.1"))])
        await u.launchCheck(deferNotice: false)
        #expect(u.noticeVisible && u.available?.version == "0.3.1")
        #expect(t.count == 1)
        let again = UpdateChecker(settings: u.settings, defaults: d, transport: t, current: AppVersion("0.3.0")!)
        await again.launchCheck(deferNotice: false)
        #expect(t.count == 1)                                 // 没有再联网
        #expect(again.noticeVisible)
    }

    @Test("关掉自动检查：启动时不发请求，也不提醒")
    func autoOff() async {
        let (u, t, _) = make([.http(200, release("v0.3.1"))], auto: false)
        await u.launchCheck(deferNotice: false)
        #expect(t.count == 0)
        #expect(!u.noticeVisible)
    }

    @Test("断网：没有任何提示，下次启动再试")
    func offline() async {
        let (u, t, _) = make([.error(.notConnectedToInternet)])
        await u.launchCheck(deferNotice: false)
        #expect(!u.noticeVisible && u.available == nil && u.lastCheck == nil)
        #expect(t.count == 1)
    }

    @Test("快捷键提示同一次启动：新版本提醒顺延")
    func deferred() async {
        let (u, _, _) = make([.http(200, release("v0.3.1"))])
        await u.launchCheck(deferNotice: true)
        #expect(!u.noticeVisible)
        #expect(u.available != nil)
    }

    @Test("× 关闭留小点；稍后、前往下载都清掉小点；跳过后同一版本不再提醒，更高版本再提醒")
    func actions() async {
        let (u, t, d) = make([.http(200, release("v0.3.1"))])
        await u.launchCheck(deferNotice: false)
        u.dismissNotice()
        #expect(u.dotVisible && !u.noticeVisible)
        u.showNotes()
        #expect(u.sheetRelease?.version == "0.3.1")
        var opened: URL?
        u.openURL = { opened = $0 }
        u.openDownload()
        #expect(opened?.absoluteString.hasSuffix("/v0.3.1") == true)
        #expect(u.sheetRelease == nil && !u.dotVisible)
        u.showNotes()
        u.skip()
        // 跳过后：同一版本不提醒
        d.removeObject(forKey: UpdateChecker.Key.lastCheck)
        let t2 = FakeTransport([.http(200, release("v0.3.1")), .http(200, release("v0.3.2"))])
        let next = UpdateChecker(settings: u.settings, defaults: d, transport: t2, current: AppVersion("0.3.0")!)
        await next.launchCheck(deferNotice: false)
        #expect(!next.noticeVisible)
        d.removeObject(forKey: UpdateChecker.Key.lastCheck)   // 过了 24 小时
        let later = UpdateChecker(settings: u.settings, defaults: d, transport: t2, current: AppVersion("0.3.0")!)
        await later.launchCheck(deferNotice: false)
        #expect(later.noticeVisible && later.available?.version == "0.3.2")
        _ = t
    }

    @Test("手动检查：新版本直接打开说明（跳过的也打开）；最新、失败给提示条")
    func manual() async {
        let (u, _, d) = make([.http(200, release("v0.3.1")), .http(200, release("v0.3.0")), .error(.timedOut)])
        d.set("0.3.1", forKey: UpdateChecker.Key.skipped)
        var toasts: [String] = []
        u.toast = { _, text, _ in toasts.append(text) }
        await u.checkNow()
        #expect(u.sheetRelease?.version == "0.3.1")
        u.later()
        await u.checkNow()
        await u.checkNow()
        #expect(toasts == [String(localized: "已是最新版本（\(AppVersion("0.3.0")!.display)）", comment: "手动检查更新：%@ 是当前版本号"),
                           String(localized: "无法检查更新，请检查网络")])
        #expect(u.lastCheck != nil)
    }

    @Test("上次检查的写法")
    func dateText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateDateText.lastChecked(nil, now: now) == String(localized: "尚未检查"))
        #expect(UpdateDateText.lastChecked(now.addingTimeInterval(-60), now: now).contains(":"))
        #expect(UpdateDateText.day(Date(timeIntervalSince1970: 0)).count == 10)
    }
}

extension ReleaseCheckResult {
    func isNewer(version: String) -> Bool {
        if case .newer(let r) = self { return r.version == version }
        return false
    }
}
