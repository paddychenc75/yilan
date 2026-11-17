import AppKit
import Observation

/// 更新提醒的策略（spec 第 13 节）：什么时候联网、提醒、小点、稍后、跳过、手动检查
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker(settings: .shared, defaults: AppDefaults.store, transport: URLSessionTransport())

    /// 以后上架 App Store 时关掉：菜单项和设置组一起隐藏
    static let isAvailable = true

    enum Key {
        static let lastCheck = "update.lastCheck"
        static let skipped = "update.skippedVersion"
        static let cached = "update.cachedRelease"
    }

    /// 两次自动检查之间至少隔多久（spec U1-01）
    static let interval: TimeInterval = 24 * 60 * 60

    // MARK: 界面状态

    /// 有新版本、没被跳过（提示卡片、小点、菜单项、表单都用它）
    private(set) var available: ReleaseInfo?
    /// 顶部提示卡片
    var noticeVisible = false
    /// ⋯ 按钮上的小点和菜单第一项（关掉卡片后，spec U2-04）
    private(set) var dotVisible = false
    /// 正在显示的更新说明表单
    var sheetRelease: ReleaseInfo?
    /// 手动检查进行中
    private(set) var checking = false
    /// 上次成功检查的时间（设置 › 通用里显示）
    private(set) var lastCheck: Date?

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var transport: ReleaseTransport
    @ObservationIgnored var current: AppVersion
    @ObservationIgnored var now: () -> Date = Date.init
    /// 打开发布页（测试里换掉）
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 显示提示条（由 BrowserModel 接上）
    @ObservationIgnored var toast: (_ symbol: String, _ text: String, _ warning: Bool) -> Void = { _, _, _ in }

    init(settings: AppSettings, defaults: UserDefaults, transport: ReleaseTransport, current: AppVersion = .current) {
        self.settings = settings
        self.defaults = defaults
        self.transport = transport
        self.current = current
        let t = defaults.double(forKey: Key.lastCheck)
        lastCheck = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private var skippedVersion: String? {
        get { defaults.string(forKey: Key.skipped) }
        set { defaults.set(newValue, forKey: Key.skipped) }
    }

    private var cachedRelease: ReleaseInfo? {
        get { defaults.data(forKey: Key.cached).flatMap { try? JSONDecoder().decode(ReleaseInfo.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.cached) }
    }

    /// 保存的新版本仍然有效：比当前版本新、没被跳过
    private func remindable(_ release: ReleaseInfo?) -> ReleaseInfo? {
        guard let release, let v = release.appVersion, v > current, release.version != skippedVersion else { return nil }
        return release
    }

    // MARK: - 启动时

    /// 启动后自动检查（spec U1-01、U1-02、U2-03、U2-06）。
    /// deferNotice：这次启动已经显示了快捷键变化提示，新版本提醒顺延到下次启动
    func launchCheck(deferNotice: Bool) async {
        guard Self.isAvailable, settings.autoCheckUpdates else { return }
        let started = now()
        let due = lastCheck.map { now().timeIntervalSince($0) >= Self.interval } ?? true
        if due {
            let result = await ReleaseClient.check(current: current, transport: transport)
            record(result)
        }
        guard settings.autoCheckUpdates, let release = remindable(cachedRelease) else { return }
        available = release
        // 只在启动时出提示：联网太慢、结果来时已经在看照片了，就只留 ⋯ 上的小点，不打断浏览
        if deferNotice { return }
        if now().timeIntervalSince(started) > Self.launchWindow {
            dotVisible = true
            return
        }
        noticeVisible = true
        // 用户什么都不做：约 8 秒后自己收成 ⋯ 上的小点（同点 ×）
        let seconds = noticeSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.noticeVisible else { return }
            self.dismissNotice()
        }
    }

    /// 启动后多久之内拿到结果才弹提示
    static let launchWindow: TimeInterval = 10
    /// 提示停留多久自动收起；测试可以改短
    var noticeSeconds: Double = 8

    /// 记下一次成功的检查；失败什么都不改（下次启动再试）
    private func record(_ result: ReleaseCheckResult) {
        switch result {
        case .newer(let release):
            cachedRelease = release
            markChecked()
        case .upToDate:
            cachedRelease = nil
            markChecked()
        case .failed:
            break
        }
    }

    private func markChecked() {
        lastCheck = now()
        defaults.set(lastCheck!.timeIntervalSince1970, forKey: Key.lastCheck)
    }

    // MARK: - 手动检查（spec U6）

    func checkNow() async {
        guard !checking else { return }
        checking = true
        let result = await ReleaseClient.check(current: current, transport: transport)
        checking = false
        record(result)
        switch result {
        case .newer(let release):
            // 手动检查不受“跳过”影响（PD-10）
            available = release
            noticeVisible = false
            sheetRelease = release
        case .upToDate:
            toast("checkmark", String(localized: "已是最新版本（\(current.display)）", comment: "手动检查更新：%@ 是当前版本号"), false)
        case .failed:
            toast("exclamationmark.triangle", String(localized: "无法检查更新，请检查网络"), true)
        }
    }

    // MARK: - 用户操作

    /// 提示卡片上的 ×：留下小点和菜单项（spec U2-04）
    func dismissNotice() {
        noticeVisible = false
        dotVisible = available != nil
    }

    /// 打开更新说明（卡片按钮、⋯ 菜单、一览菜单）
    func showNotes() {
        guard let available else { return }
        noticeVisible = false
        sheetRelease = available
    }

    /// 稍后（或 Esc）：这次不再打扰，下次启动再提醒（spec U5-01）
    func later() {
        sheetRelease = nil
        noticeVisible = false
        dotVisible = false
    }

    /// 前往下载：打开发布页，视同稍后（spec U4-01、PD-16）
    func openDownload() {
        if let url = sheetRelease?.pageURL ?? available?.pageURL { openURL(url) }
        later()
    }

    /// 跳过这个版本（spec U5-02）
    func skip() {
        if let v = sheetRelease?.version ?? available?.version { skippedVersion = v }
        available = nil
        later()
    }

    /// 关掉自动检查：已保存的新版本也不再主动提醒（spec U7-03）
    func autoCheckChanged() {
        guard !settings.autoCheckUpdates else { return }
        noticeVisible = false
        dotVisible = false
    }

    #if DEBUG
    /// 截图用：直接摆出某个状态，不联网
    func applyForShots(release: ReleaseInfo, state: String) {
        available = release
        switch state {
        case "notice": noticeVisible = true
        case "dot": dotVisible = true
        case "sheet": sheetRelease = release
        case "checking": checking = true
        default: break
        }
    }
    #endif
}

/// 设置 › 通用里“上次检查”的写法（spec U7-02）：今天 / 昨天 + 时间，更早写日期
enum UpdateDateText {
    static func lastChecked(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return String(localized: "尚未检查") }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天 \(time)", comment: "上次检查时间；%@ 是时刻") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return String(localized: "昨天 \(time)", comment: "上次检查时间；%@ 是时刻")
        }
        return day(date)
    }

    /// 发布日期（spec U3-07）：yyyy-MM-dd，中英文相同
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
