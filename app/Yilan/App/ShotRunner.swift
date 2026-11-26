import AppKit

/// 按截图参数（见 ShotHooks）在启动后摆出要截的状态。Release 版里什么都不做
@MainActor
enum ShotRunner {
    #if DEBUG
    /// 在图标视图里打开一张，量几个时间点（毫秒），再回到图标视图
    private static func measureGridOpen(_ item: MediaItem, model: BrowserModel) async {
        model.requestGridScroll(to: item.url)
        try? await Task.sleep(for: .milliseconds(500))
        // 主线程停顿：每 2 毫秒在主队列上打一个点，记最长的间隔
        var last = CACurrentMediaTime(), worstGap = 0.0, worstAnimGap = 0.0, began = Double.infinity
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler {
            let now = CACurrentMediaTime()
            worstGap = max(worstGap, now - last)
            // 过渡动画那一段（打开后 0.45 秒内）的停顿单独记
            if now >= began, last - began < 0.45 { worstAnimGap = max(worstAnimGap, now - last) }
            last = now
        }
        timer.resume()
        let start = CACurrentMediaTime()
        began = start
        model.openFromGrid(item.url)
        let sync = (CACurrentMediaTime() - start) * 1000
        let animated = model.viewSwitch != nil
        var first: Double?, full: Double?, switched: Double?
        while CACurrentMediaTime() - start < 4 {
            let ms = (CACurrentMediaTime() - start) * 1000
            let mine = model.displayedItem == item
            if first == nil, mine, model.displayed != nil || model.failure != nil { first = ms }
            if full == nil, mine, model.failure != nil || (model.displayed.map { !$0.isPreview } ?? false) { full = ms }
            if switched == nil, model.viewSwitch == nil { switched = ms }
            if first != nil, full != nil, switched != nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        try? await Task.sleep(for: .milliseconds(300))
        timer.cancel()
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        print("[perf] grid-open \(item.name): sync=\(f(sync)) first=\(f(first)) full=\(f(full)) overlayGone=\(f(switched)) animated=\(animated) worstMainGap=\(f(worstGap * 1000)) animGap=\(f(worstAnimGap * 1000))")
        fflush(stdout)
        model.returnToGrid()
        try? await Task.sleep(for: .milliseconds(700))
    }
    #endif

    static func run(model: BrowserModel) {
        #if DEBUG
        guard ShotHooks.openInfo || ShotHooks.deleteState != nil || ShotHooks.fullScreenState != nil || ShotHooks.dumpMenus
                || ShotHooks.windowSize != nil || ShotHooks.anyRatingShot || ShotHooks.view != nil
        else { return }
        Task { @MainActor in
            // 等文件夹打开、当前文件显示出来（最多 40 秒：几万个文件的文件夹扫描要十几秒）
            for _ in 0..<400 where !model.hasOpenedFolder || (!model.isGrid && (model.current == nil || model.displayed == nil)) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let size = ShotHooks.windowSize, let window = model.window {
                window.setContentSize(size)
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ShotHooks.fullScreenState != nil, let window = model.window, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(1.2))
            }
            if ShotHooks.stripHidden { model.stripVisible = false }
            if ShotHooks.view == "grid" {
                if let raw = ShotHooks.gridSize, let size = GridSize(rawValue: raw) { model.setGridSize(size) }
                model.setViewMode(.grid, remember: false)
                if ShotHooks.select == "all" {
                    model.selectAllInGrid()
                } else if ShotHooks.select == "none" {
                    model.deselectAllInGrid()
                } else if let picks = ShotHooks.select?.split(separator: ",").compactMap({ Int($0) }), !picks.isEmpty {
                    for (n, index) in picks.enumerated() where model.items.indices.contains(index) {
                        model.gridClick(model.items[index].url, command: n > 0, shift: false)
                    }
                    if let focus = model.grid.focus { model.requestGridScroll(to: focus) }
                    if ShotHooks.deleteState == "batch" { model.requestBatchDelete() }
                }
                // 量「停止」用：直接确认，3 秒后停止，打印从点停止到真正停下又多移走了多少
                if ShotHooks.deleteState == "batchstop" {
                    // 直接开始：程序在后台启动时不是当前窗口，走确认框那条路会被挡住
                    let targets = model.selectedItems
                    Task { await model.performBatchDelete(targets) }
                    try? await Task.sleep(for: .seconds(3))
                    let folder = model.folderURL!
                    func left() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? -1 }
                    let before = left(), t0 = Date()
                    model.stopBatch()
                    while model.batchRunning { try? await Task.sleep(for: .milliseconds(20)) }
                    print("[perf] stop: left before=\(before) after=\(left()) took=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
                    fflush(stdout)
                }
                // 量「图标视图里双击打开」（v0.5.1 P1）：逐张打开再回去，打印到第一帧、到高清、过渡图拿掉、主线程最长停顿
                if CommandLine.arguments.contains("--perf-grid-open") {
                    try? await Task.sleep(for: .seconds(3))   // 等缩略图
                    for item in model.items {
                        await measureGridOpen(item, model: model)
                    }
                    print("[perf] grid open done")
                    fflush(stdout)
                    NSApp.terminate(nil)
                }
                // 量内存用：从头滚到尾，每 0.12 秒滚一行
                if CommandLine.arguments.contains("--perf-grid-scroll") {
                    for index in stride(from: 0, to: model.items.count, by: max(model.gridColumns, 1)) {
                        model.requestGridScroll(to: model.items[index].url)
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    print("[perf] grid scroll done")
                    fflush(stdout)
                }
            }
            if ShotHooks.openInfo { model.setInfoVisible(true) }
            // 评星截图：只对 /tmp 下的测试副本写盘
            if let n = ShotHooks.rating, let item = model.current, isTemporary(item.url) {
                for _ in 0..<50 where !model.ratingsLoaded { try? await Task.sleep(for: .milliseconds(100)) }
                model.rateCurrent(n, fromKeyboard: true)
            }
            if ShotHooks.seedRatings, let first = model.current, isTemporary(first.url) {
                for _ in 0..<50 where !model.ratingsLoaded { try? await Task.sleep(for: .milliseconds(100)) }
                let pattern = [5, 4, 0, 3, 4, 2, 0, 5, 4, 3]
                for (i, item) in model.allItems.enumerated() where item.kind == .image {
                    model.setRating(pattern[i % pattern.count], for: item, old: model.ratings[item.url] ?? 0, recordUndo: false)
                }
                await model.ratingWriter.waitUntilIdle()
            }
            if let spec = ShotHooks.filterSpec {
                var f = BrowseFilter()
                for token in spec.split(separator: ",") {
                    if token.hasPrefix("t:"), let t = MediaFilter(rawValue: String(token.dropFirst(2))) { model.setFilter(t) }
                    if token == "ru" { f.rating.mode = .unrated }
                    if token.hasPrefix("r"), let n = Int(token.dropFirst()) { f.rating.mode = .stars(n) }
                    if token.hasPrefix("e"), let n = Int(token.dropFirst()) { f.rating.mode = .stars(n); f.rating.comparison = .exactly }
                    if token.hasPrefix("f:") {
                        f.format.selected = Set(token.dropFirst(2).split(separator: "+").compactMap { FormatGroup(rawValue: String($0)) })
                    }
                }
                model.setBrowseFilter(f)
            }
            if ShotHooks.filterPanel { model.filterPanelOpen = true }
            if ShotHooks.showStars { model.flash(nil) }
            if let state = ShotHooks.update { showUpdate(state, model: model) }
            switch ShotHooks.hint {
            case "shortcuts": model.enqueueHint(.shortcutsChanged)
            case "whatsnew": model.enqueueHint(.whatsNew)
            case "xmp": model.enqueueHint(.sidecarCreated("DSC_0812.xmp", isRaw: true))
            default: break
            }
            switch ShotHooks.deleteState {
            case "confirm":
                model.settings.confirmBeforeDelete = true
                model.requestDelete()
            case "after":
                // 真的会移到废纸篓：只对 /tmp 下的测试副本生效
                if let item = model.current, isTemporary(item.url) {
                    await model.performDelete(item)
                }
            default:
                break
            }
            if let state = ShotHooks.edit { await showEdit(state, model: model) }
            if ShotHooks.dumpMenus {
                try? await Task.sleep(for: .milliseconds(300))
                if let menu = NSApp.mainMenu { print(describe(menu, depth: 0), terminator: "") }
                fflush(stdout)
            }
        }
        #endif
    }

    #if DEBUG
    /// 截图用的假更新数据（格式和 docs/release-notes-template.md 一致）
    private static func showUpdate(_ state: String, model: BrowserModel) {
        let updater = UpdateChecker.shared
        let short = """
        ## 中文

        ### 改进

        - **大文件夹读星级更快**：文件夹里有 2000 张以上 RAW 时，星级在后台读取，首张图出现的时间不再受影响。

        ### 修复

        - **RAW 打星偶尔没有生成 `.xmp`**：以前在个别情况下评星后旁边没有出现同名小文件，现在每次评星都会写入。
        - **筛选时序号不对**：以前在筛选状态下删除当前照片，右上角的序号会错一位，现在序号和总数同步更新。

        ### 升级须知

        - **无需操作**：直接替换应用即可，设置和星级都会保留。
        - **遇到问题**：欢迎到 [GitHub 问题页](https://github.com/paddychenc75/yilan/issues) 告诉我们。

        ## English

        ### Improved

        - **Faster ratings in big folders**: with 2,000+ RAW files, ratings are now read in the background, so the first photo appears as quickly as before.

        ### Fixed

        - **RAW rating sometimes did not create an `.xmp`**: in rare cases no sidecar file appeared next to the photo; it is now written every time.
        - **Wrong counter while filtering**: deleting the current photo with a filter on left the counter off by one; position and total now update together.

        ### Upgrade notes

        - **Nothing to do**: just replace the app; settings and ratings are kept.
        - **Found a problem?** Tell us on the [GitHub issues page](https://github.com/paddychenc75/yilan/issues).

        ## 安装 / Install

        **系统要求**：macOS 26（Tahoe）或更高版本。
        """
        let long = short.replacingOccurrences(of: "### 改进", with: "### 新功能\n\n- **裁切**：按 C 进入裁切，拖动边框选出要保留的部分。\n- **保存旋转**：旋转后可以把方向写回文件。\n- **调整尺寸导出**：导出时可以选长边像素。\n\n### 改进\n\n- **筛选面板**：格式数量随星级实时变化。\n- **大文件夹**：切换筛选的结果在 0.3 秒内出现。\n- **信息面板**：RAW 的星级保存位置显示 `.xmp` 文件名。")
        let release = ReleaseInfo(version: state == "long" ? "0.4.0" : "0.3.1", tag: "v0.3.1", notes: state == "long" ? long : short,
                                  pageURL: URL(string: "https://github.com/paddychenc75/yilan/releases")!,
                                  published: ISO8601DateFormatter().date(from: "2026-11-24T08:00:00Z"))
        switch state {
        case "uptodate": model.showToast(symbol: "checkmark", text: String(localized: "已是最新版本（\(updater.current.display)）", comment: "手动检查更新：%@ 是当前版本号"), duration: 60)
        case "failed": model.showToast(symbol: "exclamationmark.triangle", text: String(localized: "无法检查更新，请检查网络"), tone: .warning, duration: 60)
        case "long": updater.applyForShots(release: release, state: "sheet")
        default: updater.applyForShots(release: release, state: state)
        }
    }
    #endif

    #if DEBUG
    /// 编辑模式截图（设计稿 edit 02–10）
    private static func showEdit(_ state: String, model: BrowserModel) async {
        if state == "rotation" {
            model.rotate(1)
            try? await Task.sleep(for: .milliseconds(400))
            model.rotationMenuOpen = true
            return
        }
        // 等大图显示出来（RAW 不能编辑，spec C6-01）
        for _ in 0..<50 where !model.canEditCurrent { try? await Task.sleep(for: .milliseconds(100)) }
        model.enterEdit()
        guard let s = model.edit else { return }
        try? await Task.sleep(for: .milliseconds(400))
        if state == "rotated" { model.rotate(1) }
        if let name = ShotHooks.editRatio, let r = CropRatio(rawValue: name) { s.setRatio(r) }
        else if state == "ratio" { s.setRatio(.square) }
        if let c = ShotHooks.editCrop, c.count == 4 {
            let size = s.editedSize
            var rect = PixelRect(x: Int(c[0] * Double(size.width)), y: Int(c[1] * Double(size.height)),
                                 width: Int(c[2] * Double(size.width)), height: Int(c[3] * Double(size.height)))
            if let r = s.ratioValue { rect.height = Int((Double(rect.width) / r).rounded()) }
            s.crop = CropMath.clamp(rect, bounds: size)
        }
        if let p = ShotHooks.editResize, let scale = ResizeMath.scale(forPercent: p) { s.scale = scale }
        if let angle = ShotHooks.editAngle {
            s.straightenOpen = true
            s.straightening = ShotHooks.editAngleDragging
            s.setAngle(angle)
        }
        try? await Task.sleep(for: .milliseconds(300))
        switch state {
        case "ratio": s.ratioMenuOpen = true
        case "resize": s.resizeOpen = true
        case "savemenu": s.saveMenuOpen = true
        case "replace": s.confirmReplace = true
        case "failed": s.failure = .notWritable(folder: s.item.url.deletingLastPathComponent().lastPathComponent)
        case "saved":
            // 真的另存副本：只对 /tmp 下的测试副本
            if isTemporary(s.item.url) { model.saveEdit() }
        default: break
        }
    }
    #endif

    private static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }

    private static func describe(_ menu: NSMenu, depth: Int) -> String {
        var out = ""
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem {
                out += "\(pad)---\n"
                continue
            }
            var key = item.keyEquivalent
            if key == "\u{8}" || key == "\u{7F}" { key = "⌫" }
            let mods = item.keyEquivalentModifierMask
            var prefix = ""
            if !key.isEmpty {
                if mods.contains(.control) { prefix += "⌃" }
                if mods.contains(.option) { prefix += "⌥" }
                if mods.contains(.shift) { prefix += "⇧" }
                if mods.contains(.command) { prefix += "⌘" }
            }
            let shortcut = key.isEmpty ? "" : "  [\(prefix)\(key)]"
            out += "\(pad)\(item.title)\(shortcut)\(item.isEnabled ? "" : "  (disabled)")\(item.isHidden ? "  (hidden)" : "")\n"
            if let sub = item.submenu { out += describe(sub, depth: depth + 1) }
        }
        return out
    }
}
