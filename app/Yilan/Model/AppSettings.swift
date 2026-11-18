import Foundation
import Observation

/// 设置（设计稿 05 系统界面 · 设置）。全部存在 UserDefaults 里，界面和浏览逻辑共用一份
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings(defaults: AppDefaults.store)

    enum Key {
        static let loopVideo = "loopVideo"
        static let autoplayVideo = "autoplayVideo"
        static let rememberFilter = "rememberFilter"
        static let wrapAround = "wrapAround"
        static let reopenLastFolder = "reopenLastFolder"
        static let startFilter = "startFilter"
        static let autoHideControls = "autoHideControls"
        static let hideDelay = "hideDelay"
        static let ambientBackground = "ambientBackground"
        static let scrollZooms = "scrollZooms"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let autoAdvanceAfterRating = "autoAdvanceAfterRating"
        static let flashRatingOnStage = "flashRatingOnStage"
        static let autoCheckUpdates = "autoCheckUpdates"
        /// 2026-11-18 默认改成小文件：换了新键名，试用版里存的旧值（当时的默认是写入文件内部）不再沿用
        static let ratingStorage = "ratingStorageMode"
        static let lastLaunchedVersion = "lastLaunchedVersion"
        static let didShowSidecarHint = "didShowSidecarHint"
        /// 编辑 RAW 时存 JPEG 还是 HEIF（spec ED-33）
        static let editRawFormat = "editRawFormat"
    }

    /// 设置里“默认显示”的选项：沿用上次，或者固定一种
    enum StartFilter: String, CaseIterable, Identifiable {
        case last, all, images, videos
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .last: "上次的选择"
            case .all: "全部（图片和视频）"
            case .images: "只看图片"
            case .videos: "只看视频"
            }
        }
    }

    /// 隐藏延迟的范围（秒）
    static let hideDelayRange: ClosedRange<Double> = 1...10

    /// 视频播完后从头循环
    var loopVideo: Bool { didSet { defaults.set(loopVideo, forKey: Key.loopVideo) } }
    /// 切到视频时自动播放（PRD：默认停在第一帧）
    var autoplayVideo: Bool { didSet { defaults.set(autoplayVideo, forKey: Key.autoplayVideo) } }
    /// 启动时的“全部 / 图片 / 视频”（旧版的“记住上次的类型”开关并进了这里）
    var startFilter: StartFilter { didSet { defaults.set(startFilter.rawValue, forKey: Key.startFilter) } }
    /// 启动时打开上次的文件夹（否则显示欢迎界面）
    var reopenLastFolder: Bool { didSet { defaults.set(reopenLastFolder, forKey: Key.reopenLastFolder) } }
    /// 鼠标静止一段时间后隐藏控件
    var autoHideControls: Bool { didSet { defaults.set(autoHideControls, forKey: Key.autoHideControls) } }
    /// 隐藏延迟（秒）
    var hideDelay: Double { didSet { defaults.set(hideDelay, forKey: Key.hideDelay) } }
    /// 用当前图片的颜色铺满窗口背景
    var ambientBackground: Bool { didSet { defaults.set(ambientBackground, forKey: Key.ambientBackground) } }
    /// 鼠标滚轮直接缩放（按住 ⌃ 时切换图片）；关闭时反过来
    var scrollZooms: Bool { didSet { defaults.set(scrollZooms, forKey: Key.scrollZooms) } }
    /// 到达最后一个时循环到第一个（PRD：默认停住）
    var wrapAround: Bool { didSet { defaults.set(wrapAround, forKey: Key.wrapAround) } }
    /// 移到废纸篓前先确认（确认框里勾选“不再询问”会关掉它）
    var confirmBeforeDelete: Bool { didSet { defaults.set(confirmBeforeDelete, forKey: Key.confirmBeforeDelete) } }

    /// 打星后自动跳到下一张（spec R8，默认关）
    var autoAdvanceAfterRating: Bool { didSet { defaults.set(autoAdvanceAfterRating, forKey: Key.autoAdvanceAfterRating) } }
    /// 自动检查更新（spec U7，默认开）
    var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) } }
    /// 评星时在画面上闪现星级（spec R3a，默认开）
    var flashRatingOnStage: Bool { didSet { defaults.set(flashRatingOnStage, forKey: Key.flashRatingOnStage) } }
    /// 星级保存到哪里（spec S-02）
    var ratingStorage: RatingStorageMode { didSet { defaults.set(ratingStorage.rawValue, forKey: Key.ratingStorage) } }
    /// 第一次为 RAW 创建 .xmp 的提示已经出现过（spec S-17）
    var didShowSidecarHint: Bool { didSet { defaults.set(didShowSidecarHint, forKey: Key.didShowSidecarHint) } }
    var editRawFormat: RawExportFormat { didSet { defaults.set(editRawFormat.rawValue, forKey: Key.editRawFormat) } }

    @ObservationIgnored private let defaults: UserDefaults
    /// 设置存放的域名（判断“以前用过一览”时只看这个域，不看全局域）
    @ObservationIgnored private let domainName: String?

    init(defaults: UserDefaults, domainName: String? = nil) {
        self.defaults = defaults
        self.domainName = domainName
        defaults.register(defaults: [
            Key.loopVideo: false,
            Key.autoplayVideo: false,
            Key.rememberFilter: true,
            Key.wrapAround: false,
            Key.reopenLastFolder: true,
            Key.autoHideControls: false,  // 默认不自动隐藏控件（用户反馈：按钮自己消失不顺手）
            Key.hideDelay: 2.0,
            Key.ambientBackground: true,
            Key.scrollZooms: false,
            Key.confirmBeforeDelete: true,
            Key.autoAdvanceAfterRating: false,
            Key.flashRatingOnStage: true,
            Key.autoCheckUpdates: true,
            Key.didShowSidecarHint: false,
        ])
        loopVideo = defaults.bool(forKey: Key.loopVideo)
        autoplayVideo = defaults.bool(forKey: Key.autoplayVideo)
        // 旧版存的是“记住上次的类型”开关
        if let raw = defaults.string(forKey: Key.startFilter), let value = StartFilter(rawValue: raw) {
            startFilter = value
        } else {
            startFilter = defaults.bool(forKey: Key.rememberFilter) ? .last : .all
        }
        reopenLastFolder = defaults.bool(forKey: Key.reopenLastFolder)
        autoHideControls = defaults.bool(forKey: Key.autoHideControls)
        hideDelay = min(max(defaults.double(forKey: Key.hideDelay), Self.hideDelayRange.lowerBound), Self.hideDelayRange.upperBound)
        ambientBackground = defaults.bool(forKey: Key.ambientBackground)
        scrollZooms = defaults.bool(forKey: Key.scrollZooms)
        wrapAround = defaults.bool(forKey: Key.wrapAround)
        confirmBeforeDelete = defaults.bool(forKey: Key.confirmBeforeDelete)
        autoAdvanceAfterRating = defaults.bool(forKey: Key.autoAdvanceAfterRating)
        flashRatingOnStage = defaults.bool(forKey: Key.flashRatingOnStage)
        autoCheckUpdates = defaults.bool(forKey: Key.autoCheckUpdates)
        ratingStorage = defaults.string(forKey: Key.ratingStorage).flatMap(RatingStorageMode.init(rawValue:)) ?? .sidecar
        didShowSidecarHint = defaults.bool(forKey: Key.didShowSidecarHint)
        editRawFormat = defaults.string(forKey: Key.editRawFormat).flatMap(RawExportFormat.init(rawValue:)) ?? .jpeg
    }

    /// 从 v0.2 升级后第一次启动（spec K-10）：以前用过（存过任何设置或最近打开）、但没记过版本号。
    /// 调用一次后记下当前版本，之后都返回 false
    func consumeUpgradeFromV02(currentVersion: String) -> Bool {
        let previous = defaults.string(forKey: Key.lastLaunchedVersion)
        defaults.set(currentVersion, forKey: Key.lastLaunchedVersion)
        guard previous == nil else { return false }
        let domain = defaults.persistentDomain(forName: domainName ?? AppDefaults.domainName) ?? [:]
        let usedBefore = [MediaFilter.defaultsKey, Key.startFilter, Key.wrapAround, Key.autoHideControls,
                          Key.confirmBeforeDelete, Key.scrollZooms, RecentFolders.defaultsKey]
            .contains { domain[$0] != nil }
        return usedBefore
    }

    /// 启动时的类型
    func initialFilter() -> MediaFilter {
        switch startFilter {
        case .last: defaults.string(forKey: MediaFilter.defaultsKey).flatMap(MediaFilter.init(rawValue:)) ?? .all
        case .all: .all
        case .images: .images
        case .videos: .videos
        }
    }

    /// 滚轮这一下是缩放还是切换（按住 ⌃ 或 ⌘ 时反过来）
    func scrollShouldZoom(modifierPressed: Bool) -> Bool {
        scrollZooms != modifierPressed
    }

    func saveFilter(_ filter: MediaFilter) {
        defaults.set(filter.rawValue, forKey: MediaFilter.defaultsKey)
    }
}

/// 设置和最近打开存放的位置。
/// 测试和截图时可以用启动参数 `--defaults-suite=名字` 换一个独立的存储，不影响真实数据
@MainActor
enum AppDefaults {
    /// 设置所在的域：默认是程序自己的域，`--defaults-suite=` 时是那个套件
    static let domainName: String = {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--defaults-suite=") }),
           let name = arg.split(separator: "=", maxSplits: 1).last.map(String.init), !name.isEmpty { return name }
        return Bundle.main.bundleIdentifier ?? "com.yilan.viewer"
    }()

    static let store: UserDefaults = {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--defaults-suite=") }),
              let name = arg.split(separator: "=", maxSplits: 1).last.map(String.init), !name.isEmpty,
              let suite = UserDefaults(suiteName: name) else { return .standard }
        return suite
    }()
}

/// 上下切换的目标位置（到头停住，或者循环）
enum Navigation {
    static func target(from index: Int, delta: Int, count: Int, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        let next = index + delta
        if (0..<count).contains(next) { return next }
        guard wrap, count > 1 else { return nil }
        return (next % count + count) % count
    }
}
