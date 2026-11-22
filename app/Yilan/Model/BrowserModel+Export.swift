import Foundation

/// RAW「导出为 JPEG」（spec C6）：RAW 只看不改，要编辑先导出一张 JPEG
extension BrowserModel {
    /// 有没有这个功能：简洁模式里没有（spec C6-12），跟编辑一起开关
    var exportEnabled: Bool { editEnabled }

    /// 右键菜单、「⋯」菜单里出不出现这一项：当前是 RAW、不是多选（spec C6-03、C6-12）
    var showsExportItem: Bool { exportEnabled && !isMultiSelection && current?.format == .raw }

    /// 现在能不能导出（spec C6-03）：当前是 RAW，不是出错卡片、不是多选、不在编辑、不在导出
    var canExportCurrent: Bool {
        guard showsExportItem, edit == nil, exportingURL == nil, pendingDelete == nil, !batchRunning, !batchModalOpen else { return false }
        // 图标视图里没有出错卡片（failure 是画廊视图里大图的状态）
        return isGrid || failure == nil
    }

    /// 这张 RAW 已经知道处在相机预览图状态（spec C1-17：只记在内存里）
    private func knownCameraPreview(_ item: MediaItem) -> Bool {
        (showingCameraPreview && displayedItem == item) || cameraPreviewSeen.contains(item.url)
    }

    /// ⇧⌘E、菜单「导出为 JPEG」（spec C6-03 ~ C6-11）
    func exportCurrentAsJPEG() {
        guard canExportCurrent, let item = current else { return }
        let preview = knownCameraPreview(item)
        // 评星关掉时内存里没有星级：导出那一刻现读 RAW 的（同编辑另存，spec T2-08）
        let knownRating: Int? = ratingEnabled ? (ratings[item.url] ?? 0) : nil
        let sidecarIndex = sidecars
        let storage = settings.ratingStorage
        let media = allItems
        let sidecarList = Array(sidecars.entries.values)
        exportingURL = item.url
        localChangeSerial += 1
        // 一直显示到结束（spec C6-08）：结束时换成成功或失败的提示
        showToast(symbol: "square.and.arrow.up", text: String(localized: "正在导出为 JPEG…"), bottom: true, duration: 3600)
        Task {
            defer {
                exportingURL = nil
                localChangeSerial += 1
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ExportOutcome, EditSaveError> in
                let rating = knownRating ?? RatingFileIO.read(item, sidecars: sidecarIndex).value
                do {
                    let written = try RawExport.export(item, cameraPreview: preview)
                    // 星级带到导出的 JPEG（按设置里的保存位置，spec C6-07）；写不成不算导出失败
                    var write: RatingFileIO.WriteResult?
                    let fresh = FolderScanner.item(at: written.url)
                    if rating > 0, let fresh {
                        let index = SidecarIndex(folder: written.url.deletingLastPathComponent(), sidecars: sidecarList, media: media + [fresh])
                        do { write = try RatingFileIO.write(rating, for: fresh, mode: storage, sidecars: index) }
                        catch { Log.app.error("导出的 JPEG 写星级失败：\(error.localizedDescription, privacy: .public)") }
                    }
                    return .success(ExportOutcome(written: written, item: fresh, rating: write, sourceRating: rating))
                } catch {
                    return .failure(EditSaveError.from(error, folder: item.url.deletingLastPathComponent()))
                }
            }.value
            switch result {
            case .success(let outcome): exportFinished(outcome, from: item)
            case .failure(let error):
                Log.app.error("导出 JPEG 失败 \(item.name, privacy: .public)：\(error.message, privacy: .public)")
                showToast(symbol: "exclamationmark.triangle", text: String(localized: "无法导出：\(error.message)", comment: "导出为 JPEG 失败；%@ 是原因"),
                          tone: .warning, solid: true, duration: 4)
            }
        }
    }

    /// 导出成功（spec C6-09、C6-10）：还停在这张 RAW 上就跳到新文件，提示可撤销
    private func exportFinished(_ outcome: ExportOutcome, from raw: MediaItem) {
        let url = outcome.written.url
        let name = url.lastPathComponent
        let text = outcome.written.cameraPreview
            ? String(localized: "已把相机预览图导出为「\(name)」", comment: "导出相机预览图成功；%@ 是新文件名")
            : String(localized: "已导出为「\(name)」", comment: "RAW 导出为 JPEG 成功；%@ 是新文件名")
        // 导出期间换了文件夹：新文件不在眼前，撤销记录也已经换了一批，只提示
        guard let fresh = outcome.item, isInCurrentFolder(url) else {
            showToast(symbol: "checkmark.circle", text: text, bottom: true, duration: 6)
            return
        }
        noteRatingWrite(outcome.rating, url: url, rating: outcome.sourceRating)
        undoHistory.push(.edit(.export(original: raw, created: url, sidecar: outcome.rating?.createdSidecar)))
        var all = allItems.filter { $0.url != url }
        all.append(fresh)
        // 用户已经翻到别的文件、或者当前筛选条件把 JPEG 挡在外面：不跳，只提示
        let jump = current?.url == raw.url && filter.includes(fresh) && matchesBrowseFilter(fresh)
        replaceItems(FolderScanner.naturalSorted(all), showing: jump ? fresh : current)
        // 图标视图里选中集合说了算：改成只选中新文件，并滚到看得见
        if jump, isGrid { setGridSelection(GridSelection.click(fresh.url), scrollToFocus: true) }
        markFresh([url])
        showToast(symbol: "checkmark.circle", text: text, action: .undoEdit, bottom: true, duration: 6)
    }
}

/// 一次导出的结果（后台算好交回主线程）
struct ExportOutcome: Sendable {
    let written: RawExport.Written
    let item: MediaItem?
    let rating: RatingFileIO.WriteResult?
    /// RAW 的星级（带到新文件上的那个值）
    let sourceRating: Int
}
