import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// 缩放指令：界面（菜单、快捷键）发给大图区
struct ZoomCommand: Equatable {
    enum Action: Equatable { case fit, actualSize, percent200, zoomIn, zoomOut, toggle }
    let action: Action
    let serial: Int
}

/// 大图区报告的缩放状态（顶部缩放控件用）
struct ZoomState: Equatable {
    /// 实际比例（100 = 1 像素对应 1 点），适应窗口时也有值
    var percent: Int
    var isFit: Bool
    /// 还能放大（没到 3200%）
    var canZoomIn: Bool
    /// 还能缩小（不是适应窗口）
    var canZoomOut: Bool
}

/// 顶部提示条：切换类型、删除、文件夹变化等
struct Toast: Equatable {
    let symbol: String
    let text: String
    /// 圆点后面的补充说明（例如“已显示下一个”）
    var detail: String? = nil
    /// 点了补充说明要做的事；有它时补充说明显示成蓝色可点的链接（“⌘Z 撤销”）
    var action: ToastAction? = nil
    var tone: ToastTone = .normal
    /// 深色实底（v0.3 新提示：亮照片上也看得清，同更新提醒）
    var solid = false
    /// 显示在底部缩略图栏上方（编辑保存后的提示，设计稿 edit 08），撤销做成胶囊按钮
    var bottom = false
    let serial: Int
}

enum ToastAction: Equatable {
    case undoDelete
    /// 撤销编辑保存（另存副本、替换原图、保存旋转）
    case undoEdit
}

/// 提示条的图标颜色：普通白色，警告黄色（设计稿“无法保存星级”）
enum ToastTone: Equatable {
    case normal
    case warning
}

/// 浏览状态：当前文件夹、类型切换、当前项、大图加载、控件显示
@MainActor
@Observable
final class BrowserModel {
    static let shared = BrowserModel()

    // MARK: 文件夹

    private(set) var folderURL: URL?
    private(set) var allItems: [MediaItem] = []
    /// 当前类型下的列表；缩略图栏、序号、上下切换都只针对它
    internal(set) var items: [MediaItem] = []
    private(set) var filter: MediaFilter
    internal(set) var currentIndex: Int?
    private(set) var counts: [MediaFilter: Int] = [.all: 0, .images: 0, .videos: 0]
    private(set) var hasOpenedFolder = false
    private(set) var openError: String?

    var current: MediaItem? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    var isFirst: Bool { currentIndex == 0 }
    var isLast: Bool { currentIndex.map { $0 >= items.count - 1 } ?? true }
    /// 箭头是否可用：设置里打开“循环到第一个”后，两头也可以继续切
    var canGoPrevious: Bool { currentIndex.flatMap { Navigation.target(from: $0, delta: -1, count: items.count, wrap: settings.wrapAround) } != nil }
    var canGoNext: Bool { currentIndex.flatMap { Navigation.target(from: $0, delta: 1, count: items.count, wrap: settings.wrapAround) } != nil }

    // MARK: 大图

    private(set) var displayed: DecodedImage?
    private(set) var displayedItem: MediaItem?
    /// 大图还没解码好时先显示缩略图
    private(set) var placeholder: CGImage?
    /// displayed 是这个文件在原地被改写（保存旋转、替换原图、撤销它们、被其他程序改动）之前的画面：
    /// 新内容解码好之前继续显示它，不清空成模糊的占位图
    private(set) var showingStaleDisplay = false
    /// 旧画面要额外转几下才和改写后的样子一致（保存旋转前浏览时转的方向）
    private(set) var heldTurns = 0
    private(set) var failure: DecodeFailure?
    /// RAW：内嵌预览已显示，正在后台完整解码
    private(set) var isDecodingRaw = false
    private(set) var ambient: CGImage?
    private(set) var ambientItemURL: URL?

    // MARK: 界面

    var stripVisible = true
    private(set) var chromeVisible = true
    private(set) var zoomCommand: ZoomCommand?
    /// 当前缩放状态；没有图片时为 nil
    var zoomState: ZoomState?
    private(set) var toast: Toast?
    /// 当前文件的显示旋转（顺时针 90° 的倍数，只影响显示，不改文件）；切换文件后复位
    internal(set) var rotation = 0
    /// 大图实际要转的方向：显示旋转，加上改写前旧画面暂时保留的方向
    var stageRotation: Int { (rotation + heldTurns) % 4 }
    /// 当前显示的画面按显示方向的像素尺寸（旧画面暂留时按改写后的方向）
    var displayedPixelSize: CGSize? {
        guard let s = displayed?.pixelSize else { return nil }
        return heldTurns % 2 == 1 ? CGSize(width: s.height, height: s.width) : s
    }

    // MARK: 编辑（BrowserModel+Edit）

    /// 正在编辑（spec 21）；nil 表示在浏览
    var edit: EditSession?
    /// 「保存旋转」胶囊的箭头菜单打开（spec ED-41）
    var rotationMenuOpen = false
    /// 鼠标停在提示条上：提示条不消失（设计稿 edit「提示条」）
    @ObservationIgnored var toastHovered = false

    // MARK: 视频、设置、最近打开

    let settings: AppSettings
    let recents: RecentFolders
    /// 播放器自己是 @Observable，界面直接观察它的播放状态
    @ObservationIgnored let video: VideoPlayerController

    @ObservationIgnored private let pipeline: ImagePipeline
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var fullResTask: Task<Void, Never>?
    @ObservationIgnored private var ambientTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// 自动隐藏的时间点：鼠标一直在动时只往后推，不每次都新建计时任务
    @ObservationIgnored private var hideDeadline = ContinuousClock.now
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hoveredControls: Set<String> = []
    @ObservationIgnored var serial = 0
    @ObservationIgnored private let ambientCache = NSCache<NSURL, CGImageBox>()
    /// 大图区所在屏幕的长边物理像素（由大图区报告；没报告前按当前屏幕估算）
    @ObservationIgnored var screenMaxPixel: Int?
    /// 播放器报告放不了的视频：它的静帧解码好了也不显示，保持出错卡片
    @ObservationIgnored private var unplayable: MediaItem?
    /// 每次加载当前项加 1：排队解码时，新的一轮排在旧的前面
    @ObservationIgnored private var loadGeneration = 0
    /// 最近一次翻页的方向（1 = 往后，-1 = 往前）：RAW 的高清版只往这个方向预加载
    @ObservationIgnored private(set) var browseDirection = 1

    // MARK: 信息面板（BrowserModel+Info）

    /// 面板开着时切换文件也保持打开
    var infoVisible = false
    var info: InfoContent?
    @ObservationIgnored var infoTask: Task<Void, Never>?
    @ObservationIgnored var metadataCache: [String: MediaMetadata] = [:]

    // MARK: 删除到废纸篓（BrowserModel+Trash）

    /// 等待确认删除的文件（显示确认对话框）
    var pendingDelete: MediaItem?
    /// 确认对话框里“不再询问”的勾选
    var deleteDontAsk = false
    var undoHistory = UndoHistory() {
        // 撤销记录里去掉的保存旋转（换文件夹、超过 100 条）：它的原文件副本删掉（F2-03）
        didSet { discardDroppedBackups(old: oldValue) }
    }
    /// 正在撤销的那条保存旋转的副本：记录先去掉、副本用完再删
    @ObservationIgnored var backupInUse: RotationBackup?
    /// 一览自己改动文件夹（删除、撤销）的次数：文件夹同步据此丢弃过期的扫描结果
    @ObservationIgnored var localChangeSerial = 0
    /// 正在移到废纸篓或放回：期间再按 ⌫ / ⌘Z 不重复执行
    @ObservationIgnored var trashBusy = false

    // MARK: 文件夹变化同步（BrowserModel+Sync）

    /// 刚新增的文件：缩略图高亮 2 秒
    var freshURLs: Set<URL> = []
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var freshTask: Task<Void, Never>?

    // MARK: 筛选（BrowserModel+Filter）

    /// 星级、格式筛选（只对当前窗口，换文件夹清空，spec F-06）
    var browseFilter = BrowseFilter()
    var filterPanelOpen = false
    /// 暂留：当前文件已经不符合条件，但留在结果里直到切走（spec F-01）
    @ObservationIgnored var stickyURL: URL?
    /// 结果变空前最后在看的文件：清除或放宽筛选后回到它（spec F1-03）
    @ObservationIgnored var emptyResultAnchor: MediaItem?

    // MARK: 评星（BrowserModel+Rating）

    /// 已经读出来的星级（0 = 未评星）；没有的键表示还没读到
    var ratings: [URL: Int] = [:]
    /// 星级全部读完了
    var ratingsLoaded = false
    /// 当前文件夹能不能写（只读磁盘、写保护卡时 false，spec S-16）
    var folderWritable = true
    /// 按 0–5 时的闪现（spec R1-05）
    var ratingFlash: RatingFlash?
    /// 顶部提示卡片（快捷键变化、.xmp 说明），一次只显示一个（spec U2-03）
    var hint: HintCard?
    @ObservationIgnored var hintQueue: [HintCard] = []
    /// 这次启动显示了快捷键变化提示（新版本提醒顺延，spec U2-03）
    @ObservationIgnored var upgradeNoticeShown = false
    @ObservationIgnored var ratingInfo: [URL: RatingInfo] = [:]
    /// 磁盘上已经确认的星级（写失败时界面恢复成它）
    @ObservationIgnored var persistedRatings: [URL: Int] = [:]
    /// 每个文件还没写完的评星记录条数（写失败时从撤销记录里拿掉）
    @ObservationIgnored var unconfirmedRatingEntries: [URL: Int] = [:]
    @ObservationIgnored var pendingRatingWrites = 0
    @ObservationIgnored var inFlightRatingWrites: [URL: Int] = [:]
    @ObservationIgnored var sidecars: SidecarIndex = .empty
    @ObservationIgnored let ratingWriter = RatingWriter()
    @ObservationIgnored var ownWrites = OwnWriteLedger()
    @ObservationIgnored var ratingLoadTask: Task<Void, Never>?
    @ObservationIgnored var flashTask: Task<Void, Never>?
    /// 同一种写入失败 10 秒内不重复提示（spec S-14）
    @ObservationIgnored var lastWriteFailure: (error: RatingWriteError, at: Date)?
    @ObservationIgnored var hoveringVideoBar = false

    // MARK: 全屏（BrowserModel+FullScreen）

    var isFullScreen = false
    /// 全屏时鼠标碰到顶边：标题栏控件和菜单栏一起出现
    var fullScreenTopRevealed = false
    /// 全屏时鼠标在底部 120 点内：缩略图栏滑入
    var fullScreenBottomRevealed = false
    /// 全屏时鼠标在动：左右箭头淡入，静止 2 秒淡出
    var fullScreenArrowsVisible = false
    @ObservationIgnored var fullScreenBottomTask: Task<Void, Never>?
    @ObservationIgnored var fullScreenIdleTask: Task<Void, Never>?
    @ObservationIgnored var fullScreenHoveringDock = false
    /// 主窗口是否是键盘焦点窗口（设置窗口在前面时，菜单里的单键快捷键不能删文件）
    var mainWindowIsKey = true
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var windowObservers: [NSObjectProtocol] = []

    init(settings: AppSettings = .shared, recents: RecentFolders = .shared, pipeline: ImagePipeline = .shared) {
        self.settings = settings
        self.recents = recents
        self.pipeline = pipeline
        video = VideoPlayerController(
            loopAtEnd: { settings.loopVideo },
            autoplay: { settings.autoplayVideo }
        )
        filter = settings.initialFilter()
        ambientCache.countLimit = 200
        video.onPlaybackFailed = { [weak self] item, message in self?.videoPlaybackFailed(item, message: message) }
    }

    // MARK: - 打开

    /// 启动时：设置里选了“打开上次的文件夹”，并且没有从访达等处打开文件时，打开最近一个还在的文件夹
    func reopenLastFolderIfNeeded() {
        // 跑单元测试时一览是宿主程序：不去打开用户真实的文件夹
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !underTests, settings.reopenLastFolder, !openRequested else { return }
        // 文件夹、封面是否还在都在后台检查（可能在断开的移动硬盘或网络盘上，不能卡住主线程）
        Task {
            await recents.refreshAvailability()
            guard !openRequested, let last = recents.existing(limit: 1).first else { return }
            let cover = last.coverPath
            let coverExists = await Task.detached(priority: .userInitiated) {
                cover.map { FileManager.default.fileExists(atPath: $0) } ?? false
            }.value
            guard !openRequested else { return }
            // 有封面（上次停留的文件）就从那个文件开始
            open(coverExists ? URL(fileURLWithPath: cover ?? last.path) : last.url)
        }
    }

    /// 已经要求打开过文件（启动时用来判断要不要自动打开上次的文件夹）
    private(set) var openRequested = false

    func open(_ url: URL) {
        openRequested = true
        scanTask?.cancel()
        openError = nil
        saveRecentCover()
        Perf.mark("open")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let pipeline = self.pipeline
        scanTask = Task {
            // 重新打开文件夹：之前记住的“打不开”可能已经过时（文件被修好或换掉）
            await pipeline.clearFailures()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FolderScanner.open(url) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let r):
                // 换了文件夹：之前的删除不能再撤销（文件夹已经不在眼前）
                if r.folder.standardizedFileURL.path != folderURL?.standardizedFileURL.path { undoHistory.removeAll() }
                apply(r)
                if !r.folderUnreadable {
                    recents.record(folder: r.folder, cover: current?.url, itemCount: r.items.count)
                    startWatching(r.folder)
                } else {
                    stopWatching()
                }
                if r.folderUnreadable {
                    openError = String(localized: "没有权限读取“\(r.folder.lastPathComponent)”文件夹，只显示这一个文件。可在 系统设置 › 隐私与安全性 › 文件与文件夹 中允许一览访问。",
                                       comment: "打开文件时读不到所在文件夹；%@ 是文件夹名")
                }
            case .failure(let error):
                Log.app.error("打开失败 \(error.localizedDescription, privacy: .public)")
                openError = String(localized: "无法打开：\(error.localizedDescription)", comment: "%@ 是系统给出的错误说明")
            }
        }
    }

    /// 显示扫描结果（测试里直接调用，绕过文件扫描）
    func apply(_ result: FolderScanner.Result) {
        Perf.mark("folder scanned")
        if result.folder.standardizedFileURL.path != folderURL?.standardizedFileURL.path {
            resetRatings()
            resetBrowseFilter()
        }
        folderURL = result.folder
        allItems = result.items
        sidecars = result.sidecars
        folderWritable = SafeReplace.isWritable(folder: result.folder)
        hasOpenedFolder = true
        recount()
        let opened = result.initialIndex.map { result.items[$0] }
        // 记住的类型里没有内容，或者打开的文件不属于这个类型时，回到“全部”
        if counts[filter] == 0 || (opened.map { !filter.includes($0) } ?? false) {
            filter = .all
        }
        items = resultList()
        displayed = nil
        displayedItem = nil
        let index = FilterSelection.index(keeping: opened, in: allItems, newList: items)
        select(index)
        loadRatings()
    }

    /// 按 allItems 重新数“全部 / 图片 / 视频”
    func recount() {
        counts = [
            .all: allItems.count,
            .images: allItems.lazy.filter { $0.kind == .image }.count,
            .videos: allItems.lazy.filter { $0.kind == .video }.count,
        ]
    }

    /// 文件夹内容变了（删除、撤销、外部增删）：换成新的列表，并显示 target
    /// （target 不在当前类型里时回到“全部”）。当前项没变时不重新加载
    func replaceItems(_ newAll: [MediaItem], showing target: MediaItem?) {
        let previous = current
        allItems = newAll
        recount()
        if let target, !filter.includes(target) { filter = .all }
        if counts[filter] == 0 { filter = .all }
        // 筛选中放回来的文件不符合条件：暂留显示（spec F-09）
        if let target, browseFilter.isActive, !matchesBrowseFilter(target) { stickyURL = target.url }
        items = resultList()
        let index = target.flatMap { t in items.firstIndex(of: t) }
        if let index, items[index] == previous {
            currentIndex = index   // 同一个文件，只是位置变了：不重新加载
        } else {
            select(index)
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SupportedFormats.allExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = String(localized: "选择一张图片、一个视频或一个文件夹")
        panel.prompt = String(localized: "打开", comment: "打开面板的确认按钮")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    // MARK: - 类型切换

    func setFilter(_ newFilter: MediaFilter) {
        guard newFilter != filter, (filteredCounts[newFilter] ?? 0) > 0, pendingDelete == nil, edit == nil else { return }
        let previous = current
        filter = newFilter
        settings.saveFilter(newFilter)
        // 切换类型时，属于另一类的已选格式自动取消（spec R5b-07）
        if newFilter != .all {
            let keep: MediaKind = newFilter == .videos ? .video : .image
            browseFilter.format.selected = browseFilter.format.selected.filter { $0.kind == keep }
        }
        // 视频没有星级：切到“视频”时星级条件一并清掉
        if newFilter == .videos { browseFilter.rating = RatingCriterion() }
        stickyURL = nil
        items = resultList()
        let index = browseFilter.isActive
            ? FilterSelection.indexAfterFilterChange(keeping: previous, in: allItems, newList: items)
            : FilterSelection.index(keeping: previous, in: allItems, newList: items)
        showToast(symbol: newFilter.symbol, text: newFilter.toastText(count: items.count))
        if items[safe: index] == previous {
            currentIndex = index   // 当前文件还在，原地不动，不需要重新加载
        } else {
            select(index)
        }
    }

    // MARK: - 切换

    func select(_ index: Int?) {
        var index = index
        // 从暂留的文件切走：它这时才从结果里消失，序号和总数随之更新（spec F-01）
        if let sticky = stickyURL, let i = index, items.indices.contains(i), items[i].url != sticky {
            let target = items[i]
            stickyURL = nil
            items = resultList()
            index = items.firstIndex(of: target)
            if let previous = current, items.firstIndex(of: previous) == nil, index != nil, displayedItem == previous {
                currentIndex = nil   // 原来的当前文件已不在列表里，下面按新位置加载
            }
        }
        guard let index, items.indices.contains(index) else {
            // 结果变空（例如筛选结果为 0）：记住刚才在看的那张，清除筛选后回到它（spec F1-03）
            if let current { emptyResultAnchor = current }
            currentIndex = nil
            loadCurrent()
            return
        }
        emptyResultAnchor = nil
        guard index != currentIndex || displayedItem != items[index] else { return }
        Perf.beginSwitch(to: items[index].url)
        // 同一个文件换了版本（原地改写）：旧画面先按刚才的显示方向留着，新内容解码好再换上
        let carriedTurns = items[index].url == displayedItem?.url ? rotation : 0
        currentIndex = index
        rotation = 0
        loadCurrent(carriedTurns: carriedTurns)
        // 只用键盘切换时鼠标不动，也要开始计时自动隐藏
        scheduleHide()
    }

    // 切换（方向键、Home / End、PageUp / Down、滚轮、箭头按钮）：筛选面板开着时先关掉再切
    func next() { closePanelForNavigation(); step(1) }
    func previous() { closePanelForNavigation(); step(-1) }
    func first() { closePanelForNavigation(); if !items.isEmpty { select(0) } }
    func last() { closePanelForNavigation(); if !items.isEmpty { select(items.count - 1) } }

    private func closePanelForNavigation() {
        if filterPanelOpen { closeFilterPanel() }
    }
    func step(_ delta: Int) {
        guard edit == nil, let i = currentIndex,
              let target = Navigation.target(from: i, delta: delta > 0 ? 1 : -1, count: items.count, wrap: settings.wrapAround)
        else { return }
        browseDirection = delta > 0 ? 1 : -1
        select(target)
    }

    // MARK: - 加载大图

    /// 解码尺寸：所在屏幕的长边像素（Retina 按物理像素）
    private var displayMaxPixel: Int {
        if let forced = Perf.forcedDecodeSize { return forced }   // 只在性能测量时（启动参数）
        if let screenMaxPixel { return screenMaxPixel }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return 3072 }
        return Self.maxPixel(for: screen)
    }

    static func maxPixel(for screen: NSScreen) -> Int {
        Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
    }

    private func displayVariant(for item: MediaItem) -> ImageDecoder.Variant {
        .display(maxPixel: displayMaxPixel)
    }

    /// 窗口换了屏幕或缩放比例变了（例如从普通显示器拖到 Retina 屏）：记下新的解码尺寸；
    /// 变大时把当前图片按新尺寸重新解码，否则一直是模糊的
    func displayDidChange(maxPixel: Int) {
        guard maxPixel > 0, maxPixel != screenMaxPixel else { return }
        let previous = displayMaxPixel
        screenMaxPixel = maxPixel
        guard maxPixel > previous, fullResTask == nil, !isDecodingRaw, failure == nil, !showingStaleDisplay,
              let item = current, item == displayedItem, item.kind == .image,
              let shown = displayed, !shown.isPreview, !shown.isCameraPreview, shown.isDownsampled || item.format == .svg,
              max(shown.image.width, shown.image.height) < maxPixel else { return }
        let variant = displayVariant(for: item)
        fullResTask = Task {
            defer { fullResTask = nil }
            // 期间已经换成了原始分辨率等更清晰的版本就不替换
            guard let image = try? await pipeline.image(item, variant), !Task.isCancelled, item == current,
                  image !== displayed, (displayed?.image.width ?? 0) < image.image.width else { return }
            show(image, for: item)
        }
    }

    private func fullVariant(for item: MediaItem) -> ImageDecoder.Variant {
        // SVG 是矢量图，“原始分辨率”就是按更大的尺寸重新栅格化
        item.format == .svg ? .display(maxPixel: 8192) : .full
    }

    private func loadCurrent(carriedTurns: Int = 0) {
        refreshInfo()
        loadTask?.cancel()
        fullResTask?.cancel()
        fullResTask = nil
        isDecodingRaw = false
        unplayable = nil
        // 切到视频才开始加载；切走时暂停并释放（PRD：视频不预加载整段）
        if let item = current, item.kind == .video { video.prepare(item) } else { video.stop() }
        guard let item = current else {
            // 没有当前文件（空文件夹、筛选结果为空）：正在算的环境光也作废，不然会晚到并盖住空状态
            ambientTask?.cancel()
            displayed = nil
            displayedItem = nil
            placeholder = nil
            failure = nil
            ambient = nil
            ambientItemURL = nil
            return
        }
        // 同一个文件在原地被改写：在新内容解码好之前继续显示旧画面（不阻塞主线程，只是不清空）
        if let shown = displayedItem, shown != item, shown.url == item.url, displayed != nil, failure == nil, item.kind == .image {
            displayedItem = item
            placeholder = nil
            showingStaleDisplay = true
            heldTurns = (heldTurns + carriedTurns) % 4
        } else if displayedItem != item {
            showingStaleDisplay = false
            heldTurns = 0
        }
        updateAmbient(for: item)
        let variant = displayVariant(for: item)
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task {
            if let hit = await pipeline.cached(item, variant) {
                show(hit, for: item)
                preloadNeighbors()
                return
            }
            // 这张 RAW 之前已经确定系统解不了：直接显示缓存里的相机预览图，不再闪一遍「正在解码」
            if item.format == .raw, let hit = await pipeline.cached(item, .cameraPreview(maxPixel: displayMaxPixel)) {
                show(hit, for: item)
                preloadNeighbors()
                return
            }
            // 还没解码好：先用缩略图占位（模糊一点也比黑屏好）
            failure = nil
            if displayedItem != item {
                displayed = nil
                displayedItem = item
                placeholder = ThumbnailStore.shared.cached(item)?.image
                showingStaleDisplay = false
                heldTurns = 0
            }
            // RAW：先取内嵌预览（不排队，立即开始）；显示出来以后，高清解码排队进行，
            // 和前后几张的预加载共用有限的名额，不会同时堆起很多个完整解码抢走 CPU
            var queuedOrder: Int?
            if item.format == .raw {
                if let preview = try? await pipeline.image(item, .rawPreview), !Task.isCancelled {
                    show(preview, for: item)
                    isDecodingRaw = true
                    queuedOrder = PreloadOrder.currentFull(generation)
                }
                // 这时只预加载前后几张的预览，它们的高清版等当前这张解完再排
                preloadNeighbors(includeFull: false)
            }
            do {
                let image = try await decodeCurrent(item, variant, order: queuedOrder)
                guard !Task.isCancelled else { return }
                show(image, for: item)
            } catch let decodeFailure as DecodeFailure {
                guard !Task.isCancelled else { return }
                // 系统解不了这张 RAW（spec C1-02）：改为显示相机存在文件里的预览图；连预览图都没有才显示出错卡片
                var shownFailure = decodeFailure
                if item.format == .raw, decodeFailure.kind == .corrupt {
                    do {
                        let preview = try await pipeline.image(item, .cameraPreview(maxPixel: displayMaxPixel))
                        guard !Task.isCancelled else { return }
                        show(preview, for: item)
                        isDecodingRaw = false
                        noteCameraPreviewShown(item)
                        preloadNeighbors()
                        return
                    } catch let previewFailure as DecodeFailure {
                        guard !Task.isCancelled else { return }
                        shownFailure = previewFailure
                    } catch {
                        return   // 切到了别的文件
                    }
                }
                displayed = nil
                placeholder = nil
                showingStaleDisplay = false
                heldTurns = 0
                failure = shownFailure
            } catch {
                return   // 切到了别的文件
            }
            isDecodingRaw = false
            preloadNeighbors()
        }
    }

    /// 解码当前项。解码被过期的取消误伤（自己没被取消、它仍是当前项）时再试一次，
    /// 否则会一直停在模糊的占位缩略图上
    private func decodeCurrent(_ item: MediaItem, _ variant: ImageDecoder.Variant, order: Int? = nil) async throws -> DecodedImage {
        do {
            return try await pipeline.image(item, variant, order: order)
        } catch is CancellationError where !Task.isCancelled && item == current {
            return try await pipeline.image(item, variant, order: order)
        }
    }

    private func show(_ image: DecodedImage, for item: MediaItem) {
        // 已经切走（或筛选结果变空）的文件晚到的解码结果不显示
        guard item != unplayable, item == current else { return }
        Perf.shown(item.url, isPreview: image.isPreview)
        // 和旧画面的方向一起换掉（同一次界面更新），不会先转一下再换图
        displayed = image
        displayedItem = item
        placeholder = nil
        failure = nil
        showingStaleDisplay = false
        heldTurns = 0
    }

    /// 预加载前后各 2 张；离开这个范围的进行中解码会被取消。
    /// 能最先显示的版本（RAW 的内嵌预览、其他图片的屏幕尺寸版）很快，前后各 2 张都立即开始，翻页方向上的在前；
    /// RAW 的高清版（完整解码，几百毫秒、几十 MB）只预加载翻页方向上的 2 张，经过排队口，
    /// 和当前这张的高清解码共用有限的名额。includeFull 为 false（当前这张的 RAW 还在解高清）时先不排
    private func preloadNeighbors(includeFull: Bool = true) {
        guard let i = currentIndex else { return }
        let d = browseDirection
        // 动图解码很占内存，不预加载；视频只预加载静帧
        let ahead = [i + d, i + 2 * d].filter { items.indices.contains($0) }.map { items[$0] }
        let behind = [i - d, i - 2 * d].filter { items.indices.contains($0) }.map { items[$0] }
        let jobs = PreloadOrder.jobs(ahead: ahead.filter { $0.format != .gif }, behind: behind.filter { $0.format != .gif },
                                     generation: loadGeneration, includeFull: includeFull, display: displayVariant(for:))
        let pipeline = self.pipeline
        Task {
            // 要保留的范围在真正执行时按最新位置算，并且总是包含当前项：
            // 否则快速跳转时，按旧位置算出的取消会误杀当前图片的解码
            await pipeline.cancelAll(except: keepSet())
            for job in jobs { await pipeline.preload(job.item, job.variant, order: job.order) }
        }
        for item in ahead + behind { prefetchAmbient(for: item) }
    }

    /// 当前项和前后各 2 张
    private func keepSet() -> Set<URL> {
        guard let i = currentIndex else { return [] }
        var keep = Set((i - 2...i + 2).filter { items.indices.contains($0) }.map { items[$0].url })
        if let current { keep.insert(current.url) }
        if let displayedItem { keep.insert(displayedItem.url) }
        return keep
    }

    /// 放大超过屏幕解码尺寸时，换成原始分辨率
    func requestFullResolution() {
        // RAW 还在完整解码（现在显示的是内嵌预览）时不要再同时解一份原始分辨率
        guard !showingStaleDisplay, let item = displayedItem, item == current, let shown = displayed, shown.isDownsampled,
              !shown.isPreview, !isDecodingRaw,
              fullResTask == nil || fullResTask?.isCancelled == true else { return }
        // 相机预览图的「原始分辨率」是内嵌 JPEG 的原始大小
        let variant = shown.isCameraPreview ? ImageDecoder.Variant.cameraPreview(maxPixel: nil) : fullVariant(for: item)
        fullResTask = Task {
            defer { fullResTask = nil }
            guard let image = try? await pipeline.image(item, variant), !Task.isCancelled, item == current,
                  image !== displayed else { return }
            show(image, for: item)
        }
    }

    /// 当前显示的是相机预览图（系统解不了这张 RAW，spec C1-02）
    var showingCameraPreview: Bool {
        displayedItem != nil && displayedItem == current && failure == nil && displayed?.isCameraPreview == true
    }

    /// 第一次显示相机预览图：出一张说明卡（spec C1-13），这台电脑上只出一次
    private func noteCameraPreviewShown(_ item: MediaItem) {
        Log.app.info("系统无法解码 \(item.name, privacy: .public)，显示相机预览图")
        guard !settings.didShowCameraPreviewHint else { return }
        settings.didShowCameraPreviewHint = true
        enqueueHint(.cameraPreview)
    }

    /// 播放器打不开当前视频：显示出错卡片
    private func videoPlaybackFailed(_ item: MediaItem, message: String?) {
        guard item == current else { return }
        Log.app.error("视频无法播放 \(item.name, privacy: .public)：\(message ?? "", privacy: .public)")
        unplayable = item
        displayed = nil
        placeholder = nil
        // 文件不见了 / 读不了就照实说，其他情况统一说“无法播放”
        failure = ImageDecoder.accessFailure(item) ?? DecodeFailure(
            reason: String(localized: "这个视频无法播放。"),
            detail: String(localized: "播放失败 · \(Formatting.fileSize(item.fileSize))", comment: "%@ 是文件大小"),
            kind: .unplayable)
    }

    func revealCurrentInFinder() {
        guard let url = current?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyCurrentPath() {
        guard let path = current?.url.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// 文件夹同步发现这些文件变了：清掉解码失败记录、缩略图、环境光和信息缓存
    func forgetCaches(for urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let pipeline = self.pipeline
        Task { await pipeline.forget(urls) }
        ThumbnailStore.shared.forget(urls)
        for url in urls { ambientCache.removeObject(forKey: url as NSURL) }
        forgetMetadata(for: urls)
    }

    // MARK: - 环境光

    private func updateAmbient(for item: MediaItem) {
        ambientTask?.cancel()
        if let hit = ambientCache.object(forKey: item.url as NSURL) {
            ambient = hit.image
            ambientItemURL = item.url
            return
        }
        ambientTask = Task {
            let image = await makeAmbient(for: item)
            guard !Task.isCancelled else { return }
            ambient = image
            ambientItemURL = item.url
        }
    }

    private func prefetchAmbient(for item: MediaItem) {
        guard ambientCache.object(forKey: item.url as NSURL) == nil else { return }
        Task { _ = await makeAmbient(for: item) }
    }

    private func makeAmbient(for item: MediaItem) async -> CGImage? {
        guard let thumb = await ThumbnailStore.shared.thumbnail(for: item)?.image else { return nil }
        let rendered = await Task.detached(priority: .userInitiated) { AmbientRenderer.render(thumb) }.value
        if let rendered { ambientCache.setObject(CGImageBox(rendered), forKey: item.url as NSURL) }
        return rendered
    }

    // MARK: - 缩放

    func zoom(_ action: ZoomCommand.Action) {
        guard current != nil else { return }
        dismissHint(.shortcutsChanged)
        serial += 1
        zoomCommand = ZoomCommand(action: action, serial: serial)
    }

    // MARK: - 旋转

    /// 旋转显示（quarterTurns：1 = 顺时针 90°，-1 = 逆时针 90°）
    func rotate(_ quarterTurns: Int) {
        guard current != nil, failure == nil else { return }
        // 编辑中：转编辑的图（裁切框跟着转，spec ED-19）
        if let edit {
            guard !edit.saving else { return }
            edit.closePopups()
            edit.rotate(clockwise: quarterTurns > 0)
            return
        }
        rotation = ((rotation + quarterTurns) % 4 + 4) % 4
        rotationMenuOpen = false
    }

    // MARK: - 最近打开

    /// 记下当前停留的文件，下次在欢迎界面里当作这个文件夹的封面
    func saveRecentCover() {
        guard let folder = folderURL, let url = current?.url else { return }
        recents.updateCover(folder: folder, cover: url)
    }

    // MARK: - 控件自动隐藏

    /// 鼠标在窗口里移动
    func noteMouseActivity() {
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.15)) { chromeVisible = true }
        }
        scheduleHide()
    }

    func setHovering(_ control: String, _ hovering: Bool) {
        if hovering { hoveredControls.insert(control) } else { hoveredControls.remove(control) }
        if control == "vbar" { setHoveringVideoBar(hovering) }
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        // 没开自动隐藏：什么都不用做（鼠标每动一下都会走到这里）
        guard settings.autoHideControls else {
            hideTask?.cancel()
            hideTask = nil
            return
        }
        hideDeadline = .now + .seconds(settings.hideDelay)
        // 已经在计时：只把时间点往后推
        guard hideTask == nil else { return }
        hideTask = Task {
            // 睡到时间点；期间时间点被推后就接着睡
            while hideDeadline > .now {
                try? await Task.sleep(until: hideDeadline, clock: .continuous)
                if Task.isCancelled { return }
            }
            hideTask = nil
            guard hoveredControls.isEmpty, canAutoHide, !ShotHooks.keepsChrome else { return }
            withAnimation(.easeOut(duration: 0.35)) { chromeVisible = false }
        }
    }

    /// 只有在看图或视频时才自动隐藏；出错、空文件夹时控件一直显示
    private var canAutoHide: Bool {
        settings.autoHideControls && current != nil && failure == nil && pendingDelete == nil && edit == nil
    }

    // MARK: - 提示条

    func showToast(symbol: String, text: String, detail: String? = nil, action: ToastAction? = nil,
                   tone: ToastTone = .normal, solid: Bool = false, bottom: Bool = false, duration: Double = 1.6) {
        serial += 1
        toast = Toast(symbol: symbol, text: text, detail: detail, action: action, tone: tone, solid: solid,
                      bottom: bottom, serial: serial)
        toastHovered = false
        toastTask?.cancel()
        toastTask = Task {
            // 截图时（--shot-hold-flash）提示条一直显示
            try? await Task.sleep(for: .seconds(ShotHooks.holdFlash ? 600 : duration))
            // 鼠标停在提示条上时不消失
            while toastHovered, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func hideToast() {
        toastTask?.cancel()
        toast = nil
    }

    func performToastAction(_ action: ToastAction) {
        switch action {
        case .undoDelete, .undoEdit: Task { await undoLast() }
        }
    }

    // MARK: - 键盘

    /// 处理没有 ⌘ 的单键快捷键；返回 true 表示已处理
    func handleKey(_ event: NSEvent) -> Bool {
        let handled = handleKeyCommand(event)
        // 键盘操作也算“有动作”：重新开始自动隐藏计时（不主动显示控件）
        if handled { scheduleHide() }
        return handled
    }

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        // 更新说明表单打开时：Esc = 稍后，其他单键不起作用（spec U3-01、K-08）
        if UpdateChecker.shared.sheetRelease != nil {
            if event.keyCode == 53 { UpdateChecker.shared.later() }
            return mods.isEmpty || event.keyCode == 53
        }
        // 编辑模式：按键另有一套（spec ED-07、ED-08）
        if edit != nil { return handleEditKey(event) }
        // 删除确认对话框：Return 确认，Esc 取消；其他按键不起作用（菜单里的 ⌘ 快捷键也已置灰）
        if pendingDelete != nil {
            switch event.keyCode {
            case 36, 76: confirmDelete()   // Return、小键盘 Enter
            case 53: cancelDelete()        // Esc
            case 49: deleteDontAsk.toggle()   // 空格：勾选“不再询问”
            default: break
            }
            return true
        }
        // ⌫ 和 ⌘⌫：移到废纸篓
        if event.keyCode == 51, mods.isEmpty || mods == [.command] {
            requestDelete()
            return true
        }
        // Esc：先关筛选面板，再关信息面板，再退出全屏（spec R5-07）
        if event.keyCode == 53, mods.isEmpty {
            if filterPanelOpen { closeFilterPanel(); return true }
            if infoVisible { setInfoVisible(false); return true }
            if isFullScreen { toggleFullScreen(); return true }
            return false
        }
        // 数字键 1–5 评星、0 清除（spec R1、K-01）：按键码判断，主键盘和小键盘都算；按住不放的重复不算
        if mods.isEmpty, !event.modifierFlags.contains(.shift), let value = Self.ratingKey(event.keyCode) {
            // 筛选面板开着时数字键只用来选星级，绝不给当前照片评星（避免在面板后面悄悄写文件）
            if !event.isARepeat {
                if filterPanelOpen { filterDigit(value) } else { rateCurrent(value, fromKeyboard: true) }
            }
            return true
        }
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoom(.zoomIn); return true
            case "-", "−": zoom(.zoomOut); return true
            case "0": zoom(.actualSize); return true   // ⌘0 实际大小（spec K-02）
            case "9": zoom(.fit); return true          // ⌘9 适应窗口
            case "f": toggleFilterPanel(); return true // ⌘F 筛选面板（spec K-06）
            case "1": setFilter(.all); return true
            case "2": setFilter(.images); return true
            case "3": setFilter(.videos); return true
            default: return false
            }
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 123, 126, 116: previous(); return true   // ← ↑ PageUp
        case 124, 125, 121: next(); return true       // → ↓ PageDown
        case 115: first(); return true                // Home
        case 119: last(); return true                 // End
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": zoom(.toggle); return true   // Z：适应窗口 ↔ 实际大小（spec K-03）
        case "t":
            withAnimation(.easeInOut(duration: 0.25)) { stripVisible.toggle() }
            return true
        case "r":
            rotate(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case "i":
            toggleInfo()
            return true
        case "f":
            toggleFullScreen()
            return true
        case "e":
            enterEdit()   // 不能编辑的文件上无反应（spec ED-02）
            return true
        default: break
        }
        // 视频：空格 播放/暂停，J / L 快退/快进 5 秒，M 静音（方向键留给切换文件）
        guard current?.kind == .video, failure == nil, video.isActive else { return false }
        if event.keyCode == 49 { video.togglePlay(); return true }   // 空格
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": video.skip(by: -VideoTransport.skipSeconds); return true
        case "l": video.skip(by: VideoTransport.skipSeconds); return true
        case "m": video.toggleMute(); return true
        default: return false
        }
    }
}

extension BrowserModel {
    /// 键码 → 星级：主键盘 0–5（29, 18, 19, 20, 21, 23），小键盘 0–5（82–87）
    nonisolated static func ratingKey(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 29, 82: 0
        case 18, 83: 1
        case 19, 84: 2
        case 20, 85: 3
        case 21, 86: 4
        case 23, 87: 5
        default: nil
        }
    }
}

/// 预加载哪些、按什么先后（技术方案 v0.3.1）。
/// - 能最先显示的版本（RAW 的内嵌预览、其他图片的屏幕尺寸版）：前后各 2 张，不排队（order 为 nil），
///   翻页方向上近的在前。预览只要几十毫秒，提前备好，方向键才跟手。
/// - RAW 的高清版：只要翻页方向上的 2 张，排队（数字大的先开始）。新一轮（切换后）整体排在旧一轮前面；
///   同一轮里当前这张的高清版最先，然后是下一张、下下张
enum PreloadOrder {
    struct Job: Equatable {
        let item: MediaItem
        let variant: ImageDecoder.Variant
        /// nil：立即开始，不排队
        let order: Int?
    }

    private static let step = 100

    static func currentFull(_ generation: Int) -> Int { generation * step + 90 }

    /// ahead：翻页方向上的（下一张、下下张）；behind：反方向的（上一张、上上张）
    static func jobs(ahead: [MediaItem], behind: [MediaItem], generation: Int, includeFull: Bool,
                     display: (MediaItem) -> ImageDecoder.Variant) -> [Job] {
        // 近的在前：下一张、上一张、下下张、上上张
        var near: [MediaItem] = []
        for n in 0..<max(ahead.count, behind.count) {
            if n < ahead.count { near.append(ahead[n]) }
            if n < behind.count { near.append(behind[n]) }
        }
        let first = near.map { Job(item: $0, variant: $0.format == .raw ? .rawPreview : display($0), order: nil) }
        guard includeFull else { return first }
        let full = ahead.enumerated().filter { $0.element.format == .raw }
            .map { Job(item: $0.element, variant: display($0.element), order: generation * step + 50 - $0.offset) }
        return first + full
    }
}

/// NSCache 只能存对象，CGImage 包一层
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
