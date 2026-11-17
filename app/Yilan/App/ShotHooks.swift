import Foundation

/// 截图用的启动参数（只在 Debug 版里生效，Release 里全部为空）。
/// 自动截图时一览不在最前面，收不到鼠标悬停，所以用参数直接摆出要截的状态：
/// `--shot-hover=0.62` 进度条固定在 62% 处显示时间气泡，并且控件不自动隐藏；
/// `--shot-drop=路径` 显示拖入遮罩（内容按这个路径算）；
/// `--shot-settings` 启动后打开设置窗口（`--shot-settings=general` 打开指定的页面）；
/// `--shot-info` 打开信息面板；
/// `--shot-delete=confirm` 显示删除确认框；`--shot-delete=after` 真的删除当前文件
///   （只对 /tmp 下的测试副本生效，移到 /tmp 下的假废纸篓，不进用户的废纸篓）；
/// `--shot-fullscreen=idle|top|bottom` 启动后进入全屏，并固定成静止 / 顶部 / 底部出现控件的样子；
/// `--shot-menus` 启动后把菜单栏的内容打印到标准输出（检查菜单项和快捷键）；
/// `--shot-window=1000x760` 启动后把窗口内容区改成这个大小（截窄窗口、中等宽度）；
/// `--shot-rating=4` 启动后给当前文件评 4 星（会写进 /tmp 下的测试副本）；`--shot-stars` 一直显示画面五星；
/// `--shot-hint=shortcuts|xmp` 显示提示卡片；`--shot-strip=hidden` 隐藏缩略图栏；
/// `--shot-seed-ratings` 给 /tmp 下的副本按固定规律评星；`--shot-filter=t:videos,r4,ru,f:jpeg+heic` 设筛选
/// （t: 类型，r4 不低于 4 星，ru 未评星，f: 格式）；`--shot-filter-panel` 打开筛选面板。
enum ShotHooks {
    #if DEBUG
    private static func value(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }
            .map { String($0.dropFirst(name.count + 3)) }
    }
    static let hoverFraction: Double? = value("shot-hover").flatMap(Double.init)
    static let dropPath: String? = value("shot-drop")
    static let settingsPane: String? = value("shot-settings")
    static let openSettings = CommandLine.arguments.contains("--shot-settings") || settingsPane != nil
    static let openInfo = CommandLine.arguments.contains("--shot-info")
    static let deleteState: String? = value("shot-delete")
    static let fullScreenState: String? = value("shot-fullscreen")
    static let dumpMenus = CommandLine.arguments.contains("--shot-menus")
    static let rating: Int? = value("shot-rating").flatMap(Int.init)
    static let showStars = CommandLine.arguments.contains("--shot-stars")
    static let hint: String? = value("shot-hint")
    static let stripHidden = value("shot-strip") == "hidden"
    static let seedRatings = CommandLine.arguments.contains("--shot-seed-ratings")
    /// `--shot-row-hover=4` 信息行里的星摆成鼠标停在第 4 颗的样子；`--shot-hold-flash` 闪现的胶囊一直显示
    static let rowHover: Int? = value("shot-row-hover").flatMap(Int.init)
    static let holdFlash = CommandLine.arguments.contains("--shot-hold-flash")
    /// `--shot-update=notice|dot|sheet|long|checking|uptodate|failed` 用内置的假数据摆出更新提醒的样子（不联网）
    static let update: String? = value("shot-update")
    /// `--shot-formats=fresh|some|group|mixed|justset|restored|declined|confirm|progress|restoreall`
    /// 文件格式页用假的系统接口摆出各个状态（绝不改真实的默认打开方式）
    static let formats: String? = value("shot-formats")
    static let filterSpec: String? = value("shot-filter")
    static let filterPanel = CommandLine.arguments.contains("--shot-filter-panel")
    static let windowSize: CGSize? = value("shot-window").flatMap { text in
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
    #else
    static let settingsPane: String? = nil
    static let hoverFraction: Double? = nil
    static let dropPath: String? = nil
    static let openSettings = false
    static let openInfo = false
    static let deleteState: String? = nil
    static let fullScreenState: String? = nil
    static let dumpMenus = false
    static let windowSize: CGSize? = nil
    static let rating: Int? = nil
    static let showStars = false
    static let hint: String? = nil
    static let stripHidden = false
    static let seedRatings = false
    static let rowHover: Int? = nil
    static let holdFlash = false
    static let update: String? = nil
    static let formats: String? = nil
    static let filterSpec: String? = nil
    static let filterPanel = false
    #endif

    /// 调试顶部栏收缩：环境变量 YILAN_LOG_TOPBAR=1 时把宽度和选中的档位打到标准输出
    static func logTopBar(width: CGFloat, widths: TopBarWidths, tier: TopBarTier) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["YILAN_LOG_TOPBAR"] != nil else { return }
        print("topbar w=\(width) \(widths) -> \(tier)")
        #endif
    }

    /// 截图时不让控件自动隐藏
    static var keepsChrome: Bool { hoverFraction != nil || openInfo || deleteState != nil || showStars }
    static var anyRatingShot: Bool {
        rating != nil || showStars || hint != nil || stripHidden || seedRatings || filterSpec != nil || filterPanel || update != nil
    }
}

extension ShotHooks {
    /// 截图时换成假的系统接口；平时返回 nil
    @MainActor
    static func formatsModel() -> DefaultHandlers? {
        #if DEBUG
        guard let state = formats else { return nil }
        return FormatsShot.make(state)
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// 文件格式页截图用的假数据
@MainActor
enum FormatsShot {
    static func app(_ id: String, _ path: String) -> AppRef {
        AppRef(bundleID: id, path: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
    }
    static let preview = app("com.apple.Preview", "/System/Applications/Preview.app")
    static let quickTime = app("com.apple.QuickTimePlayerX", "/System/Applications/QuickTime Player.app")
    static let safari = app("com.apple.Safari", "/Applications/Safari.app")
    static let captureOne = app("com.captureone.captureone16", "/Applications/Capture One.app")
    static let iina = app("com.colliderli.iina", "/Applications/IINA.app")

    static func make(_ state: String) -> DefaultHandlers {
        let me = WorkspaceHandlerSystem.ref(for: Bundle.main.bundleURL)
            ?? AppRef(bundleID: "com.yilan.viewer", path: Bundle.main.bundlePath, name: "Yilan")
        // 全新安装的样子：图片和 RAW 由预览打开，WebP、SVG 由 Safari，视频由 QuickTime
        var base: [HandlerFormat: AppRef] = [:]
        for f in HandlerFormat.allCases {
            base[f] = f.group == .videos ? quickTime : (f == .webp || f == .svg ? safari : preview)
        }
        if state != "fresh" {
            base[.png] = captureOne; base[.cr3] = captureOne; base[.dng] = captureOne; base[.mp4] = iina
        }
        var on: Set<HandlerFormat> = []
        switch state {
        case "fresh": break
        case "group": on = Set(HandlerFormat.Group.images.formats)
        case "mixed": on = [.jpeg, .heic, .heif, .arw, .mov]
        case "restored": on = [.jpeg, .heic, .mov, .png]
        case "restoreall": on = Set(HandlerFormat.allCases)
        default: on = [.jpeg, .heic, .mov]
        }
        var handlers: [String: AppRef] = [:]
        for f in HandlerFormat.allCases { handlers[f.typeIdentifier] = on.contains(f) ? me : base[f] }
        let system = FakeHandlerSystem(handlers: handlers, installed: [preview, quickTime, safari, captureOne, iina, me])
        let store = UserDefaults(suiteName: "yilan-shot-formats")!
        store.removePersistentDomain(forName: "yilan-shot-formats")
        // 之前记下的应用：PNG 原来是 Capture One；全部还原时有几种不知道原来是谁
        var previous: [String: AppRef] = [HandlerFormat.png.typeIdentifier: captureOne]
        if state == "restoreall" {
            for f in HandlerFormat.allCases where ![.heif, .bmp, .rw2, .m4v].contains(f) { previous[f.typeIdentifier] = base[f] }
        }
        store.set(try? JSONEncoder().encode(previous), forKey: DefaultHandlers.previousKey)
        let model = DefaultHandlers(system: system, store: store, selfApp: me)
        model.noteSeconds = 3600
        model.bannerSeconds = 3600
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            switch state {
            case "justset": await model.setSwitch(.png, on: true)
            case "restored": await model.setSwitch(.png, on: false)
            case "declined":
                system.declines = [HandlerFormat.png.typeIdentifier]
                await model.setSwitch(.png, on: true)
            case "confirm": model.requestAll(on: true)
            case "restoreall":
                model.requestAll(on: false)
                await model.runPlan()
            case "progress":
                let plan: [HandlerFormat] = HandlerFormat.allCases.filter { !model.isYilan($0) }
                var notes: [HandlerFormat: DefaultHandlers.Note] = [:]
                for (i, f) in plan.enumerated() { notes[f] = i < 3 ? nil : (i == 3 ? .busy : .waiting) }
                for f in plan.prefix(3) { system.handlers[f.typeIdentifier] = me }
                model.refresh()
                model.shotSet(banner: .init(kind: .progress, text: String(localized: "正在设置 \(4) / \(plan.count)（\(plan[3].name)）· 请在 macOS 弹出的对话框里选择")),
                              notes: notes, busy: true)
            default: break
            }
        }
        return model
    }
}
#endif
