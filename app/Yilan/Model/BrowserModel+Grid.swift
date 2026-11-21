import AppKit
import SwiftUI

/// 图标视图：视图切换、选中集合、键盘（spec 第 3–5、9 节，技术方案 3.1）。
/// 图标视图里 currentIndex 的含义：恰好选中一张时指向它，否则为 nil；任何时候都不加载大图
extension BrowserModel {
    var isGrid: Bool { viewMode == .grid }
    var itemURLs: [URL] { items.map(\.url) }
    /// 选中的文件，按列表顺序
    var selectedItems: [MediaItem] { items.filter { grid.selection.contains($0.url) } }
    var selectionCount: Int { isGrid ? grid.selection.count : (current == nil ? 0 : 1) }
    /// 多选：选中 2 张及以上
    var isMultiSelection: Bool { isGrid && grid.selection.count > 1 }

    /// 能不能切换视图：打开了文件夹，没有在编辑，没有确认框和批量操作
    var canSwitchView: Bool {
        hasOpenedFolder && edit == nil && pendingDelete == nil && !batchRunning && !batchModalOpen && UpdateChecker.shared.sheetRelease == nil
    }

    // MARK: - 切换视图

    /// G、切换控件、菜单
    func toggleViewMode() { setViewMode(isGrid ? .gallery : .grid) }

    /// remember：这次是用户主动选的视图，记下来（spec V6-01）。从图标视图打开一张、再回去，都不算
    func setViewMode(_ mode: ViewMode, remember: Bool = true) {
        guard canSwitchView else { return }
        if remember { settings.lastViewMode = mode }
        guard mode != viewMode else { return }
        if filterPanelOpen { closeFilterPanel() }
        switch mode {
        case .grid:
            // 画廊视图全屏时：先退出全屏，再切（spec V1-19）
            if isFullScreen { toggleFullScreen() }
            let cur = current
            suspendStage()
            cameFromGrid = false
            withAnimation(.easeInOut(duration: 0.25)) { viewMode = .grid }
            noteMouseActivity()   // 图标视图里控件始终显示（spec V1-18）
            // 选中集合变成只有当前这一张，并滚到完整可见（spec SEL-03）
            grid = .single(cur?.url)
            gridKnownURLs = itemURLs
            syncCurrentToGrid()
            if let cur { requestGridScroll(to: cur.url) }
        case .gallery:
            // 显示选中的那一张；多选时显示最后点的那一张，选中收成它（spec SEL-04）
            let target = GridSelection.representative(grid, items: itemURLs)
            grid = .single(target)
            cameFromGrid = false
            withAnimation(.easeInOut(duration: 0.25)) { viewMode = .gallery }
            currentIndex = target.flatMap { url in items.firstIndex { $0.url == url } }
            resumeStage()
        }
    }

    /// 图标视图里双击、回车、空格：进画廊视图看这一张（spec V3-01、V3-02）
    func openFromGrid(_ url: URL) {
        guard isGrid, canSwitchView, items.contains(where: { $0.url == url }) else { return }
        grid = .single(url)
        setViewMode(.gallery, remember: false)
        cameFromGrid = true
    }

    /// Esc、空格：回到图标视图，刚才看的那一张处于选中（spec V3-04、V3-05）
    func returnToGrid() {
        guard cameFromGrid, !isGrid else { return }
        setViewMode(.grid, remember: false)
    }

    /// 打开文件或文件夹前决定用哪种视图（spec V6-03、V6-04）。这里不改「上次的视图」的记忆
    func prepareView(forFolder: Bool) {
        let mode: ViewMode = forFolder ? settings.viewModeForFolder : .gallery
        cameFromGrid = false
        guard mode != viewMode else { return }
        if mode == .grid {
            if isFullScreen { toggleFullScreen() }
            suspendStage()
        }
        viewMode = mode
    }

    /// 图标视图里打开文件夹之后：选中打开的那一张
    func selectInGridAfterOpen(_ index: Int?) {
        let url = index.flatMap { items.indices.contains($0) ? items[$0].url : nil }
        grid = .single(url)
        gridKnownURLs = itemURLs
        syncCurrentToGrid()
        if let url { requestGridScroll(to: url) }
    }

    func resetGridSelection() {
        grid = .empty
        gridKnownURLs = []
        gridPendingRenames = [:]
        gridLostOnlySelection = false
        cameFromGrid = false
    }

    func requestGridScroll(to url: URL) {
        serial += 1
        gridScrollRequest = GridScrollRequest(url: url, serial: serial)
    }

    // MARK: - 选中集合

    /// 列表变了（筛选、同步、删除）：不在列表里的从选中里去掉（items 的 didSet 调用）
    func gridListChanged(old: [MediaItem]) {
        let had = grid.only
        grid = GridSelection.reconcile(grid, items: itemURLs, oldItems: old.map(\.url), renamed: gridPendingRenames)
        gridPendingRenames = [:]
        gridKnownURLs = itemURLs
        if had != nil, grid.selection.isEmpty { gridLostOnlySelection = true }
    }

    /// 现有的各条路径（筛选、同步、单张删除）调 select() 时，在图标视图里走这里：不加载大图
    func adoptInGrid(_ index: Int?) {
        // 唯一选中的那一张刚被拿掉：调用方给的那一张顶上（单张删除后选中后面一张，spec V4-06）
        if gridLostOnlySelection, grid.selection.isEmpty, let index, items.indices.contains(index) {
            grid = .single(items[index].url)
        }
        gridLostOnlySelection = false
        if index == nil, let current { emptyResultAnchor = current }
        syncCurrentToGrid()
    }

    /// 让 currentIndex 跟上选中集合：恰好一张时指向它，否则 nil
    func syncCurrentToGrid() {
        let index = grid.only.flatMap { url in items.firstIndex { $0.url == url } }
        if currentIndex != index { currentIndex = index }
        refreshInfo()
    }

    /// 图标视图里所有改选中的操作都走这里
    func setGridSelection(_ new: GridSelectionState, scrollToFocus: Bool = false) {
        guard isGrid else { return }
        var new = new
        // 选中换到别处：暂留的文件这时才离开列表（spec V8-03）。它自己还在选中里（比如全选）就继续留着，
        // 眼前看到的每一张都要能被选中、被删除
        if let sticky = stickyURL, new.selection != grid.selection, !new.selection.contains(sticky) {
            stickyURL = nil
            let old = itemURLs
            let fresh = resultList()
            if fresh != items {
                grid = new
                items = fresh          // didSet 里按新列表收拾 grid
                new = GridSelection.reconcile(new, items: itemURLs, oldItems: old)
            }
        }
        gridLostOnlySelection = false
        grid = new
        gridKnownURLs = itemURLs
        syncCurrentToGrid()
        if scrollToFocus, let focus = new.focus { requestGridScroll(to: focus) }
    }

    /// 点了某一张（spec X1-01 至 X1-04）
    func gridClick(_ url: URL, command: Bool, shift: Bool) {
        guard isGrid, !batchRunning else { return }
        let urls = itemURLs
        let new: GridSelectionState
        if shift { new = GridSelection.shiftClick(url, state: grid, items: urls, union: command) }
        else if command { new = GridSelection.commandClick(url, state: grid) }
        else { new = GridSelection.click(url) }
        setGridSelection(new)
    }

    /// 框选时视图报上来的选中集合（spec X1-08）
    func gridViewSelectionChanged(_ urls: Set<URL>) {
        guard isGrid, !batchRunning, urls != grid.selection else { return }
        setGridSelection(GridSelection.replace(with: urls, state: grid, items: itemURLs))
    }

    /// ⌘A（spec X1-05）
    func selectAllInGrid() {
        guard isGrid, !batchRunning else { return }
        setGridSelection(GridSelection.selectAll(itemURLs, state: grid))
    }

    /// ⌥⌘A、Esc、点空白处（spec X1-06）
    func deselectAllInGrid() {
        guard isGrid, !batchRunning, !grid.selection.isEmpty else { return }
        setGridSelection(GridSelection.deselectAll(grid))
    }

    // MARK: - 缩略图大小（spec V5）

    var gridSize: GridSize { settings.gridSize }

    func setGridSize(_ size: GridSize) {
        guard size != settings.gridSize else { return }
        settings.gridSize = size
        if let focus = grid.focus { requestGridScroll(to: focus) }
    }

    func stepGridSize(larger: Bool) { setGridSize(larger ? gridSize.larger : gridSize.smaller) }

    // MARK: - 键盘（spec 第 9 节）

    /// 图标视图里的按键。返回 nil：这个键和画廊视图共用同一套处理（I、F、G、⌘F、⌘1–3、数字键等）
    func handleGridKey(_ event: NSEvent, mods: NSEvent.ModifierFlags) -> Bool? {
        let shift = event.modifierFlags.contains(.shift)
        let urls = itemURLs
        // Esc：关面板 → 取消选中 → 退出全屏，每次只做一件（spec K-02）
        if event.keyCode == 53, mods.isEmpty {
            if filterPanelOpen { closeFilterPanel(); return true }
            if infoVisible { setInfoVisible(false); return true }
            if !grid.selection.isEmpty { deselectAllInGrid(); return true }
            if isFullScreen { toggleFullScreen(); return true }
            return false
        }
        // ⌫：一张按单张规则，多张一定先确认，没有选中时没有反应（spec K-07）
        if event.keyCode == 51, mods.isEmpty || mods == [.command] {
            if isMultiSelection { requestBatchDelete() } else if current != nil { requestDelete() }
            return true
        }
        // 数字键：多选时是批量评星（spec X7）；一张或没有选中时和画廊视图共用
        if mods.isEmpty, !shift, let value = Self.ratingKey(event.keyCode), isMultiSelection {
            if !event.isARepeat, ratingEnabled, !filterPanelOpen { rateSelection(value) }
            return true
        }
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "=", "+": stepGridSize(larger: true); return true
            case "-", "−": stepGridSize(larger: false); return true
            case "0", "9": return true                       // 缩放图片的快捷键在这里没有意义
            case "a" where !textFieldHasFocus:
                if mods == [.command, .option] { deselectAllInGrid() } else if mods == [.command] { selectAllInGrid() }
                return true
            case "c" where mods == [.command] && !shift && !textFieldHasFocus:
                copySelection()
                return true
            default: return nil
            }
        }
        guard mods.isEmpty else { return nil }
        let direction: GridSelection.Direction? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 126: .up
        case 125: .down
        default: nil
        }
        if let direction {
            let new = shift
                ? GridSelection.extend(direction, state: grid, items: urls, columns: gridColumns, firstVisible: gridFirstVisible)
                : GridSelection.move(direction, state: grid, items: urls, columns: gridColumns, firstVisible: gridFirstVisible)
            setGridSelection(new, scrollToFocus: true)
            return true
        }
        switch event.keyCode {
        case 115: if !urls.isEmpty { setGridSelection(GridSelection.moveToEdge(first: true, items: urls), scrollToFocus: true) }; return true
        case 119: if !urls.isEmpty { setGridSelection(GridSelection.moveToEdge(first: false, items: urls), scrollToFocus: true) }; return true
        case 116, 121:
            setGridSelection(GridSelection.movePage(down: event.keyCode == 121, state: grid, items: urls, columns: gridColumns,
                                                    rows: gridVisibleRows, firstVisible: gridFirstVisible), scrollToFocus: true)
            return true
        case 36, 76, 49:
            // 回车、空格：看大图（spec V3-02）。没有选中时没有反应
            if !event.isARepeat, !grid.selection.isEmpty, let url = GridSelection.representative(grid, items: urls) { openFromGrid(url) }
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        // 旋转、编辑、缩放切换、缩略图栏、视频的几个键：图标视图里没有反应（spec K-12、K-14、K-15、K-17）
        case "z", "t", "r", "e", "j", "l", "m": return true
        default: return nil
        }
    }

    // MARK: - 菜单栏「前往」（spec MB-06）

    func goPrevious() {
        if isGrid { setGridSelection(GridSelection.move(.left, state: grid, items: itemURLs, columns: gridColumns, firstVisible: gridFirstVisible), scrollToFocus: true) } else { previous() }
    }

    func goNext() {
        if isGrid { setGridSelection(GridSelection.move(.right, state: grid, items: itemURLs, columns: gridColumns, firstVisible: gridFirstVisible), scrollToFocus: true) } else { next() }
    }

    func goEdge(first: Bool) {
        if isGrid {
            guard !items.isEmpty else { return }
            setGridSelection(GridSelection.moveToEdge(first: first, items: itemURLs), scrollToFocus: true)
        } else if first { self.first() } else { last() }
    }

    /// ⌘C：拷贝选中的文件；没有选中时没有反应（spec K-10）
    func copySelection() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        copyFiles(selected)
    }
}

// MARK: - 信息条、计数、面板上的汇总（spec V1-10 至 V1-15、V10-04、V10-05）

/// 图标视图里一组文件的汇总
struct GridSummary: Equatable, Sendable {
    var count = 0
    var images = 0
    var videos = 0
    var bytes: Int64 = 0

    init(_ items: [MediaItem]) {
        count = items.count
        for item in items {
            if item.kind == .video { videos += 1 } else { images += 1 }
            bytes += item.fileSize
        }
    }

    /// 「已选 5 项」
    var selectedText: String { String(localized: "已选 \(count) 项", comment: "多选时的计数；%lld 是数量") }

    /// 「4 张图片 · 1 个视频」；只有一种时只写那一种
    var composition: String {
        var parts: [String] = []
        if images > 0 { parts.append(String(localized: "\(images) 张图片", comment: "多选的构成；%lld 是数量")) }
        if videos > 0 { parts.append(String(localized: "\(videos) 个视频", comment: "多选的构成；%lld 是数量")) }
        return parts.joined(separator: " · ")
    }

    var sizeText: String { Formatting.fileSize(bytes) }
    /// 「共 86.4 MB」
    var totalText: String { String(localized: "共 \(sizeText)", comment: "信息条上的总大小；%@ 是大小") }
}

extension BrowserModel {
    /// 选中文件的汇总（多选时用）
    var selectionSummary: GridSummary { GridSummary(selectedItems) }
    /// 眼前列表的汇总（没有选中时用）
    var listSummary: GridSummary { GridSummary(items) }

    /// 「46 个项目」：文件夹里的总数，不随筛选变（spec V1-15）
    var folderCountText: String { String(localized: "\(allItems.count) 个项目", comment: "图标视图标题下面、信息条上的项目数；%lld 是数量") }

    /// 没有选中时信息条左边文件夹名后面的文字：筛选生效时「显示 12 / 共 46 个项目」（spec V1-12）
    var listCountText: String {
        items.count == allItems.count
            ? folderCountText
            : String(localized: "显示 \(items.count) / 共 \(allItems.count) 个项目", comment: "筛选生效时信息条上的项目数")
    }

    /// 信息条右边：「5712 × 3808 · 3.9 MB · HEIF」，拆成尺寸和其余两段（窗口窄时尺寸先让位）
    var gridItemTrailing: (dims: String?, rest: String)? {
        guard let item = current else { return nil }
        let meta = gridMeta?.url == item.url ? gridMeta : nil
        var dims: String?
        if let w = meta?.pixelWidth, let h = meta?.pixelHeight, w > 0, h > 0 { dims = "\(w) × \(h)" }
        var parts: [String] = []
        if item.kind == .video, let d = ThumbnailStore.shared.cached(item)?.duration { parts.append(Formatting.duration(d)) }
        parts.append(Formatting.fileSize(item.fileSize))
        parts.append(item.formatName)
        return (dims, parts.joined(separator: " · "))
    }
}
