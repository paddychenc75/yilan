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
        let result = await Task.detached(priority: .userInitiated) {
            BatchTrash.run(jobs, stop: stop, trash: trash) { [weak self] done in
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

    /// 在空白处点右键（spec M5-01）
    func showGridBlankMenu() {}

    /// 把选中的文件拖出窗口（spec X8）
    func beginGridDrag(_ item: MediaItem, event: NSEvent, from view: NSView) {}

    /// 多选时按数字键（spec X7）。这一版没做批量评星时：不改任何星级，给一句提示（spec X7-07）
    func rateSelection(_ value: Int) {
        showToast(symbol: "star", text: String(localized: "一次只能给一张图片评星"), duration: 2)
    }
}
