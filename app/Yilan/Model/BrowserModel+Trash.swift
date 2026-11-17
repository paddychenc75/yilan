import AppKit
import SwiftUI

/// 移到废纸篓和撤销（设计稿 08 · 删除到废纸篓）
extension BrowserModel {
    /// 菜单项和 ⌫ 是否可用：主窗口在前、有当前文件、没有在等确认
    var canDelete: Bool { current != nil && pendingDelete == nil && mainWindowIsKey }
    var canUndoDelete: Bool { canUndo }

    /// ⌫ / ⌘⌫ / 菜单：按设置先弹确认框，或者直接删
    func requestDelete() {
        guard let item = current, pendingDelete == nil, !trashBusy else { return }
        // 视频正在播放时也可以删：先暂停再弹出确认
        if video.isPlaying { video.pause() }
        if settings.confirmBeforeDelete {
            deleteDontAsk = false
            withAnimation(.easeOut(duration: 0.15)) { pendingDelete = item }
        } else {
            Task { await performDelete(item) }
        }
    }

    /// 确认框：移到废纸篓（Return）
    func confirmDelete() {
        guard let item = pendingDelete else { return }
        if deleteDontAsk { settings.confirmBeforeDelete = false }
        withAnimation(.easeOut(duration: 0.12)) { pendingDelete = nil }
        Task { await performDelete(item) }
    }

    /// 确认框：取消（Esc）
    func cancelDelete() {
        withAnimation(.easeOut(duration: 0.12)) { pendingDelete = nil }
    }

    /// 移到废纸篓；成功后显示下一个（已是最后一个时显示上一个），提示可以撤销
    func performDelete(_ item: MediaItem) async {
        guard !trashBusy else { return }
        trashBusy = true
        localChangeSerial += 1
        defer {
            trashBusy = false
            localChangeSerial += 1
        }
        let url = item.url
        let sidecar = sidecars.sidecarToMoveWith(item).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws -> TrashEntry in
                let trashed = try TrashService.trash(url)
                var entry = TrashEntry(item: item, trashedURL: trashed)
                // 照片进了废纸篓，它的 .xmp 小文件也一起进（spec S-23）；小文件失败不影响删除
                if let sidecar, let t = try? TrashService.trash(sidecar) { entry.sidecar = (sidecar, t) }
                return entry
            }
        }.value
        switch result {
        case .success(let entry):
            undoHistory.push(.trash(entry))
            if let side = entry.sidecar { sidecars.noteRemoved(side.original) }
            removeAfterDelete(item)
            showToast(symbol: "trash", text: String(localized: "已移到废纸篓"),
                      detail: String(localized: "⌘Z 撤销", comment: "删除后提示条里可以点的链接"),
                      action: .undoDelete, duration: 4)
        case .failure(let error):
            Log.app.error("移到废纸篓失败 \(item.name, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            showToast(symbol: "exclamationmark.triangle",
                      text: String(localized: "无法移到废纸篓：\(error.localizedDescription)", comment: "%@ 是系统给出的原因"),
                      duration: 4)
        }
    }

    /// 从列表里拿掉删除的文件，显示相邻的一个
    private func removeAfterDelete(_ item: MediaItem) {
        let newAll = allItems.filter { $0.url != item.url }
        var target = current
        if current?.url == item.url {
            let oldIndex = items.firstIndex { $0.url == item.url } ?? currentIndex ?? 0
            let newList = filter.apply(newAll)
            target = DeleteSelection.index(afterRemoving: oldIndex, newCount: newList.count).map { newList[$0] }
        }
        forgetMetadata(for: [item.url])
        replaceItems(newAll, showing: target)
    }

    /// ⌘Z / 提示条里的“撤销”：把最近删除的文件从废纸篓放回原处并显示它
    func undoDelete() async {
        guard case .trash(let entry)? = undoHistory.last, !trashBusy, pendingDelete == nil else { return }
        trashBusy = true
        localChangeSerial += 1
        defer {
            trashBusy = false
            localChangeSerial += 1
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws -> MediaItem? in
                try TrashService.restore(entry)
                return FolderScanner.item(at: entry.item.url)
            }
        }.value
        undoHistory.pop()
        if let side = entry.sidecar, FileManager.default.fileExists(atPath: side.original.path) { sidecars.noteWritten(side.original) }
        switch result {
        case .success(let restored):
            hideToast()
            // 期间换了文件夹：文件已经放回去了，只是不在眼前，不用显示
            // 比较路径而不是 URL：目录 URL 末尾有没有“/”、/tmp 和 /private/tmp 都算同一个
            guard let restored, let folder = folderURL,
                  restored.url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
            else { return }
            var newAll = allItems.filter { $0.url != restored.url }
            newAll.append(restored)
            replaceItems(FolderScanner.naturalSorted(newAll), showing: restored)
        case .failure(let error):
            Log.app.error("撤销删除失败 \(entry.item.name, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            showToast(symbol: "exclamationmark.triangle",
                      text: String(localized: "无法撤销：\(error.localizedDescription)", comment: "%@ 是原因"),
                      duration: 4)
        }
    }

    /// 菜单“编辑 › 撤销”：主窗口在前时撤销删除；设置窗口在前时交给输入框自己的撤销
    func undoFromMenu() {
        if mainWindowIsKey {
            Task { await undoLast() }
        } else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        }
    }

    func redoFromMenu() {
        if !mainWindowIsKey { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
    }
}
