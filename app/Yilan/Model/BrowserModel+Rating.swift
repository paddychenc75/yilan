import AppKit
import SwiftUI

/// 五星胶囊的一次闪现（按 0–5 或点星时）
struct RatingFlash: Equatable {
    /// 刚评的星级（0 = 清除），第 value 颗放大发光
    let value: Int
    let serial: Int
}

/// 顶部提示卡片（设计稿 1.4）：一次只显示一个，后来的排队
enum HintCard: Equatable {
    /// 从 v0.2 升级后第一次启动：快捷键变化（spec K-10）
    case shortcutsChanged
    /// 第一次为 RAW 创建 .xmp（spec S-17），带小文件名
    case sidecarCreated(String)
}

/// 评星：打星、写盘、读取、撤销、提示（spec 第 1–5、7 节）
extension BrowserModel {
    // MARK: - 状态

    /// 当前文件的星级（还没读出来时 nil）
    var currentRating: Int? { current.flatMap { ratings[$0.url] } }

    /// 当前文件能不能评星：显示错误卡片时不能（spec R1-09），位置不可写时不能（spec R1-10）
    var canRateCurrent: Bool { current != nil && failure == nil && folderWritable }

    /// 信息面板“保存位置”：内嵌写“文件内部”，小文件写文件名（spec R3-07）
    func ratingLocationDescription(for item: MediaItem) -> String {
        if let url = ratingInfo[item.url]?.sidecarURL, ratingInfo[item.url]?.sidecar != nil { return url.lastPathComponent }
        let usesSidecar = RatingFileIO.kind(for: item) == .sidecarOnly || settings.ratingStorage == .sidecar
        if usesSidecar { return sidecars.writeURL(for: item).lastPathComponent }
        return String(localized: "文件内部", comment: "信息面板：星级写在文件自己的信息区里")
    }

    // MARK: - 打星

    /// 给当前文件打星（键盘 1–5 / 0、点五星、菜单）
    func rateCurrent(_ value: Int, fromKeyboard: Bool) {
        guard let item = current, pendingDelete == nil else { return }
        dismissHint(.shortcutsChanged)
        guard failure == nil else {
            showRatingProblem(String(localized: "无法评星：文件无法读取"))
            return
        }
        guard folderWritable else {
            reportWriteFailure(.notWritable)
            return
        }
        let old = ratings[item.url] ?? 0
        flash(value)
        if value != old {
            setRating(value, for: item, old: old, recordUndo: true)
            if value == 0 {
                showToast(symbol: "star", text: String(localized: "已清除星级"), duration: 1.5)
            }
        }
        // 打星后自动下一张（spec R8-02）：只限键盘，相同数字也跳
        if fromKeyboard, settings.autoAdvanceAfterRating, canGoNext {
            next()
            flash(nil)
        }
    }

    /// 改星级：界面立即变化，写盘在后台（spec R1-02、S-05）
    func setRating(_ value: Int, for item: MediaItem, old: Int, recordUndo: Bool) {
        ratings[item.url] = value
        if recordUndo {
            undoHistory.push(.rating(RatingChange(item: item, old: old, new: value)))
            unconfirmedRatingEntries[item.url, default: 0] += 1
        }
        pendingRatingWrites += 1
        inFlightRatingWrites[item.url, default: 0] += 1
        let job = RatingWriter.Job(item: item, value: value, mode: settings.ratingStorage, sidecars: sidecars)
        let writer = ratingWriter
        Task {
            await writer.enqueue(job) { [weak self] outcome in
                await MainActor.run { self?.writeFinished(outcome, for: item, value: value) }
            }
        }
    }

    func writeFinished(_ outcome: RatingWriter.Outcome, for item: MediaItem, value: Int) {
        pendingRatingWrites = max(0, pendingRatingWrites - 1)
        inFlightRatingWrites[item.url] = max(0, (inFlightRatingWrites[item.url] ?? 1) - 1)
        if case .written(_, let stamps) = outcome { ownWrites.record(stamps) }
        guard ratingWriterOwns(item) else { return }
        localChangeSerial += 1
        switch outcome {
        case .written(let result, _):
            for url in result.touched where url.pathExtension.lowercased() == "xmp" {
                if FileManager.default.fileExists(atPath: url.path) { sidecars.noteWritten(url) } else { sidecars.noteRemoved(url) }
            }
            persistedRatings[item.url] = value
            unconfirmedRatingEntries[item.url] = 0
            var info = ratingInfo[item.url] ?? .unrated
            info.value = value
            if case .sidecar(let url) = result.location {
                info.sidecarURL = url
                info.sidecar = result.removedSidecar == nil ? value : nil
            } else {
                info.embedded = value
            }
            ratingInfo[item.url] = info
            if let created = result.createdSidecar, item.format == .raw, !settings.didShowSidecarHint {
                settings.didShowSidecarHint = true
                enqueueHint(.sidecarCreated(created.lastPathComponent))
            }
        case .superseded:
            break
        case .failed(let error):
            // 界面恢复成磁盘上的值；这些没写成的操作不进撤销记录（spec S-14）
            ratings[item.url] = persistedRatings[item.url] ?? 0
            for _ in 0..<(unconfirmedRatingEntries[item.url] ?? 0) { undoHistory.removeLastRating(for: item.url) }
            unconfirmedRatingEntries[item.url] = 0
            reportWriteFailure(error)
        }
    }

    /// 这个文件属于当前文件夹（换了文件夹后，旧文件夹的写入结果只更新账本）
    private func ratingWriterOwns(_ item: MediaItem) -> Bool {
        guard let folder = folderURL else { return false }
        return item.url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// 写失败的提示（spec S-14、S-15）：文件不见了不提示；同一原因 10 秒内只提示一次
    func reportWriteFailure(_ error: RatingWriteError) {
        if error == .vanished { return }
        if let last = lastWriteFailure, last.error == error, Date().timeIntervalSince(last.at) < 10 { return }
        lastWriteFailure = (error, Date())
        let text: String = switch error {
        case .notWritable: String(localized: "无法保存星级：此位置不可写")
        case .diskFull: String(localized: "无法保存星级：磁盘已满")
        case .other(let reason), .unsupported(let reason): String(localized: "无法保存星级：\(reason)", comment: "%@ 是系统给出的原因")
        case .vanished: ""
        }
        showRatingProblem(text)
    }

    private func showRatingProblem(_ text: String) {
        showToast(symbol: "exclamationmark.triangle", text: text, tone: .warning, duration: 4)
    }

    // MARK: - 五星胶囊的显示

    /// 闪现约 1 秒（value 为 nil 时显示当前文件自己的星级，用于自动下一张）
    func flash(_ value: Int?) {
        serial += 1
        ratingFlash = RatingFlash(value: value ?? currentRating ?? 0, serial: serial)
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { ratingFlash = nil }
        }
    }

    /// 鼠标在窗口里移动：胶囊淡入，静止“隐藏延迟”后淡出（spec R2-03，不管自动隐藏开没开）
    func showStarBarForMouse() {
        guard !hoveringVideoBar else { return }
        if !starBarMouseVisible { withAnimation(.easeOut(duration: 0.15)) { starBarMouseVisible = true } }
        scheduleStarBarHide()
    }

    func scheduleStarBarHide() {
        starBarTask?.cancel()
        let delay = settings.hideDelay
        starBarTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !hoveringStarBar else { return }
            withAnimation(.easeOut(duration: 0.35)) { starBarMouseVisible = false }
        }
    }

    /// 鼠标在视频控制条上：胶囊让开（spec R2-05）
    func setHoveringVideoBar(_ hovering: Bool) {
        hoveringVideoBar = hovering
        if hovering {
            starBarTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { starBarMouseVisible = false }
        }
    }

    func setHoveringStarBar(_ hovering: Bool) {
        hoveringStarBar = hovering
        if hovering { starBarTask?.cancel() } else { scheduleStarBarHide() }
    }

    // MARK: - 读取

    /// 换文件夹：清空星级状态
    func resetRatings() {
        ratingLoadTask?.cancel()
        ratings = [:]
        ratingInfo = [:]
        persistedRatings = [:]
        unconfirmedRatingEntries = [:]
        ratingsLoaded = false
        ownWrites.removeAll()
        lastWriteFailure = nil
    }

    /// 打开文件夹后读星级（spec R4-04）：先当前文件，等首张图显示（最多 300 毫秒）后，
    /// 按离当前位置的远近在后台读，4 路并行，每读完一批交回主线程
    func loadRatings() {
        ratingLoadTask?.cancel()
        let all = allItems
        let index = sidecars
        let center = current.flatMap { all.firstIndex(of: $0) } ?? 0
        let missing = all.filter { ratings[$0.url] == nil }
        guard !missing.isEmpty else { ratingsLoaded = true; return }
        ratingsLoaded = false
        ratingLoadTask = Task {
            if let item = current, ratings[item.url] == nil {
                let info = await Task.detached(priority: .userInitiated) { RatingFileIO.read(item, sidecars: index) }.value
                guard !Task.isCancelled else { return }
                applyLoaded([(item.url, info)])
            }
            // 等首张图出现，免得和首张图的解码抢磁盘
            for _ in 0..<15 where displayed == nil && current != nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let ordered = missing.enumerated()
                .sorted { abs(all.firstIndex(of: $0.element).map { $0 - center } ?? 0) < abs(all.firstIndex(of: $1.element).map { $0 - center } ?? 0) }
                .map(\.element)
            var start = 0
            while start < ordered.count {
                guard !Task.isCancelled else { return }
                let chunk = Array(ordered[start..<min(start + 64, ordered.count)])
                start += chunk.count
                let results = await Task.detached(priority: .utility) { Self.readChunk(chunk, sidecars: index) }.value
                guard !Task.isCancelled else { return }
                applyLoaded(results)
            }
            ratingsLoaded = true
        }
    }

    /// 读一批：4 路并行
    nonisolated static func readChunk(_ chunk: [MediaItem], sidecars: SidecarIndex) -> [(URL, RatingInfo)] {
        let lock = NSLock()
        var out: [(URL, RatingInfo)] = []
        out.reserveCapacity(chunk.count)
        DispatchQueue.concurrentPerform(iterations: 4) { lane in
            var mine: [(URL, RatingInfo)] = []
            for i in stride(from: lane, to: chunk.count, by: 4) {
                mine.append((chunk[i].url, RatingFileIO.read(chunk[i], sidecars: sidecars)))
            }
            lock.lock()
            out += mine
            lock.unlock()
        }
        return out
    }

    /// 读到的结果写进界面；用户刚改过、还没写完的文件不覆盖
    func applyLoaded(_ results: [(URL, RatingInfo)]) {
        var changed = ratings
        for (url, info) in results where (unconfirmedRatingEntries[url] ?? 0) == 0 && (inFlightRatingWrites[url] ?? 0) == 0 {
            changed[url] = info.value
            persistedRatings[url] = info.value
            ratingInfo[url] = info
        }
        ratings = changed
    }

    /// 文件夹同步发现这些文件的星级可能被其他软件改了：重新读（spec R4-06）
    func rereadRatings(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        let index = sidecars
        Task {
            let results = await Task.detached(priority: .utility) { Self.readChunk(items, sidecars: index) }.value
            applyLoaded(results)
        }
    }

    // MARK: - 撤销

    var canUndo: Bool { undoHistory.canUndo && pendingDelete == nil }

    /// 编辑菜单里撤销项的文字（spec R7-02）
    var undoMenuTitle: String {
        switch undoHistory.last {
        case .rating?: String(localized: "撤销“评星”")
        case .trash?: String(localized: "撤销“移到废纸篓”")
        case nil: String(localized: "撤销")
        }
    }

    /// ⌘Z：撤销最近一次评星或删除
    func undoLast() async {
        guard pendingDelete == nil, !trashBusy else { return }
        switch undoHistory.last {
        case .trash?: await undoDelete()
        case .rating(let change)?:
            undoHistory.pop()
            undoRating(change)
        case nil: break
        }
    }

    /// 撤销评星（spec R7-03、R7-04）：恢复旧值，文件还在就切过去
    func undoRating(_ change: RatingChange) {
        guard let item = allItems.first(where: { $0.url == change.item.url }) else {
            showToast(symbol: "exclamationmark.triangle", text: String(localized: "无法撤销：文件已不在这个文件夹"),
                      tone: .warning, duration: 4)
            return
        }
        if let i = items.firstIndex(of: item), currentIndex != i { select(i) }
        setRating(change.old, for: item, old: ratings[item.url] ?? change.new, recordUndo: false)
        flash(change.old)
    }

    // MARK: - 提示卡片

    func enqueueHint(_ card: HintCard) {
        if hint == nil {
            withAnimation(.easeOut(duration: 0.2)) { hint = card }
        } else if hint != card, !hintQueue.contains(card) {
            hintQueue.append(card)
        }
    }

    /// 关闭卡片；传了 only 时只在当前卡片是它时关闭
    func dismissHint(_ only: HintCard? = nil) {
        guard let shown = hint, only == nil || only == shown else { return }
        withAnimation(.easeOut(duration: 0.2)) { hint = hintQueue.isEmpty ? nil : hintQueue.removeFirst() }
    }

    /// 启动时：从 v0.2 升级来的用户显示快捷键变化（spec K-10）。跑测试时不显示
    func showUpgradeNoticeIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if settings.consumeUpgradeFromV02(currentVersion: AppInfo.version) { enqueueHint(.shortcutsChanged) }
    }

    // MARK: - 退出

    /// 退出前等没写完的星级，最多 3 秒（spec S-20）
    func flushRatingWrites() async {
        let writer = ratingWriter
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            Task { await writer.waitUntilIdle(); if once.claim() { done.resume() } }
            Task { try? await Task.sleep(for: .seconds(3)); if once.claim() { done.resume() } }
        }
    }
}

/// 只放行第一次（两个任务比谁先完成）
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
