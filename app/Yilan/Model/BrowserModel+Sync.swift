import SwiftUI

/// 文件夹变化同步（设计稿 08 · 文件夹变化同步）
extension BrowserModel {
    func startWatching(_ folder: URL) {
        stopWatching()
        // 跑单元测试时一览是宿主程序：测试自己会直接调用 applySync
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        watcher = FolderWatcher(folder: folder) { [weak self] in self?.folderDidChange() }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        syncTask?.cancel()
        syncTask = nil
    }

    /// 文件夹有变化：等 0.3 秒（期间又有变化就再等），合并成一次重新扫描
    func folderDidChange() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let folder = folderURL else { return }
            let serial = localChangeSerial
            let scanned = await Task.detached(priority: .utility) { () -> ([MediaItem], SidecarIndex)? in
                guard let items = try? FolderScanner.scan(folder: folder) else { return nil }
                return (items, SidecarIndex.scan(folder: folder, media: items))
            }.value
            guard !Task.isCancelled, folder == folderURL, let scanned else { return }
            // 扫描期间一览自己删除、恢复了文件或写了星级：结果可能已经过时，重新扫一次
            if serial != localChangeSerial || trashBusy || pendingRatingWrites > 0 {
                folderDidChange()
                return
            }
            applySync(scanned.0, sidecars: scanned.1)
        }
    }

    /// 用新的扫描结果更新列表（测试里直接调用）。
    /// 当前文件还在就不动；被改名时继续显示它；被删除或移走时显示相邻的一个
    func applySync(_ scannedItems: [MediaItem], sidecars newSidecars: SidecarIndex? = nil) {
        // 一览自己写星级改了的文件（大小变了、修改时间没变）：当作没变，沿用原来的条目（技术方案 3.4、4.5）
        let oldByPath = Dictionary(allItems.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let scanned = scannedItems.map { item -> MediaItem in
            guard let old = oldByPath[item.url.path], old.fileSize != item.fileSize || old.modificationDate != item.modificationDate,
                  ownWrites.consume(path: item.url.path, size: item.fileSize, modificationDate: item.modificationDate)
            else { return item }
            return old
        }
        // 小文件的变化：一览自己写的跳过，其他软件改的要重读主人的星级（spec R4-06）
        var reread: [MediaItem] = []
        if let newSidecars {
            for name in newSidecars.changedNames(comparedTo: sidecars) {
                let entry = newSidecars.entries[name]
                let own = entry.map { ownWrites.consume(path: $0.url.path, size: $0.size, modificationDate: $0.modificationDate) }
                    ?? ownWrites.consumeRemoval(path: sidecars.entries[name]?.url.path ?? "")
                if !own { reread += newSidecars.owners(ofSidecarNamed: name, in: scanned) }
            }
            sidecars = newSidecars
        }
        let diff = FolderDiff(old: allItems, new: scanned)
        // 内容被其他程序改了的文件、新出现的文件：重读星级
        reread += diff.modified + diff.added + diff.renamed.values
        rereadRatings(Array(Set(reread)))
        guard !diff.isEmpty else { return }
        forgetCaches(for: diff.changedURLs)

        var target = current
        var replacement: (item: MediaItem, isNext: Bool)?
        var currentGone = false
        if let cur = current {
            if let same = scanned.first(where: { $0.url == cur.url }) {
                target = same                      // 还在（内容变了时会原地重新加载）
            } else if let renamed = diff.renamed[cur] {
                target = renamed                   // 改名：视为同一个文件，不提示
            } else {
                currentGone = true
                replacement = SyncSelection.replacement(for: cur, oldList: items, newList: scanned.filter { filter.includes($0) && matchesBrowseFilter($0) })
                target = replacement?.item
            }
        }
        replaceItems(scanned, showing: target)

        if currentGone {
            let detail: String? = switch replacement?.isNext {
            case true?: String(localized: "已显示下一个")
            case false?: String(localized: "已显示上一个")
            case nil: nil
            }
            showToast(symbol: "info.circle", text: String(localized: "当前文件已被删除或移走"), detail: detail, duration: 4)
        } else if !diff.added.isEmpty {
            showToast(symbol: "folder", text: String(localized: "新增 \(diff.added.count) 个文件"), duration: 3)
        }
        markFresh(diff.added.map(\.url))
    }

    /// 新文件的缩略图高亮 2 秒，然后淡回普通样式
    private func markFresh(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        freshURLs.formUnion(urls)
        freshTask?.cancel()
        freshTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { freshURLs = [] }
        }
    }
}
