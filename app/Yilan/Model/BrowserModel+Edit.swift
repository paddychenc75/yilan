import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 编辑模式：进入、退出、按键、保存、撤销、浏览时的「保存旋转」（spec 21）
extension BrowserModel {
    // MARK: - 能不能编辑

    var isEditing: Bool { edit != nil }

    /// 可编辑：图片，且不是 GIF、SVG（spec ED-02）、不是 RAW（spec C6-01：RAW 只看不改，要编辑先导出为 JPEG）
    nonisolated static func isEditable(_ item: MediaItem) -> Bool {
        item.kind == .image && item.format != .gif && item.format != .svg && item.format != .raw
    }

    /// 当前文件现在能进入编辑：可编辑、没出错、大图已经显示
    var canEditCurrent: Bool {
        guard let item = current, Self.isEditable(item), failure == nil else { return false }
        // 相机预览图不能编辑（spec C2-01）：编辑会把低一档的预览图当成原片存出去
        return displayedItem == item && displayed != nil && !showingStaleDisplay && displayed?.isCameraPreview != true
    }

    /// 编辑按钮是不是置灰（文件类型不支持或出错）；大图还在加载时不置灰
    var editUnsupported: Bool {
        guard let item = current else { return true }
        return !Self.isEditable(item) || failure != nil || showingCameraPreview
    }

    /// 编辑按钮置灰的原因是 RAW：悬停提示先导出（spec C6-01）。相机预览图状态仍用它自己的提示（TX-09），由界面先判断
    var editBlockedByRaw: Bool { current?.format == .raw }

    // MARK: - 进入、退出

    /// E、编辑按钮、菜单（spec ED-03）
    func enterEdit() {
        // 编辑关掉后 E、菜单都进不来（spec T2-12）
        guard editEnabled, edit == nil, canEditCurrent, let item = current, let shown = displayed, pendingDelete == nil else { return }
        if filterPanelOpen { closeFilterPanel() }
        if infoVisible { setInfoVisible(false) }
        if video.isPlaying { video.pause() }
        rotationMenuOpen = false
        dismissHint()
        hideToast()
        let session = EditSession(item: item, imageSize: PixelSize(shown.pixelSize), turns: rotation)
        withAnimation(.easeOut(duration: 0.2)) { edit = session }
        noteMouseActivity()
        let url = item.url
        Task {
            let info = await Task.detached(priority: .userInitiated) { EditWriter.sourceInfo(url) }.value
            if edit === session { session.source = info }
        }
    }

    /// Esc、「取消」（spec ED-07）：放弃编辑，不产生任何文件
    func cancelEdit() {
        guard let session = edit, !session.saving else { return }
        withAnimation(.easeOut(duration: 0.2)) { edit = nil }
        // 回到进入编辑前的显示旋转
        rotation = session.startTurns
    }

    // MARK: - 按键（spec ED-07 ~ ED-09、ED-15 ~ ED-18、ED-26 ~ ED-30）

    func handleEditKey(_ event: NSEvent) -> Bool {
        guard let s = edit else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isEsc = event.keyCode == 53
        // 保存失败的提示框：回车 / Esc = 好
        if s.failure != nil {
            if isReturn || isEsc { s.failure = nil }
            return mods.isEmpty || isReturn || isEsc
        }
        // 替换确认框：回车 = 替换，Esc 回到编辑
        if s.confirmReplace {
            if isReturn { confirmReplace() }
            if isEsc { s.confirmReplace = false }
            return mods.isEmpty || isReturn || isEsc
        }
        if s.saving { return mods.isEmpty || isReturn }
        // 尺寸面板开着：按键交给输入框（数字、回车），只接 Esc
        if s.resizeOpen {
            if isEsc { s.resizeOpen = false; return true }
            return false
        }
        if isEsc {
            if s.anyPopupOpen { s.closePopups() } else { cancelEdit() }
            return true
        }
        if isReturn {
            if mods == [.option] { requestReplace() } else if mods.isEmpty { saveEdit() }
            return true
        }
        // ⌘⌫ 复原
        if event.keyCode == 51 {
            if mods == [.command] { s.reset() }
            return true
        }
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": zoom(.zoomIn); return true
            case "-", "−": zoom(.zoomOut); return true
            case "0": zoom(.actualSize); return true
            case "9": zoom(.fit); return true
            default: return false   // ⌘Q、⌘W 等交给菜单（编辑中会改文件的菜单项已置灰）
            }
        }
        guard mods.isEmpty else { return true }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": rotate(event.modifierFlags.contains(.shift) ? -1 : 1)
        case "x": s.swapOrientation()
        case "z": zoom(.toggle)
        default: break   // 方向键、数字键、⌫、T、I、F 等：编辑中不起作用
        }
        return true
    }

    // MARK: - 保存

    enum EditSaveMode: Sendable {
        case copy
        case replace
        /// 「存到其他位置…」
        case elsewhere(URL)
    }

    /// 回车、保存按钮左半（spec ED-27）
    func saveEdit() { performEditSave(.copy) }

    /// ⌥回车、菜单「替换原图…」：先确认（spec ED-30）
    func requestReplace() {
        guard let s = edit, !s.saving, s.target.canReplaceOriginal else { return }
        s.closePopups()
        s.confirmReplace = true
    }

    func confirmReplace() {
        guard let s = edit else { return }
        s.confirmReplace = false
        performEditSave(.replace)
    }

    /// 保存失败框里的「存到其他位置…」：系统存储面板
    func saveEditElsewhere() {
        guard let s = edit else { return }
        s.failure = nil
        let panel = NSSavePanel()
        let target = s.target
        panel.nameFieldStringValue = EditNaming.copyURL(for: s.item.url, ext: target.pathExtension).lastPathComponent
        if let type = UTType(target.typeIdentifier) { panel.allowedContentTypes = [type] }
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performEditSave(.elsewhere(url))
    }

    /// session 不是当前编辑（浏览时「保存旋转」另存副本）时：不进编辑界面，失败用提示条
    private func performEditSave(_ mode: EditSaveMode, session: EditSession? = nil) {
        guard let s = session ?? edit, !s.saving, !trashBusy else { return }
        let inEditor = s === edit
        s.closePopups()
        let plan = s.plan, target = s.target, item = s.item
        if case .replace = mode, !target.canReplaceOriginal { return }
        s.saving = true
        // 评星关掉时内存里没有星级：保存那一刻现读原图的（spec T2-08），不然副本会丢星
        let knownRating: (value: Int, fromSidecar: Bool)? = ratingEnabled
            ? (ratings[item.url] ?? 0, ratingInfo[item.url]?.sidecar != nil) : nil
        let sidecarIndex = sidecars
        let mode2 = settings.ratingStorage
        let media = allItems
        let sidecarList = Array(sidecars.entries.values)
        let folder = item.url.deletingLastPathComponent()
        trashBusy = true
        localChangeSerial += 1
        Task {
            defer {
                trashBusy = false
                localChangeSerial += 1
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<EditSaveOutcome, EditSaveError> in
                let rating: Int, ratingFromSidecar: Bool
                if let knownRating {
                    (rating, ratingFromSidecar) = knownRating
                } else {
                    let info = RatingFileIO.read(item, sidecars: sidecarIndex)
                    (rating, ratingFromSidecar) = (info.value, info.sidecar != nil)
                }
                do {
                    switch mode {
                    case .copy, .elsewhere:
                        let url: URL
                        if case .elsewhere(let dest) = mode {
                            try EditWriter.save(plan, target: target, to: dest)
                            url = dest
                        } else {
                            url = try EditWriter.saveCopy(plan, target: target)
                        }
                        // 星级带到新文件（按设置，默认写新文件旁的 .xmp，spec ED-35）
                        let sameFolder = url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
                        var write: RatingFileIO.WriteResult?
                        if rating > 0, let fresh = FolderScanner.item(at: url) {
                            let index = SidecarIndex(folder: url.deletingLastPathComponent(), sidecars: sameFolder ? sidecarList : [],
                                                     media: (sameFolder ? media : []) + [fresh])
                            do { write = try RatingFileIO.write(rating, for: fresh, mode: mode2, sidecars: index) }
                            catch { Log.app.error("编辑后的文件写星级失败：\(error.localizedDescription, privacy: .public)") }
                        }
                        return .success(EditSaveOutcome(url: url, item: FolderScanner.item(at: url), rating: write, trash: nil, sourceRating: rating))
                    case .replace:
                        let entry = try EditWriter.replaceOriginal(plan, target: target, item: item)
                        // 内嵌的星级不会跟着重新编码：原来写在文件里的，重写一次（.xmp 小文件原样留着）
                        var write: RatingFileIO.WriteResult?
                        if rating > 0, !ratingFromSidecar, let fresh = FolderScanner.item(at: item.url) {
                            let index = SidecarIndex(folder: folder, sidecars: sidecarList, media: media)
                            do { write = try RatingFileIO.write(rating, for: fresh, mode: mode2, sidecars: index) }
                            catch { Log.app.error("编辑后的文件写星级失败：\(error.localizedDescription, privacy: .public)") }
                        }
                        return .success(EditSaveOutcome(url: item.url, item: FolderScanner.item(at: item.url), rating: write, trash: entry, sourceRating: rating))
                    }
                } catch {
                    return .failure(EditSaveError.from(error, folder: folder))
                }
            }.value
            switch result {
            case .success(let outcome):
                editSaved(outcome, mode: mode, session: s, rating: outcome.sourceRating)
            case .failure(let error):
                Log.app.error("编辑保存失败 \(item.name, privacy: .public)：\(error.message, privacy: .public)")
                s.saving = false
                if inEditor {
                    // 停在编辑模式，改动保留（spec ED-40）
                    s.failure = error
                } else {
                    showToast(symbol: "exclamationmark.triangle",
                              text: String(localized: "没能保存旋转：\(error.message)", comment: "%@ 是原因"),
                              tone: .warning, solid: true, duration: 4)
                }
            }
        }
    }

    /// 保存成功：退出编辑，显示新文件，提示可撤销（spec ED-37、ED-38）
    private func editSaved(_ outcome: EditSaveOutcome, mode: EditSaveMode, session s: EditSession, rating: Int) {
        let original = s.item
        if edit === s { withAnimation(.easeOut(duration: 0.2)) { edit = nil } }
        // 替换原图：新图解码好之前，旧画面按编辑时转的方向留着（裁切、缩小要等新图换上才看得到）
        if case .replace = mode, outcome.item != nil { rotation = s.turns } else { rotation = 0 }
        noteRatingWrite(outcome.rating, url: outcome.url, rating: rating)
        let name = outcome.url.lastPathComponent
        switch mode {
        case .replace:
            guard let entry = outcome.trash else { return }
            undoHistory.push(.edit(.replace(entry)))
            forgetCaches(for: [original.url])
            if let fresh = outcome.item {
                replaceItems(allItems.map { $0.url == original.url ? fresh : $0 }, showing: fresh)
            }
            showToast(symbol: "checkmark.circle", text: String(localized: "已替换原图，原图在废纸篓"),
                      action: .undoEdit, bottom: true, duration: 6)
        case .copy, .elsewhere:
            let sidecar = outcome.rating?.createdSidecar
            undoHistory.push(.edit(.copy(original: original, created: outcome.url, sidecar: sidecar)))
            if let fresh = outcome.item, isInCurrentFolder(fresh.url) {
                var all = allItems.filter { $0.url != fresh.url }
                all.append(fresh)
                replaceItems(FolderScanner.naturalSorted(all), showing: fresh)
                markFresh([fresh.url])
                showToast(symbol: "checkmark.circle",
                          text: String(localized: "已另存为「\(name)」，原图在左边一张", comment: "另存副本成功；%@ 是新文件名"),
                          action: .undoEdit, bottom: true, duration: 6)
            } else {
                showToast(symbol: "checkmark.circle",
                          text: String(localized: "已另存为「\(name)」", comment: "存到其他文件夹成功；%@ 是新文件名"),
                          action: .undoEdit, bottom: true, duration: 6)
            }
        }
    }

    /// 新文件的星级写好了：更新界面和小文件索引（编辑另存、RAW 导出共用）
    func noteRatingWrite(_ write: RatingFileIO.WriteResult?, url: URL, rating: Int) {
        guard let write else { return }
        ownWrites.record(write.stamps())
        for touched in write.touched where touched.pathExtension.lowercased() == "xmp" { sidecars.noteWritten(touched) }
        ratings[url] = rating
        persistedRatings[url] = rating
        var info = RatingInfo.unrated
        info.value = rating
        if case .sidecar(let side) = write.location { info.sidecarURL = side; info.sidecar = rating } else { info.embedded = rating }
        ratingInfo[url] = info
        ratingsDidChange()
    }

    func isInCurrentFolder(_ url: URL) -> Bool {
        guard let folder = folderURL else { return false }
        return url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
    }

    // MARK: - 撤销（spec ED-39、ED-42）

    func undoEdit(_ entry: EditUndo) async {
        guard !trashBusy else { return }
        trashBusy = true
        localChangeSerial += 1
        defer {
            trashBusy = false
            localChangeSerial += 1
        }
        if case .rotation(_, _, _, let backup) = entry { backupInUse = backup }
        undoHistory.pop()
        hideToast()
        switch entry {
        // RAW 导出的撤销和另存副本一样（spec C6-10）
        case .copy(let original, let created, let sidecar), .export(let original, let created, let sidecar):
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    _ = try TrashService.trash(created)
                    if let sidecar, FileManager.default.fileExists(atPath: sidecar.path) { _ = try? TrashService.trash(sidecar) }
                }
            }.value
            if case .failure(let error) = result { return showUndoFailure(error) }
            if let sidecar { sidecars.noteRemoved(sidecar) }
            forgetCaches(for: [created])
            let all = allItems.filter { $0.url != created }
            replaceItems(all, showing: all.first { $0.url == original.url } ?? current)
        case .replace(let trashEntry):
            let url = trashEntry.item.url
            let result = await Task.detached(priority: .userInitiated) { () -> Result<MediaItem?, Error> in
                Result {
                    // 编辑后的文件进废纸篓，原图放回
                    let edited = try TrashService.trash(url)
                    do { try TrashService.restore(trashEntry) } catch {
                        try? FileManager.default.moveItem(at: edited, to: url)
                        throw error
                    }
                    return FolderScanner.item(at: url)
                }
            }.value
            switch result {
            case .failure(let error): return showUndoFailure(error)
            case .success(let restored):
                forgetCaches(for: [url])
                guard let restored else { return }
                replaceItems(allItems.map { $0.url == url ? restored : $0 }, showing: restored)
                rereadRatings([restored])
            }
        case .rotation(let url, let old, let new, let backup):
            let result = await Task.detached(priority: .userInitiated) { () -> Result<MediaItem?, Error> in
                Result {
                    // 成功、失败都用完了：这条记录已经去掉
                    defer { if let backup { RotationBackupStore.discard(backup) } }
                    if let backup {
                        try RotationBackupStore.restore(url, from: backup, old: old, new: new)
                    } else {
                        try EditWriter.setOrientation(url, to: old)
                    }
                    return FolderScanner.item(at: url)
                }
            }.value
            backupInUse = nil
            switch result {
            case .failure(let error): return showUndoFailure(error)
            case .success(let fresh): refreshAfterRewrite(url, fresh: fresh)
            }
        }
    }

    /// 撤销记录里已经没有的保存旋转：删掉它的原文件副本（正在撤销的那条除外）
    func discardDroppedBackups(old: UndoHistory) {
        let kept = undoHistory.rotationBackups
        for b in old.rotationBackups where !kept.contains(b) && b != backupInUse {
            Task.detached(priority: .utility) { RotationBackupStore.discard(b) }
        }
    }

    private func showUndoFailure(_ error: Error) {
        let reason = (error as? EditSaveError)?.message ?? error.localizedDescription
        Log.app.error("撤销编辑失败：\(reason, privacy: .public)")
        showToast(symbol: "exclamationmark.triangle", text: String(localized: "无法撤销：\(reason)", comment: "%@ 是原因"),
                  tone: .warning, solid: true, duration: 4)
    }

    /// 文件内容在原地被改了（保存旋转、撤销保存旋转）：清缓存，重新显示
    private func refreshAfterRewrite(_ url: URL, fresh: MediaItem?) {
        forgetCaches(for: [url])
        guard let fresh else { return }
        replaceItems(allItems.map { $0.url == url ? fresh : $0 }, showing: fresh)
    }

    // MARK: - 浏览时的「保存旋转」（spec ED-41 ~ ED-44）

    /// 胶囊要不要出现：浏览、转过、可编辑
    var showsSaveRotation: Bool {
        // 相机预览图：可以转着看，但不出「保存旋转」（spec C2-02）；RAW 都不出（isEditable，spec C6-02）
        editEnabled && edit == nil && rotation != 0 && current.map(Self.isEditable) == true && failure == nil && !showingCameraPreview
    }

    /// 当前文件能只改方向标记（JPEG、HEIC/HEIF、TIFF）
    var currentSupportsLosslessRotation: Bool {
        guard let item = current, item.format == .standard else { return false }
        return EditTarget.supportsOrientationOnly(EditSession.guessType(item.url))
    }

    /// 胶囊左半：能无损时改原图，否则另存副本
    func saveRotation() { saveRotation(toOriginal: currentSupportsLosslessRotation) }

    func saveRotation(toOriginal: Bool) {
        rotationMenuOpen = false
        guard showsSaveRotation, let item = current, !trashBusy, let shown = displayed, displayedItem == item else { return }
        let turns = rotation
        if toOriginal {
            guard currentSupportsLosslessRotation else { return }
            trashBusy = true
            localChangeSerial += 1
            Task {
                defer {
                    trashBusy = false
                    localChangeSerial += 1
                }
                let url = item.url
                let result = await Task.detached(priority: .userInitiated) { () -> Result<(Int, Int, MediaItem?, RotationBackup?), EditSaveError> in
                    // 先留一份原文件：撤销时原样放回，逐字节相同（F2-03）
                    let copy = RotationBackupStore.make(for: url)
                    do {
                        let (old, new) = try EditWriter.rotateInPlace(url, quarterTurns: turns)
                        let backup = copy.flatMap { c in DiskStamp(url).map { RotationBackup(copy: c, written: $0) } }
                        if backup == nil, let copy { try? FileManager.default.removeItem(at: copy) }
                        return .success((old, new, FolderScanner.item(at: url), backup))
                    } catch {
                        if let copy { try? FileManager.default.removeItem(at: copy) }
                        return .failure(EditSaveError.from(error, folder: url.deletingLastPathComponent()))
                    }
                }.value
                switch result {
                case .success(let (old, new, fresh, backup)):
                    undoHistory.push(.edit(.rotation(url: url, old: old, new: new, backup: backup)))
                    refreshAfterRewrite(url, fresh: fresh)
                    rotation = 0
                    showToast(symbol: "checkmark.circle", text: String(localized: "已保存旋转，画质不变"),
                              action: .undoEdit, bottom: true, duration: 6)
                case .failure(let error):
                    showToast(symbol: "exclamationmark.triangle",
                              text: String(localized: "没能保存旋转：\(error.message)", comment: "%@ 是原因"),
                              tone: .warning, solid: true, duration: 4)
                }
            }
            return
        }
        // 另存副本：等于在编辑模式里只转了方向就保存
        let session = EditSession(item: item, imageSize: PixelSize(shown.pixelSize), turns: turns)
        session.source = EditWriter.sourceInfo(item.url)
        performEditSave(.copy, session: session)
    }
}

/// 一次保存的结果（后台算好交回主线程）
struct EditSaveOutcome: Sendable {
    let url: URL
    let item: MediaItem?
    let rating: RatingFileIO.WriteResult?
    let trash: TrashEntry?
    /// 原图的星级（带到新文件上的那个值）
    var sourceRating = 0
}
