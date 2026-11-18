import AppKit
import Observation
import UniformTypeIdentifiers

// 设置 › 文件格式：每个格式「默认用一览打开」（spec 19，D1–D6）。
// 系统按应用的 bundle id 记录打开方式（E-01、E-06），每改一个格式系统都会弹一次确认框（E-03），
// 用户在确认框里拒绝时返回 userCanceledErr（-128，E-04）。
// 系统接口抽成 HandlerSystem，测试和截图用假的，绝不改真实设置。

/// 一个应用：按 bundle id 认，路径只用来设置和取图标
struct AppRef: Equatable, Codable, Sendable {
    var bundleID: String
    var path: String
    var name: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// 读写「某个格式默认用哪个应用打开」
@MainActor
protocol HandlerSystem: AnyObject {
    func handler(for type: UTType) -> AppRef?
    /// 按 bundle id 找应用（找不到 = 已经删掉）
    func app(bundleID: String) -> AppRef?
    func setHandler(_ app: AppRef, for type: UTType) async throws
}

/// 真实的系统（NSWorkspace / Launch Services）
@MainActor
final class WorkspaceHandlerSystem: HandlerSystem {
    func handler(for type: UTType) -> AppRef? {
        NSWorkspace.shared.urlForApplication(toOpen: type).flatMap(Self.ref(for:))
    }

    func app(bundleID: String) -> AppRef? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(Self.ref(for:))
    }

    func setHandler(_ app: AppRef, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app.url, toOpen: type)
    }

    static func ref(for url: URL) -> AppRef? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return AppRef(bundleID: id, path: url.path, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}

/// 设置页里的一个格式（一行对应一个系统格式，PD-20）
enum HandlerFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heif, heic, webp, gif, svg, tiff, bmp
    case arw, cr2, cr3, nef, raf, rw2, orf, dng
    case mp4, m4v, mov

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case images, raw, videos
        var id: String { rawValue }
        var formats: [HandlerFormat] { HandlerFormat.allCases.filter { $0.group == self } }
        var title: String {
            switch self {
            case .images: String(localized: "图片", comment: "文件格式页的组名")
            case .raw: "RAW"
            case .videos: String(localized: "视频", comment: "文件格式页的组名")
            }
        }
        /// 不知道原来是谁时还原成它（D4、PD-19）
        var systemDefaultBundleID: String {
            self == .videos ? "com.apple.QuickTimePlayerX" : "com.apple.Preview"
        }
    }

    var id: String { rawValue }

    var group: Group {
        switch self {
        case .jpeg, .png, .heif, .heic, .webp, .gif, .svg, .tiff, .bmp: .images
        case .arw, .cr2, .cr3, .nef, .raf, .rw2, .orf, .dng: .raw
        case .mp4, .m4v, .mov: .videos
        }
    }

    /// 系统里的格式名（E-07：RAW 每家相机一个，奥林巴斯是 com.olympus.raw-image）
    var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heif: "public.heif"
        case .heic: "public.heic"
        case .webp: "org.webmproject.webp"
        case .gif: "com.compuserve.gif"
        case .svg: "public.svg-image"
        case .tiff: "public.tiff"
        case .bmp: "com.microsoft.bmp"
        case .arw: "com.sony.arw-raw-image"
        case .cr2: "com.canon.cr2-raw-image"
        case .cr3: "com.canon.cr3-raw-image"
        case .nef: "com.nikon.raw-image"
        case .raf: "com.fuji.raw-image"
        case .rw2: "com.panasonic.rw2-raw-image"
        case .orf: "com.olympus.raw-image"
        case .dng: "com.adobe.raw-image"
        case .mp4: "public.mpeg-4"
        case .m4v: "com.apple.m4v-video"
        case .mov: "com.apple.quicktime-movie"
        }
    }

    var type: UTType { UTType(typeIdentifier) ?? UTType(importedAs: typeIdentifier) }

    var name: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heif: "HEIF"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .gif: "GIF"
        case .svg: "SVG"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .arw: "ARW"
        case .cr2: "CR2"
        case .cr3: "CR3"
        case .nef: "NEF"
        case .raf: "RAF"
        case .rw2: "RW2"
        case .orf: "ORF"
        case .dng: "DNG"
        case .mp4: "MP4"
        case .m4v: "M4V"
        case .mov: "MOV"
        }
    }

    /// 名字后面的小字：扩展名，RAW 加品牌
    var detail: String {
        switch self {
        case .jpeg: ".jpg .jpeg"
        case .tiff: ".tif .tiff"
        case .arw: ".arw · " + String(localized: "索尼", comment: "相机品牌")
        case .cr2, .cr3: ".\(rawValue) · " + String(localized: "佳能", comment: "相机品牌")
        case .nef: ".nef · " + String(localized: "尼康", comment: "相机品牌")
        case .raf: ".raf · " + String(localized: "富士", comment: "相机品牌")
        case .rw2: ".rw2 · " + String(localized: "松下", comment: "相机品牌")
        case .orf: ".orf · " + String(localized: "奥林巴斯", comment: "相机品牌")
        default: "." + rawValue
        }
    }
}

/// 设置页的状态和操作（tech-design 11d）
@MainActor
@Observable
final class DefaultHandlers {
    /// 格子第二行的临时状态
    enum Note: Equatable {
        case justSet            // 绿色「已设为默认」约 3 秒
        case restored           // 「已还原 · 由 xx 打开」约 3 秒
        case unchanged          // 黄色「未改动 · 由 xx 打开」
        case busy               // 批量：正在设置
        case waiting            // 批量：等待中
    }

    struct Banner: Equatable {
        enum Kind { case warn, ok, progress }
        var kind: Kind
        var text: String
    }

    /// 一次要改好几个格式时先说明次数（PD-17）
    struct Plan: Equatable {
        var turnOn: Bool
        var formats: [HandlerFormat]
        var isAll: Bool
    }

    /// 关掉开关时让用户选：交还给之前的应用，还是交给系统默认
    struct RestoreChoice: Equatable {
        var format: HandlerFormat
        var previous: AppRef
        var systemDefault: AppRef
    }

    /// 一个格式改完的结果
    enum Outcome: Equatable {
        case changed
        case declined           // 用户在系统确认框里拒绝（-128）
        case failed
    }

    let selfApp: AppRef
    private let system: HandlerSystem
    private let store: UserDefaults
    static let previousKey = "defaultHandlerPrevious"

    /// 每个格式现在由谁打开（nil = 没有应用）；每次都从系统读（D2）
    private(set) var current: [HandlerFormat: AppRef] = [:]
    private(set) var notes: [HandlerFormat: Note] = [:]
    private(set) var banner: Banner?
    /// 正在等系统（确认框）时为 true，其他开关都不能拨
    private(set) var isBusy = false
    /// 等用户确认的批量操作
    var pendingPlan: Plan?
    /// 关掉一个开关时，之前的应用和系统默认不是同一个：先让用户选交给谁
    var pendingRestoreChoice: RestoreChoice?
    private var stopRequested = false
    private var noteTokens: [HandlerFormat: UUID] = [:]
    private var bannerToken = UUID()
    /// 临时状态停留的时间；测试设成 0 不等
    var noteSeconds: Double = 3
    var bannerSeconds: Double = 8

    init(system: HandlerSystem, store: UserDefaults, selfApp: AppRef) {
        self.system = system
        self.store = store
        self.selfApp = selfApp
        refresh()
    }

    static func live() -> DefaultHandlers {
        let me = WorkspaceHandlerSystem.ref(for: Bundle.main.bundleURL)
            ?? AppRef(bundleID: Bundle.main.bundleIdentifier ?? "com.yilan.viewer", path: Bundle.main.bundlePath, name: "Yilan")
        return DefaultHandlers(system: WorkspaceHandlerSystem(), store: .standard, selfApp: me)
    }

    // MARK: - 读

    func refresh() {
        var map: [HandlerFormat: AppRef] = [:]
        for format in HandlerFormat.allCases {
            if let app = system.handler(for: format.type) { map[format] = app }
        }
        current = map
    }

    /// 只按 bundle id 判断（E-06：本机可能装了好几份一览）
    func isYilan(_ format: HandlerFormat) -> Bool {
        current[format]?.bundleID == selfApp.bundleID
    }

    func onCount(_ group: HandlerFormat.Group) -> Int {
        group.formats.filter(isYilan).count
    }

    var anyOn: Bool { HandlerFormat.allCases.contains(where: isYilan) }
    var allOn: Bool { HandlerFormat.allCases.allSatisfy(isYilan) }

    /// 打开开关前记下的应用（只用于还原，DF-04）
    var previous: [String: AppRef] {
        get {
            guard let data = store.data(forKey: Self.previousKey) else { return [:] }
            return (try? JSONDecoder().decode([String: AppRef].self, from: data)) ?? [:]
        }
        set { store.set(try? JSONEncoder().encode(newValue), forKey: Self.previousKey) }
    }

    /// 关掉开关时设成谁：记下的应用还在就是它，否则系统默认（D4、DF-05）
    func restoreTarget(_ format: HandlerFormat) -> (app: AppRef, usedSystemDefault: Bool)? {
        if let prev = previous[format.typeIdentifier], prev.bundleID != selfApp.bundleID,
           let app = system.app(bundleID: prev.bundleID) {
            return (app, false)
        }
        return system.app(bundleID: format.group.systemDefaultBundleID).map { ($0, true) }
    }

    // MARK: - 单个开关

    func setSwitch(_ format: HandlerFormat, on: Bool) async {
        guard !isBusy, isYilan(format) != on else { return }
        clearBanner()
        // 之前的应用不一定是用户想要的（例如终端应用也声明能打开 SVG），和系统默认不同时让用户自己选
        if !on, let restore = restoreTarget(format), !restore.usedSystemDefault,
           let fallback = system.app(bundleID: format.group.systemDefaultBundleID),
           fallback.bundleID != restore.app.bundleID {
            pendingRestoreChoice = RestoreChoice(format: format, previous: restore.app, systemDefault: fallback)
            return
        }
        await perform(format, on: on, restoreTo: nil)
    }

    /// 用户在「交给谁」里选了一个应用；nil = 取消
    func chooseRestore(_ app: AppRef?) async {
        guard let choice = pendingRestoreChoice else { return }
        pendingRestoreChoice = nil
        guard let app, !isBusy, isYilan(choice.format) else { return }
        await perform(choice.format, on: false, restoreTo: app)
    }

    private func perform(_ format: HandlerFormat, on: Bool, restoreTo: AppRef?) async {
        isBusy = true
        defer { isBusy = false }
        let outcome = await apply(format, on: on, inBatch: false, restoreTo: restoreTo).outcome
        switch outcome {
        case .changed: break
        case .declined:
            show(.unchanged, for: format, temporary: false)
            showBanner(.init(kind: .warn, text: on
                ? String(localized: "\(format.name) 没有改动：你在系统确认框里选择了继续使用 \(appName(format))。")
                : String(localized: "\(format.name) 没有改动：你在系统确认框里选择了继续使用一览。")))
        case .failed:
            show(.unchanged, for: format, temporary: false)
            showBanner(.init(kind: .warn, text: String(localized: "macOS 没有接受这次更改，\(format.name) 仍由 \(appName(format)) 打开。请稍后再试。")))
        }
    }

    // MARK: - 组和全部（PD-17：先说明次数，用户同意后才开始）

    /// 组头复选框：空或混合 → 全开；全开 → 全关
    func requestGroup(_ group: HandlerFormat.Group) {
        let turnOn = onCount(group) < group.formats.count
        request(Plan(turnOn: turnOn, formats: group.formats.filter { isYilan($0) != turnOn }, isAll: false))
    }

    func requestAll(on: Bool) {
        request(Plan(turnOn: on, formats: HandlerFormat.allCases.filter { isYilan($0) != on }, isAll: true))
    }

    private func request(_ plan: Plan) {
        guard !isBusy, !plan.formats.isEmpty else { return }
        clearBanner()
        if plan.formats.count == 1 {
            Task { await setSwitch(plan.formats[0], on: plan.turnOn) }
        } else {
            pendingPlan = plan
        }
    }

    func cancelPlan() { pendingPlan = nil }

    /// 用户点「停止」：正在等的这个系统确认框处理完就停
    func stop() { stopRequested = true }

    /// 一个接一个改；用户拒绝一个就停下，剩下的不再弹框（PD-21、DF-08）
    func runPlan() async {
        guard let plan = pendingPlan, !isBusy else { return }
        pendingPlan = nil
        isBusy = true
        stopRequested = false
        defer { isBusy = false }
        for f in plan.formats { notes[f] = .waiting; noteTokens[f] = nil }
        var changed = 0, failed = 0, systemDefaults = 0
        var declined = false, userStopped = false
        for (index, format) in plan.formats.enumerated() {
            if stopRequested { userStopped = true; break }
            notes[format] = .busy
            banner = Banner(kind: .progress, text: String(localized: "正在设置 \(index + 1) / \(plan.formats.count)（\(format.name)）· 请在 macOS 弹出的对话框里选择"))
            let result = await apply(format, on: plan.turnOn, inBatch: true)
            switch result.outcome {
            case .changed:
                changed += 1
                if result.usedSystemDefault { systemDefaults += 1 }
            case .declined:
                notes[format] = .unchanged
                declined = true
            case .failed:
                notes[format] = .unchanged
                failed += 1
            }
            if declined { break }
        }
        // 没轮到的格式去掉「等待中」
        for f in plan.formats where notes[f] == .waiting { notes[f] = nil }
        let left = plan.formats.count - changed
        let text: String
        if declined {
            text = String(localized: "已改 \(changed) 种。你在系统确认框里选择了保留原来的应用，已停止，剩下 \(left) 种没有改。")
        } else if userStopped {
            text = String(localized: "已停止。已改 \(changed) 种，\(left) 种没有改。")
        } else if failed > 0 {
            text = String(localized: "已改 \(changed) 种，\(failed) 种 macOS 没有接受，仍由原来的应用打开。")
        } else if plan.turnOn {
            text = String(localized: "已把 \(changed) 种格式设为用一览打开。")
        } else if systemDefaults > 0 {
            text = String(localized: "已还原 \(changed) 种格式。其中 \(systemDefaults) 种不知道原来是谁，已恢复成系统默认（预览 / QuickTime Player）。")
        } else {
            text = String(localized: "已还原 \(changed) 种格式。")
        }
        showBanner(Banner(kind: !declined && !userStopped && failed == 0 ? .ok : .warn, text: text))
    }

    // MARK: - 改一个

    private func apply(_ format: HandlerFormat, on: Bool, inBatch: Bool, restoreTo: AppRef? = nil) async -> (outcome: Outcome, usedSystemDefault: Bool) {
        let target: AppRef
        var usedSystemDefault = false
        if on {
            // 记下原来的应用（已经是一览的不记；没有应用的不记，还原时用系统默认）
            if let now = current[format], now.bundleID != selfApp.bundleID {
                var map = previous
                map[format.typeIdentifier] = now
                previous = map
            }
            target = selfApp
        } else if let restoreTo {
            target = restoreTo
        } else {
            guard let restore = restoreTarget(format) else { return (.failed, false) }
            target = restore.app
            usedSystemDefault = restore.usedSystemDefault
        }
        let outcome: Outcome
        do {
            try await system.setHandler(target, for: format.type)
            outcome = .changed
        } catch {
            outcome = Self.isDeclined(error) ? .declined : .failed
            if outcome == .failed {
                Log.app.error("设置默认打开方式失败 \(format.typeIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
        if outcome == .changed {
            if !on {
                var map = previous
                map[format.typeIdentifier] = nil
                previous = map
            }
            show(on ? .justSet : .restored, for: format, temporary: true)
        }
        return (outcome, usedSystemDefault)
    }

    /// 用户在系统确认框里拒绝：-128，可能包在 NSCocoaErrorDomain 256 的 underlying 里（E-04）
    nonisolated static func isDeclined(_ error: Error) -> Bool {
        var err: NSError? = error as NSError
        while let e = err {
            if e.domain == NSOSStatusErrorDomain, e.code == userCanceledErr { return true }
            if e.domain == NSCocoaErrorDomain, e.code == NSUserCancelledError { return true }
            err = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: - 临时状态

    func appName(_ format: HandlerFormat) -> String {
        if isYilan(format) { return String(localized: "一览", comment: "应用名") }
        return current[format]?.name ?? String(localized: "没有应用", comment: "文件格式：这个格式没有应用能打开")
    }

    private func show(_ note: Note, for format: HandlerFormat, temporary: Bool) {
        notes[format] = note
        let token = UUID()
        noteTokens[format] = token
        guard temporary else { return }
        let seconds = noteSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.noteTokens[format] == token else { return }
            self.notes[format] = nil
        }
    }

    private func showBanner(_ value: Banner) {
        banner = value
        let token = UUID()
        bannerToken = token
        let seconds = bannerSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.bannerToken == token else { return }
            self.banner = nil
        }
    }

    /// 下次操作时说明条消失；格子里的「未改动」也清掉
    private func clearBanner() {
        banner = nil
        bannerToken = UUID()
        for (f, note) in notes where note == .unchanged { notes[f] = nil }
    }

    #if DEBUG
    /// 截图用：直接摆出说明条和格子状态
    func shotSet(banner: Banner?, notes: [HandlerFormat: Note], busy: Bool = false) {
        self.banner = banner
        self.notes = notes
        isBusy = busy
    }
    #endif
}

/// 假的系统：测试和截图用，只改内存里的表（绝不碰真实设置）
@MainActor
final class FakeHandlerSystem: HandlerSystem {
    var handlers: [String: AppRef]
    var installed: [String: AppRef]
    /// 对这些格式，假装用户在系统确认框里点了拒绝
    var declines: Set<String> = []
    /// 对这些格式，假装系统拒绝
    var failures: Set<String> = []
    private(set) var calls: [(bundleID: String, type: String)] = []

    init(handlers: [String: AppRef] = [:], installed: [AppRef] = []) {
        self.handlers = handlers
        self.installed = Dictionary(installed.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func handler(for type: UTType) -> AppRef? { handlers[type.identifier] }

    func app(bundleID: String) -> AppRef? { installed[bundleID] }

    func setHandler(_ app: AppRef, for type: UTType) async throws {
        calls.append((app.bundleID, type.identifier))
        if declines.contains(type.identifier) {
            throw NSError(domain: NSCocoaErrorDomain, code: 256,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: userCanceledErr)])
        }
        if failures.contains(type.identifier) {
            throw NSError(domain: NSOSStatusErrorDomain, code: -10814)
        }
        handlers[type.identifier] = app
    }
}
