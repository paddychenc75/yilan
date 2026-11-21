import AppKit
import SwiftUI

/// 复制到文件夹… / 移动到文件夹…（spec R9）。进度、停止、结束提示框沿用批量删除的一套（BrowserModel+Batch）
extension BrowserModel {
    /// 要复制 / 移动的文件：图标视图里是选中的（按列表顺序），画廊视图里是当前这一张
    var transferTargets: [MediaItem] {
        if isGrid { return selectedItems }
        return current.map { [$0] } ?? []
    }

    /// 菜单里两项能不能用：有文件，没有别的批量操作、确认框、编辑（spec X3-08）
    var canTransfer: Bool {
        !transferTargets.isEmpty && !batchRunning && !trashBusy && !batchModalOpen && pendingDelete == nil
            && pendingBatchDelete == nil && edit == nil && mainWindowIsKey
    }

    /// 菜单「复制到文件夹…」「移动到文件夹…」：先弹系统的选择文件夹面板，取消时什么都不发生（spec R9-02）
    func requestTransfer(_ mode: BatchTransfer.Mode) {
        guard canTransfer else { return }
        let targets = transferTargets
        guard let folder = chooseTransferFolder(mode, count: targets.count) else { return }
        settings.lastTransferFolder = folder
        Task { await performTransfer(mode, targets, to: folder) }
    }

    /// 系统的选择文件夹面板：标题「复制 N 项到…」，按钮「复制到这里」，可以新建文件夹，默认停在上次选的目标
    private func chooseTransferFolder(_ mode: BatchTransfer.Mode, count: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let title = mode == .copy
            ? String(localized: "复制 \(count) 项到…", comment: "选择目标文件夹面板的标题；%lld 是数量")
            : String(localized: "移动 \(count) 项到…", comment: "选择目标文件夹面板的标题；%lld 是数量")
        panel.title = title
        panel.message = title
        panel.prompt = mode == .copy ? String(localized: "复制到这里") : String(localized: "移动到这里")
        if let last = settings.lastTransferFolder, FileManager.default.fileExists(atPath: last.path) { panel.directoryURL = last }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 两个文件夹是同一个（/tmp 和 /private/tmp、末尾有没有「/」都算同一个）
    nonisolated static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 复制 / 移动到 folder。disk：测试里换成会在某一步失败的版本
    func performTransfer(_ mode: BatchTransfer.Mode, _ targets: [MediaItem], to folder: URL, disk: BatchTransfer.Disk = .live) async {
        guard !batchRunning, !trashBusy, !targets.isEmpty else { return }
        // 移动到它们本来就在的文件夹：提示一句，不做任何事（spec R9-03）。复制照常进行，得到带序号的副本
        if mode == .move, targets.allSatisfy({ Self.sameFolder($0.url.deletingLastPathComponent(), folder) }) {
            showToast(symbol: "folder", text: String(localized: "这些文件已经在这个文件夹里"), duration: 3)
            return
        }
        // 小文件跟着走，共用小文件的规则同批量删除（spec R9-04、X3-06）
        let jobs = BatchTrash.jobs(for: targets, sidecars: sidecars)
        let stop = BatchTrash.StopFlag()
        batchStop = stop
        batchProgress = BatchProgress(kind: mode == .copy ? .copy : .move, total: targets.count)
        // 进行中暂停对文件夹变化的自动刷新（spec X3-09）
        trashBusy = true
        localChangeSerial += 1
        // 超过 1 秒还没做完才显示进度条（spec R9-06、X3-07）
        let reveal = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, batchProgress != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { batchProgress?.visible = true }
        }
        let outcome = await Task.detached(priority: .userInitiated) { () -> (BatchTransfer.Result, [MediaItem]) in
            let result = BatchTransfer.run(jobs, to: folder, mode: mode, stop: stop, disk: disk) { [weak self] done in
                Task { @MainActor in self?.batchProgress?.done = done }
            }
            // 复制到眼前这个文件夹：新文件要出现在列表里
            let added = mode == .copy ? result.placed.compactMap { FolderScanner.item(at: $0.destination) } : []
            return (result, added)
        }.value
        reveal.cancel()
        batchStop = nil
        withAnimation(.easeOut(duration: 0.2)) { batchProgress = nil }
        trashBusy = false
        localChangeSerial += 1
        switch mode {
        case .copy: finishCopy(outcome.0, added: outcome.1, to: folder)
        case .move: finishMove(outcome.0, to: folder)
        }
        batchDidEnd()
    }

    /// 放到了眼前这个文件夹里的新文件：加进列表，选择不变
    private func addPlaced(_ result: BatchTransfer.Result, added: [MediaItem], to folder: URL) {
        guard let here = folderURL, Self.sameFolder(here, folder), !added.isEmpty else { return }
        for side in result.placed.compactMap(\.sidecar) { sidecars.noteWritten(side.destination) }
        let urls = Set(added.map(\.url))
        replaceItems(FolderScanner.naturalSorted(allItems.filter { !urls.contains($0.url) } + added), showing: isGrid ? nil : current)
    }

    private func finishCopy(_ result: BatchTransfer.Result, added: [MediaItem], to folder: URL) {
        let placed = result.placed
        addPlaced(result, added: added, to: folder)
        let name = folder.lastPathComponent
        if !result.failed.isEmpty {
            for f in result.failed { Log.app.error("复制失败 \(f.item.name, privacy: .public)：\(f.reason, privacy: .public)") }
            withAnimation(.easeOut(duration: 0.15)) {
                batchReport = .make(title: String(localized: "有 \(result.failed.count) 个项目无法复制", comment: "复制到文件夹有文件失败的提示框标题；%lld 是数量"),
                                    message: nil, failures: result.failed,
                                    actionTitle: String(localized: "在访达中显示"), action: .reveal(result.failed.map(\.item.url)))
            }
        } else if !result.untouched.isEmpty {
            showToast(symbol: "stop.circle",
                      text: String(localized: "已停止：\(placed.count) 项已复制，\(result.untouched.count) 项没有复制", comment: "复制到文件夹被停止后的提示条"),
                      detail: placed.isEmpty ? nil : String(localized: "在访达中显示"),
                      action: placed.isEmpty ? nil : .reveal(placed.map(\.destination)), duration: 4)
        } else if !placed.isEmpty {
            // 有重名加了序号时多说一句（spec R9-07）
            let renamed = placed.filter(\.renamed).count
            let text = renamed > 0
                ? String(localized: "已复制 \(placed.count) 项到“\(name)”，其中 \(renamed) 项重名，已加序号", comment: "复制到文件夹完成；数量、文件夹名、重名数")
                : String(localized: "已复制 \(placed.count) 项到“\(name)”", comment: "复制到文件夹完成；%lld 是数量，%@ 是文件夹名")
            showToast(symbol: "folder", text: text, detail: String(localized: "在访达中显示"),
                      action: .reveal(placed.map(\.destination)), duration: 4)
        }
    }

    private func finishMove(_ result: BatchTransfer.Result, to folder: URL) {
        let moved = result.placed
        if !moved.isEmpty {
            undoHistory.push(.moveBatch(moved))
            for side in moved.compactMap(\.sidecar) { sidecars.noteRemoved(side.source) }
            let gone = Set(moved.map(\.item.url))
            var target: MediaItem?
            if isGrid {
                // 焦点落在第一个被移走的文件原来的位置上现在的那一张（同 X3-10）
                if let first = items.first(where: { gone.contains($0.url) }) { grid.focus = first.url }
            } else if let cur = current, gone.contains(cur.url) {
                // 画廊视图：和单张删除一样显示下一张（已是最后一张时显示上一张）
                let oldIndex = items.firstIndex(of: cur) ?? 0
                let newList = items.filter { !gone.contains($0.url) }
                target = DeleteSelection.index(afterRemoving: oldIndex, newCount: newList.count).map { newList[$0] }
            } else {
                target = current
            }
            forgetMetadata(for: gone)
            // 列表一次性更新，选中集合里移走的自动去掉（spec R9-08）
            replaceItems(allItems.filter { !gone.contains($0.url) }, showing: target)
        }
        let name = folder.lastPathComponent
        if !result.failed.isEmpty {
            for f in result.failed { Log.app.error("移动失败 \(f.item.name, privacy: .public)：\(f.reason, privacy: .public)") }
            withAnimation(.easeOut(duration: 0.15)) {
                batchReport = .make(title: String(localized: "有 \(result.failed.count) 个项目无法移动", comment: "移动到文件夹有文件失败的提示框标题；%lld 是数量"),
                                    message: nil, failures: result.failed,
                                    actionTitle: String(localized: "在访达中显示"), action: .reveal(result.failed.map(\.item.url)))
            }
        } else if !result.untouched.isEmpty {
            showToast(symbol: "stop.circle",
                      text: String(localized: "已停止：\(moved.count) 项已移动，\(result.untouched.count) 项没有移动", comment: "移动到文件夹被停止后的提示条"),
                      detail: moved.isEmpty ? nil : String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"),
                      action: moved.isEmpty ? nil : .undo, duration: 4)
        } else if !moved.isEmpty {
            showToast(symbol: "folder", text: String(localized: "已移动 \(moved.count) 项到“\(name)”", comment: "移动到文件夹完成；%lld 是数量，%@ 是文件夹名"),
                      detail: String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"), action: .undo, duration: 4)
        }
    }

    /// ⌘Z：把移走的文件全部移回原位并选中；移不回的列出来（spec R9-08，样子同 X3-16、X3-17）。这条记录用完
    func undoMoveBatch(_ placed: [BatchTransfer.Placed], disk: BatchTransfer.Disk = .live) async {
        guard !trashBusy, !batchRunning, pendingDelete == nil else { return }
        trashBusy = true
        localChangeSerial += 1
        let result = await Task.detached(priority: .userInitiated) { () -> (BatchTransfer.RestoreResult, [MediaItem]) in
            let r = BatchTransfer.moveBack(placed, disk: disk)
            return (r, r.restored.compactMap { FolderScanner.item(at: $0.item.url) })
        }.value
        trashBusy = false
        localChangeSerial += 1
        undoHistory.pop()
        hideToast()
        let (restore, found) = result
        for entry in restore.restored {
            if let side = entry.sidecar, FileManager.default.fileExists(atPath: side.source.path) { sidecars.noteWritten(side.source) }
        }
        // 期间换了文件夹：文件已经移回去了，只是不在眼前
        let here = found.filter { item in
            guard let folder = folderURL else { return false }
            return Self.sameFolder(item.url.deletingLastPathComponent(), folder)
        }
        if !here.isEmpty {
            let urls = Set(here.map(\.url))
            let newAll = FolderScanner.naturalSorted(allItems.filter { !urls.contains($0.url) } + here)
            if isGrid {
                replaceItems(newAll, showing: nil)
                // 移回来的文件全部选中，第一张滚到可见
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
            for f in restore.failed { Log.app.error("移回失败 \(f.item.name, privacy: .public)：\(f.reason, privacy: .public)") }
            let failedURLs = Set(restore.failed.map(\.item.url))
            withAnimation(.easeOut(duration: 0.15)) {
                batchReport = .make(title: String(localized: "有 \(restore.failed.count) 个项目无法放回原位", comment: "撤销批量删除部分失败的提示框标题；%lld 是数量"),
                                    message: restore.restored.isEmpty ? nil
                                        : String(localized: "其余 \(restore.restored.count) 项已经放回，现在处于选中。", comment: "撤销批量删除部分失败的提示框正文；%lld 是数量"),
                                    failures: restore.failed, actionTitle: String(localized: "在访达中显示"),
                                    action: .reveal(placed.filter { failedURLs.contains($0.item.url) }.map(\.destination)))
            }
        }
    }
}
