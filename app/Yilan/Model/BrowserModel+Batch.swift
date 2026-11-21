import AppKit
import SwiftUI

/// 批量确认框里要显示的内容（spec X3-02）
struct BatchDeleteRequest: Equatable {
    enum Scope: Equatable { case some, wholeFolder, wholeFilter }

    let items: [MediaItem]
    let scope: Scope

    var count: Int { items.count }
    var videos: Int { items.filter { $0.kind == .video }.count }
    /// 叠放的前三张（按列表顺序）
    var preview: [MediaItem] { Array(items.prefix(3)) }

    var title: String {
        switch scope {
        case .some: String(localized: "将 \(count) 个项目移到废纸篓？", comment: "批量删除确认框标题；%lld 是数量")
        case .wholeFolder: String(localized: "将这个文件夹里的全部 \(count) 个项目移到废纸篓？", comment: "批量删除确认框标题；%lld 是数量")
        case .wholeFilter: String(localized: "将筛选出的全部 \(count) 个项目移到废纸篓？", comment: "批量删除确认框标题；%lld 是数量")
        }
    }

    var message: String {
        let body = String(localized: "可以在废纸篓里恢复，删除后按 ⌘Z 可以一次全部撤销。")
        guard videos > 0 else { return body }
        return String(localized: "其中有 \(videos) 个视频。", comment: "批量删除确认框正文的前缀；%lld 是数量") + body
    }
}

/// 批量操作的进度（spec X3-07）
struct BatchProgress: Equatable {
    enum Kind: Equatable { case trash, copy, move }
    var kind: Kind
    var done = 0
    var total: Int
    /// 超过 1 秒还没做完才显示进度条
    var visible = false
    var stopping = false

    var title: String {
        switch kind {
        case .trash: String(localized: "正在移到废纸篓")
        case .copy: String(localized: "正在复制")
        case .move: String(localized: "正在移动")
        }
    }
}

/// 批量操作结束后的提示框（spec X3-12、X3-14、X3-17）
struct BatchReport: Equatable {
    enum Action: Equatable {
        /// 在访达里选中这些文件
        case reveal([URL])
        case openTrash
    }

    var title: String
    var message: String?
    /// 文件名、原因；最多 5 行
    var rows: [BatchTrash.Failure]
    /// 没列出来的还有几个
    var more: Int
    var actionTitle: String
    var action: Action

    static func make(title: String, message: String?, failures: [BatchTrash.Failure], actionTitle: String, action: Action) -> BatchReport {
        // 最多 5 行；更多时前 4 行加一行「还有 N 个」
        let shown = failures.count > 5 ? Array(failures.prefix(4)) : failures
        return BatchReport(title: title, message: message, rows: shown, more: failures.count - shown.count,
                           actionTitle: actionTitle, action: action)
    }
}

/// 批量操作（spec 第 6、7 节）
extension BrowserModel {
    /// 正在批量移到废纸篓、复制或移动（spec X3-08）：这期间别的操作都不响应
    var batchRunning: Bool { batchProgress != nil }

    var canBatchDelete: Bool {
        isMultiSelection && !batchRunning && !trashBusy && pendingDelete == nil && pendingBatchDelete == nil && mainWindowIsKey
    }

    /// 确认框、结束提示框开着：只有回车和 Esc 起作用（spec X3-03、X3-04）
    var batchModalOpen: Bool { pendingBatchDelete != nil || batchReport != nil }

    // MARK: - 移到废纸篓（spec X3）

    /// 多选时按 ⌫、选「将 N 项移到废纸篓」：一定先确认，不管「删除前确认」设置（spec X3-01）
    func requestBatchDelete() {
        guard canBatchDelete else { return }
        let selected = selectedItems
        guard selected.count > 1 else { return }
        var scope = BatchDeleteRequest.Scope.some
        if selected.count == items.count {
            scope = browseFilter.isActive || filter != .all ? .wholeFilter : .wholeFolder
        }
        withAnimation(.easeOut(duration: 0.15)) { pendingBatchDelete = BatchDeleteRequest(items: selected, scope: scope) }
    }

    /// 确认框：取消（Esc）。没有任何文件被移动，选择不变（spec X3-05）
    func cancelBatchDelete() {
        withAnimation(.easeOut(duration: 0.12)) { pendingBatchDelete = nil }
    }

    /// 确认框：移到废纸篓（回车）
    func confirmBatchDelete() {
        guard let request = pendingBatchDelete else { return }
        withAnimation(.easeOut(duration: 0.12)) { pendingBatchDelete = nil }
        Task { await performBatchDelete(request.items) }
    }

    /// 进度条上的「停止」：正在处理的那一个做完后停下（spec X3-11）
    func stopBatch() {
        batchStop?.stop()
        batchProgress?.stopping = true
    }

    /// trash：测试里换成会失败的版本
    func performBatchDelete(_ targets: [MediaItem], trash: @escaping @Sendable (URL) throws -> URL = TrashService.trash) async {
        guard !batchRunning, !trashBusy, !targets.isEmpty else { return }
        let jobs = BatchTrash.jobs(for: targets, sidecars: sidecars)
        let stop = BatchTrash.StopFlag()
        batchStop = stop
        batchProgress = BatchProgress(kind: .trash, total: targets.count)
        // 进行中暂停对文件夹变化的自动刷新（spec X3-09）
        trashBusy = true
        localChangeSerial += 1
        let reveal = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, batchProgress != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { batchProgress?.visible = true }
        }
        let throttle = ProgressThrottle(total: targets.count)
        let result = await Task.detached(priority: .userInitiated) {
            BatchTrash.run(jobs, stop: stop, trash: trash) { [weak self] done in
                guard throttle.shouldReport(done) else { return }
                Task { @MainActor in self?.batchProgress?.done = done }
            }
        }.value
        reveal.cancel()
        batchStop = nil
        withAnimation(.easeOut(duration: 0.2)) { batchProgress = nil }
        trashBusy = false
        localChangeSerial += 1
        finishBatchDelete(result, requested: targets.count)
        batchDidEnd()
    }

    private func finishBatchDelete(_ result: BatchTrash.Result, requested: Int) {
        let moved = result.moved
        if !moved.isEmpty {
            undoHistory.push(.trashBatch(moved))
            for side in moved.compactMap(\.sidecar) { sidecars.noteRemoved(side.original) }
            let gone = Set(moved.map(\.item.url))
            // 焦点落在第一张被删文件原来的位置上现在的那一张（spec X3-10）
            if isGrid, let first = items.first(where: { gone.contains($0.url) }) { grid.focus = first.url }
            forgetMetadata(for: gone)
            // 列表一次性更新：被移走的格子同时消失（spec X3-09）；选中集合里移走的自动去掉，移不走和没动的保持选中
            replaceItems(allItems.filter { !gone.contains($0.url) }, showing: isGrid ? nil : current)
        }
        if !result.failed.isEmpty {
            for f in result.failed { Log.app.error("移到废纸篓失败 \(f.item.name, privacy: .public)：\(f.reason, privacy: .public)") }
            let title = moved.isEmpty
                ? String(localized: "这 \(result.failed.count) 个项目无法移到废纸篓", comment: "批量删除全部失败的提示框标题；%lld 是数量")
                : String(localized: "有 \(result.failed.count) 个项目无法移到废纸篓", comment: "批量删除部分失败的提示框标题；%lld 是数量")
            let message = moved.isEmpty ? nil
                : String(localized: "其余 \(moved.count) 项已经移到废纸篓，按 ⌘Z 可以撤销。", comment: "批量删除部分失败的提示框正文；%lld 是数量")
            withAnimation(.easeOut(duration: 0.15)) {
                batchReport = .make(title: title, message: message, failures: result.failed,
                                    actionTitle: String(localized: "在访达中显示"), action: .reveal(result.failed.map(\.item.url)))
            }
        } else if !result.untouched.isEmpty {
            showToast(symbol: "stop.circle",
                      text: String(localized: "已停止：\(moved.count) 项已移到废纸篓，\(result.untouched.count) 项没有移动", comment: "批量删除被停止后的提示条"),
                      detail: moved.isEmpty ? nil : String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"),
                      action: moved.isEmpty ? nil : .undoDelete, duration: 4)
        } else if !moved.isEmpty {
            showToast(symbol: "trash", text: String(localized: "已将 \(moved.count) 项移到废纸篓", comment: "批量删除后的提示条；%lld 是数量"),
                      detail: String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"), action: .undoDelete, duration: 4)
        }
    }

    /// 提示框的按钮
    func dismissBatchReport(performAction: Bool) {
        guard let report = batchReport else { return }
        withAnimation(.easeOut(duration: 0.12)) { batchReport = nil }
        guard performAction else { return }
        switch report.action {
        case .reveal(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
        case .openTrash:
            if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(trash) }
        }
    }

    /// ⌘Z：把这一批实际移走的文件和小文件全部放回原位（spec X3-16、X3-17）
    func undoBatchTrash(_ entries: [TrashEntry]) async {
        guard !trashBusy, !batchRunning, pendingDelete == nil else { return }
        trashBusy = true
        localChangeSerial += 1
        let result = await Task.detached(priority: .userInitiated) { () -> (BatchTrash.RestoreResult, [MediaItem]) in
            let r = BatchTrash.restore(entries)
            return (r, r.restored.compactMap { FolderScanner.item(at: $0.item.url) })
        }.value
        trashBusy = false
        localChangeSerial += 1
        // 这条记录用完：放不回的也不能再撤销一次
        undoHistory.pop()
        hideToast()
        let (restore, found) = result
        for entry in restore.restored {
            if let side = entry.sidecar, FileManager.default.fileExists(atPath: side.original.path) { sidecars.noteWritten(side.original) }
        }
        // 期间换了文件夹：文件已经放回去了，只是不在眼前
        let here = found.filter { item in
            guard let folder = folderURL else { return false }
            return item.url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
        }
        if !here.isEmpty {
            let urls = Set(here.map(\.url))
            let newAll = FolderScanner.naturalSorted(allItems.filter { !urls.contains($0.url) } + here)
            if isGrid {
                replaceItems(newAll, showing: nil)
                // 放回的文件全部选中，第一张滚到可见
                let visible = Set(itemURLs).intersection(urls)
                setGridSelection(GridSelection.replace(with: visible, state: grid, items: itemURLs))
                if let first = items.first(where: { visible.contains($0.url) }) { requestGridScroll(to: first.url) }
            } else {
                replaceItems(newAll, showing: FolderScanner.naturalSorted(here).first)
            }
        }
        if restore.failed.isEmpty {
            if !restore.restored.isEmpty {
                showToast(symbol: "arrow.uturn.backward", text: String(localized: "已放回 \(restore.restored.count) 项", comment: "撤销批量删除后的提示条；%lld 是数量"), duration: 2.5)
            }
        } else {
            for f in restore.failed { Log.app.error("放回失败 \(f.item.name, privacy: .public)：\(f.reason, privacy: .public)") }
            withAnimation(.easeOut(duration: 0.15)) {
                batchReport = .make(title: String(localized: "有 \(restore.failed.count) 个项目无法放回原位", comment: "撤销批量删除部分失败的提示框标题；%lld 是数量"),
                                    message: restore.restored.isEmpty ? nil
                                        : String(localized: "其余 \(restore.restored.count) 项已经放回，现在处于选中。", comment: "撤销批量删除部分失败的提示框正文；%lld 是数量"),
                                    failures: restore.failed, actionTitle: String(localized: "打开废纸篓"), action: .openTrash)
            }
        }
    }

    /// 一批做完：如果用户在这期间要求退出，现在放行（spec X3-08）
    func batchDidEnd() {
        if terminateAfterBatch {
            terminateAfterBatch = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: - 后面几步补上

    /// 在空白处点右键（spec M5-01）：选择不变
    func showGridBlankMenu() {
        guard canShowGridMenu, hasOpenedFolder else { return }
        var entries: [ContextMenuPresenter.Entry] = [
            .init(title: String(localized: "全选"), shortcut: MenuShortcut(key: "a", command: true), enabled: !items.isEmpty) { [weak self] in self?.selectAllInGrid() },
            .separator,
            // 当前视图打勾，G 只标在另一项上
            .init(title: String(localized: "画廊视图"), shortcut: MenuShortcut(key: "g"), enabled: canSwitchView) { [weak self] in self?.setViewMode(.gallery) },
            .init(title: String(localized: "图标视图"), checked: true) {},
            .separator,
            .init(title: String(localized: "放大缩略图"), shortcut: MenuShortcut(key: "+", command: true), enabled: gridSize != GridSize.allCases.last) { [weak self] in self?.stepGridSize(larger: true) },
            .init(title: String(localized: "缩小缩略图"), shortcut: MenuShortcut(key: "-", command: true), enabled: gridSize != GridSize.allCases.first) { [weak self] in self?.stepGridSize(larger: false) },
        ]
        if let folder = folderURL {
            entries += [.separator, .init(title: String(localized: "在访达中显示“\(folder.lastPathComponent)”", comment: "空白处右键菜单；%@ 是文件夹名")) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }]
        }
        ContextMenuPresenter.show(entries: entries)
    }

    /// 把选中的文件拖出窗口（spec X8）：被拖的没选中时先改为只选中它；拖出去是拷贝，原文件不动，不带 .xmp
    func beginGridDrag(_ item: MediaItem, event: NSEvent, from view: NSView) {
        guard isGrid, !batchRunning, !batchModalOpen, pendingDelete == nil else { return }
        if !grid.selection.contains(item.url) { gridClick(item.url, command: false, shift: false) }
        let files = selectedItems.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !files.isEmpty else { return }
        // 被拖的那一张排最前，鼠标带着它和另外两张叠在一起（spec X8-02）
        let ordered = [item] + files.filter { $0 != item }
        let origin = view.convert(event.locationInWindow, from: nil)
        let dragItems = ordered.enumerated().map { index, file -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let size = CGSize(width: 96, height: 64)
            let offset = CGFloat(min(index, 2)) * 6
            let frame = CGRect(x: origin.x - size.width / 2 + offset, y: origin.y - size.height / 2 + offset, width: size.width, height: size.height)
            if index < 3, let image = ThumbnailStore.shared.cached(file)?.image {
                dragItem.setDraggingFrame(frame, contents: NSImage(cgImage: image, size: size))
            } else {
                dragItem.setDraggingFrame(frame, contents: nil)
            }
            return dragItem
        }
        gridDragging = Set(files.map(\.url))
        let source = GridDragSource { [weak self] in self?.gridDragging = [] }
        gridDragSource = source
        let session = view.beginDraggingSession(with: dragItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    // MARK: - 批量评星（spec X7）

    /// 多选时按 1–5 / 0：选中的图片全部设成这个星级，视频跳过，已经是这个星级的不动（spec X7-01）。
    /// 评星关掉时没有任何反应（spec X7-06）
    func rateSelection(_ value: Int) {
        guard ratingEnabled, isMultiSelection, !batchRunning, !batchModalOpen, pendingDelete == nil, edit == nil else { return }
        let selected = selectedItems
        let photos = selected.filter(RatingFileIO.isRatable)
        let skipped = selected.count - photos.count
        // 选中的全是视频：和单张一样，1–5 给一句提示，0 什么都不做
        guard !photos.isEmpty else {
            if value > 0 { showToast(symbol: "video", text: String(localized: "视频暂不支持评星"), solid: true, duration: 1.6) }
            return
        }
        dismissHint(.shortcutsChanged)
        let changes = photos.compactMap { item -> RatingChange? in
            let old = ratings[item.url] ?? 0
            return old == value ? nil : RatingChange(item: item, old: old, new: value)
        }
        // 整个位置不可写：一张都不改（spec X7-04、v0.3 S-14）
        guard folderWritable else {
            showBatchRatingFailure(changes.isEmpty ? photos.count : changes.count)
            return
        }
        // 闪现和提示写实际改动的张数；一张都不用改时写选中的图片数
        let shown = changes.isEmpty ? photos.count : changes.count
        flash(value, count: shown)
        if !changes.isEmpty {
            serial += 1
            let id = serial
            // 整批一条撤销记录（spec X7-03）
            undoHistory.push(.ratingBatch(RatingBatchUndo(id: id, changes: changes)))
            ratingBatches[id] = RatingBatchProgress(pending: changes.count)
            for change in changes { setRating(value, for: change.item, old: change.old, recordUndo: false, batch: id, refresh: false) }
            // 一起刷新一次结果列表：不再符合筛选条件的全部暂留（spec X7-05）
            ratingsDidChange()
        }
        let text = skipped > 0
            ? String(localized: "已给 \(shown) 张图片评 \(value) 星，\(skipped) 个视频已跳过", comment: "批量评星后的提示条：张数、星级、跳过的视频数")
            : String(localized: "已给 \(shown) 张图片评 \(value) 星", comment: "批量评星后的提示条：张数、星级")
        showToast(symbol: "star", text: text,
                  detail: changes.isEmpty ? nil : String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"),
                  action: changes.isEmpty ? nil : .undo, duration: 4)
    }

    /// 批量评星里一个文件写完了（成功、失败或被后来的评星取代）。整批写完后：没写成的从撤销记录里拿掉，
    /// 给一句汇总提示（spec X7-04）。失败的文件界面上的星级由 writeFinished 恢复原状
    func batchRatingWriteFinished(_ id: Int, item: MediaItem, outcome: RatingWriter.Outcome, owned: Bool) {
        guard var progress = ratingBatches[id] else { return }
        progress.pending -= 1
        if case .failed(let error) = outcome {
            progress.failed.insert(item.url)
            // 文件已经不在了：不算「无法保存」，只是撤销时不用管它
            if error != .vanished { progress.reported += 1 }
        }
        guard progress.pending <= 0 else {
            ratingBatches[id] = progress
            return
        }
        ratingBatches[id] = nil
        guard !progress.failed.isEmpty else { return }
        undoHistory.dropFromRatingBatch(id, urls: progress.failed)
        if owned, progress.reported > 0 { showBatchRatingFailure(progress.reported) }
    }

    /// 「有 N 张的星级无法保存：此位置不可写」（spec X7-04）
    private func showBatchRatingFailure(_ count: Int) {
        showToast(symbol: "exclamationmark.triangle",
                  text: String(localized: "有 \(count) 张的星级无法保存：此位置不可写", comment: "批量评星有文件写不进去的提示条；%lld 是数量"),
                  tone: .warning, solid: true, duration: 4)
    }

    /// ⌘Z 撤销批量评星：每张恢复成原来的星级（spec X7-03）。已经不在这个文件夹的跳过
    func undoRatingBatch(_ batch: RatingBatchUndo) {
        var touched = false
        for change in batch.changes {
            guard let item = allItems.first(where: { $0.url == change.item.url }) else { continue }
            setRating(change.old, for: item, old: ratings[item.url] ?? change.new, recordUndo: false, refresh: false)
            touched = true
        }
        if touched { ratingsDidChange() }
    }
}

/// 一次批量评星的写盘进度（spec X7-04）
struct RatingBatchProgress: Equatable {
    /// 还没写完的文件数
    var pending: Int
    /// 没写成的文件（界面已恢复原星级，要从撤销记录里拿掉）
    var failed: Set<URL> = []
    /// 其中要告诉用户「无法保存」的个数（文件已经不在的不算）
    var reported = 0
}

/// 拖出文件的来源（spec X8-03、X8-04）：拖到别的程序是拷贝；一览自己的窗口不接受
final class GridDragSource: NSObject, NSDraggingSource {
    private let onEnd: @MainActor () -> Void
    init(onEnd: @escaping @MainActor () -> Void) { self.onEnd = onEnd }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { onEnd() }
    }
}
