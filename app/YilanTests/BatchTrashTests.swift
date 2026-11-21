import AppKit
import Foundation
import Testing
@testable import Yilan

// 批量移到废纸篓（spec X3）。测试进程里用的是假废纸篓，不会碰真正的废纸篓

private let names = ["aurora.jpg", "harbor_night.png", "IMG_2031.heic", "IMG_2034.jpg", "IMG_2035.heic", "IMG_2052.jpg", "river.mp4"]

@MainActor
private func makeGrid(_ files: [String] = names, settings: AppSettings? = nil) throws -> (BrowserModel, URL) {
    let folder = try MetaFixtures.copy(files)
    let model = BrowserModel(settings: settings ?? T5.settings(), recents: RecentFolders(defaults: T5.suite().defaults))
    let items = try FolderScanner.scan(folder: folder)
    model.apply(FolderScanner.Result(folder: folder, items: items, initialIndex: items.isEmpty ? nil : 0,
                                     sidecars: SidecarIndex.scan(folder: folder, media: items)))
    model.setViewMode(.grid)
    return (model, folder)
}

@MainActor
private func pick(_ model: BrowserModel, _ indexes: [Int]) {
    for (n, i) in indexes.enumerated() { model.gridClick(model.items[i].url, command: n > 0, shift: false) }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private struct Refused: Error {}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

@Suite("批量移到废纸篓：后台部分")
struct BatchTrashRunTests {
    private func folderWithRaws() throws -> (URL, [MediaItem], SidecarIndex) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yilan-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.arw", "a.dng", "a.xmp", "b.arw", "b.xmp", "c.jpg", "c.jpg.xmp"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let items = try FolderScanner.scan(folder: dir)
        return (dir, items, SidecarIndex.scan(folder: dir, media: items))
    }

    @Test("两个 RAW 共用一个小文件：都在这一批里才带走，只在一个上带一次（spec X3-06）")
    func sharedSidecar() throws {
        let (_, items, index) = try folderWithRaws()
        func item(_ name: String) throws -> MediaItem { try #require(items.first { $0.name == name }) }
        let all = BatchTrash.jobs(for: [try item("a.arw"), try item("a.dng"), try item("b.arw")], sidecars: index)
        #expect(all.map { $0.sidecar?.lastPathComponent } == [nil, "a.xmp", "b.xmp"])
        let one = BatchTrash.jobs(for: [try item("a.arw"), try item("b.arw")], sidecars: index)
        #expect(one.map { $0.sidecar?.lastPathComponent } == [nil, "b.xmp"])
    }

    @Test("逐个移走，小文件跟着走；一个失败不影响其余的（spec X3-06、X3-12）")
    func partial() throws {
        let (dir, items, index) = try folderWithRaws()
        let jobs = BatchTrash.jobs(for: items, sidecars: index)
        let result = BatchTrash.run(jobs, stop: .init(), trash: { url in
            if url.lastPathComponent == "b.arw" { throw Refused() }
            return try TrashService.trash(url)
        })
        #expect(result.moved.count == items.count - 1)
        #expect(result.failed.map(\.item.name) == ["b.arw"])
        #expect(result.untouched.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["b.arw", "b.xmp"])        // 移不走的文件和它的小文件都留在原处
        // 放回去：全部回到原位
        let back = BatchTrash.restore(result.moved)
        #expect(back.failed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 7)
    }

    @Test("停止：正在处理的做完后停下，其余没动（spec X3-11）")
    func stop() throws {
        let (_, items, index) = try folderWithRaws()
        let flag = BatchTrash.StopFlag()
        let result = BatchTrash.run(BatchTrash.jobs(for: items, sidecars: index), stop: flag, progress: { done in
            if done == 2 { flag.stop() }
        })
        #expect(result.moved.count == 2)
        #expect(result.untouched.count == items.count - 2)
        #expect(result.untouched.allSatisfy { exists($0.url) })
    }

    @Test("文件已经不在原处、已锁定：给出对应的原因（spec X3-13）")
    func reasons() throws {
        let (dir, items, index) = try folderWithRaws()
        let gone = try #require(items.first { $0.name == "c.jpg" })
        try FileManager.default.removeItem(at: gone.url)
        let result = BatchTrash.run(BatchTrash.jobs(for: [gone], sidecars: index), stop: .init())
        #expect(result.failed.first?.reason == String(localized: "文件已经不在原处"))
        let locked = dir.appendingPathComponent("b.arw")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        #expect(BatchTrash.reason(for: Refused(), url: locked) == String(localized: "文件已锁定"))
    }

    @Test("放回时原位置已有同名文件：跳过它，其余照常（spec X3-17）")
    func restoreConflict() throws {
        let (dir, items, index) = try folderWithRaws()
        let result = BatchTrash.run(BatchTrash.jobs(for: items, sidecars: index), stop: .init())
        try Data("new".utf8).write(to: dir.appendingPathComponent("c.jpg"))
        let back = BatchTrash.restore(result.moved)
        #expect(back.failed.map(\.item.name) == ["c.jpg"])
        #expect(back.failed.first?.reason == String(localized: "原位置已经有同名文件"))
        #expect(back.restored.count == items.count - 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent("c.jpg")) == Data("new".utf8))   // 没有覆盖
    }
}

@Suite("批量移到废纸篓：接进浏览模型")
struct BatchTrashModelTests {
    @Test("多选时按 ⌫ 一定先确认，哪怕「删除前确认」关着；取消后什么都没动（spec X3-01、X3-05）")
    @MainActor
    func alwaysConfirms() async throws {
        let settings = T5.settings()
        settings.confirmBeforeDelete = false
        let (model, _) = try makeGrid(settings: settings)
        pick(model, [1, 3, 4])
        _ = model.handleKey(try T5.key(51))
        let request = try #require(model.pendingBatchDelete)
        #expect(request.count == 3 && request.scope == .some)
        #expect(model.items.count == 7)
        // 确认框开着：别的键不起作用，选择不变
        #expect(model.handleKey(try T5.key(0, "a", .command)))
        #expect(model.handleKey(try T5.key(49, " ")))
        #expect(model.grid.selection.count == 3)
        model.cancelBatchDelete()
        #expect(model.pendingBatchDelete == nil && model.items.count == 7 && model.grid.selection.count == 3)
        #expect(model.items.allSatisfy { exists($0.url) })
    }

    @Test("确认框标题：选中全部时按有没有筛选换说法；有视频时正文加一句（spec X3-02）")
    @MainActor
    func titles() throws {
        let (model, _) = try makeGrid()
        model.selectAllInGrid()
        model.requestBatchDelete()
        var request = try #require(model.pendingBatchDelete)
        #expect(request.scope == .wholeFolder && request.videos == 1 && request.preview.count == 3)
        #expect(request.message.hasPrefix(String(localized: "其中有 \(1) 个视频。")))
        model.cancelBatchDelete()
        model.setFilter(.images)
        model.selectAllInGrid()
        model.requestBatchDelete()
        request = try #require(model.pendingBatchDelete)
        #expect(request.scope == .wholeFilter && request.count == 6 && request.videos == 0)
    }

    @Test("确认后整批移走：列表更新，选中清空，不自动选中；⌘Z 一次全部放回并选中（spec X3-10、X3-16）")
    @MainActor
    func deleteAndUndo() async throws {
        let (model, _) = try makeGrid()
        pick(model, [1, 3, 4])
        let gone = model.selectedItems
        let afterFirst = model.items[2].url
        model.requestBatchDelete()
        model.confirmBatchDelete()
        _ = await T5.waitFor { model.items.count == 4 && !model.batchRunning }
        #expect(gone.allSatisfy { !exists($0.url) })
        #expect(model.grid.selection.isEmpty && model.current == nil)
        #expect(model.grid.focus == afterFirst)             // 第一张被删文件原来位置上现在的那一张
        #expect(model.undoHistory.entries.count == 1)
        #expect(model.undoMenuTitle == String(localized: "撤销“将 \(3) 项移到废纸篓”"))
        // 之后再按 ⌫：没有选中，没有反应（spec X3-20）
        _ = model.handleKey(try T5.key(51))
        #expect(model.pendingBatchDelete == nil && model.pendingDelete == nil)
        await model.undoLast()
        #expect(model.items.count == 7)
        #expect(gone.allSatisfy { exists($0.url) })
        #expect(Set(model.selectedItems.map(\.url)) == Set(gone.map(\.url)))
        #expect(!model.canUndo)
    }

    @Test("有文件移不走：其余照常，移不走的保持选中，弹出提示框（spec X3-12）")
    @MainActor
    func partialFailure() async throws {
        let (model, _) = try makeGrid()
        pick(model, [0, 2, 5])
        let stubborn = model.items[2]
        await model.performBatchDelete(model.selectedItems, trash: { url in
            if url == stubborn.url { throw Refused() }
            return try TrashService.trash(url)
        })
        #expect(model.items.count == 5 && exists(stubborn.url))
        #expect(model.selectedItems == [stubborn])
        let report = try #require(model.batchReport)
        #expect(report.rows.map(\.item) == [stubborn] && report.more == 0)
        #expect(report.title == String(localized: "有 \(1) 个项目无法移到废纸篓"))
        #expect(report.message == String(localized: "其余 \(2) 项已经移到废纸篓，按 ⌘Z 可以撤销。"))
        // 提示框开着时只有回车和 Esc 交给按钮
        #expect(!model.handleKey(try T5.key(36)))
        #expect(model.handleKey(try T5.key(5, "g")))
        model.dismissBatchReport(performAction: false)
        #expect(model.batchReport == nil && model.canUndo)
    }

    @Test("一个都没移走：标题换一句，没有「其余 N 项」，不留撤销记录（spec X3-14）")
    @MainActor
    func allFailed() async throws {
        let (model, _) = try makeGrid()
        pick(model, [0, 1])
        await model.performBatchDelete(model.selectedItems, trash: { _ in throw Refused() })
        let report = try #require(model.batchReport)
        #expect(report.title == String(localized: "这 \(2) 个项目无法移到废纸篓") && report.message == nil)
        #expect(model.items.count == 7 && !model.canUndo && model.grid.selection.count == 2)
    }

    @Test("提示框最多列 5 个，更多时最后一行写还有几个（spec X3-12）")
    func reportRows() throws {
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/x.jpg"), format: .standard, fileSize: 1, modificationDate: .now)
        func failures(_ n: Int) -> [BatchTrash.Failure] { (0..<n).map { _ in .init(item: item, reason: "r") } }
        let five = BatchReport.make(title: "t", message: nil, failures: failures(5), actionTitle: "a", action: .openTrash)
        #expect(five.rows.count == 5 && five.more == 0)
        let nine = BatchReport.make(title: "t", message: nil, failures: failures(9), actionTitle: "a", action: .openTrash)
        #expect(nine.rows.count == 4 && nine.more == 5)
    }

    @Test("撤销时有文件放不回：其余放回并选中，提示框说明，这条记录用完（spec X3-17）")
    @MainActor
    func undoPartial() async throws {
        let (model, _) = try makeGrid()
        pick(model, [0, 1, 2])
        let gone = model.selectedItems
        await model.performBatchDelete(gone)
        try Data("occupied".utf8).write(to: gone[1].url)
        await model.undoLast()
        let report = try #require(model.batchReport)
        #expect(report.rows.map(\.item.name) == [gone[1].name])
        #expect(report.action == .openTrash)
        #expect(Set(model.selectedItems.map(\.name)) == [gone[0].name, gone[2].name])
        #expect(!model.canUndo)
        #expect(try Data(contentsOf: gone[1].url) == Data("occupied".utf8))
    }

    @Test("中途点停止：已移走的和没动的数量对得上，没动的保持选中，⌘Z 放回已移走的（spec X3-11）")
    @MainActor
    func stopMidway() async throws {
        let (model, _) = try makeGrid()
        model.selectAllInGrid()
        let all = model.selectedItems
        let counter = Counter()
        await model.performBatchDelete(all, trash: { url in
            // 第 3 个文件处理完后「点停止」
            if counter.next() == 3 { Task { @MainActor in model.stopBatch() } }
            Thread.sleep(forTimeInterval: 0.05)
            return try TrashService.trash(url)
        })
        let left = model.items.count
        #expect(left > 0 && left < all.count)
        #expect(model.grid.selection.count == left)          // 没动的保持选中
        #expect(model.items.allSatisfy { exists($0.url) })
        #expect(model.toast?.text == String(localized: "已停止：\(all.count - left) 项已移到废纸篓，\(left) 项没有移动"))
        #expect(!model.batchRunning)
        await model.undoLast()
        #expect(model.items.count == all.count && all.allSatisfy { exists($0.url) })
    }

    @Test("有筛选时全选并删除：眼前的每一张（包括暂留的）都删，没看到的不动（PRD 验收）")
    @MainActor
    func filteredSelectAll() async throws {
        let (model, _) = try makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "harbor_night.png"])
        _ = await T5.waitFor { model.ratingsLoaded }
        // 给两张打 3 星，筛「不低于 3 星」
        for i in [0, 1] {
            model.gridClick(model.items[i].url, command: false, shift: false)
            model.rateCurrent(3, fromKeyboard: true)
        }
        await model.ratingWriter.waitUntilIdle()
        _ = await T5.waitFor { model.pendingRatingWrites == 0 }
        var f = BrowseFilter()
        f.rating.mode = .stars(3)
        model.setBrowseFilter(f)
        try #require(model.items.count == 2)
        // 把其中一张改成 1 星：不符合了，但暂留在眼前
        model.gridClick(model.items[0].url, command: false, shift: false)
        model.rateCurrent(1, fromKeyboard: true)
        await model.ratingWriter.waitUntilIdle()
        #expect(model.items.count == 2)
        let hidden = model.allItems.filter { !model.items.contains($0) }
        model.selectAllInGrid()
        let seen = model.selectedItems
        #expect(seen.count == 2)
        model.requestBatchDelete()
        #expect(model.pendingBatchDelete?.scope == .wholeFilter)
        model.confirmBatchDelete()
        _ = await T5.waitFor { !model.batchRunning && model.allItems.count == 2 }
        #expect(seen.allSatisfy { !exists($0.url) })
        #expect(hidden.count == 2 && hidden.allSatisfy { exists($0.url) })
    }

    @Test("小文件跟着照片进废纸篓，撤销时一起回来（spec X3-06）")
    @MainActor
    func sidecarsFollow() async throws {
        let (model, folder) = try makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        _ = await T5.waitFor { model.ratingsLoaded }
        model.settings.ratingStorage = .sidecar
        model.gridClick(model.items[0].url, command: false, shift: false)
        model.rateCurrent(4, fromKeyboard: true)
        await model.ratingWriter.waitUntilIdle()
        _ = await T5.waitFor { model.pendingRatingWrites == 0 }
        let xmp = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".xmp") }
        try #require(xmp.count == 1)
        pick(model, [0, 1])
        await model.performBatchDelete(model.selectedItems)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["IMG_2052.jpg"])
        await model.undoLast()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 4)
    }
}

@Suite("多选：拷贝和菜单")
struct MultiSelectionMenuTests {
    @Test("多选菜单：在访达中显示、拷贝 N 项、拷贝 N 个文件路径、将 N 项移到废纸篓（spec X4-02）")
    @MainActor
    func multiMenu() throws {
        let (model, _) = try makeGrid()
        pick(model, [0, 2, 3])
        let menu = model.fileMenu(.gridItem)
        #expect(menu.compactMap(\.action) == [.reveal, .copy, .copyPath, .trash])
        #expect(menu.filter { $0.action != nil }.map(\.title) == [
            String(localized: "在访达中显示"), String(localized: "拷贝 \(3) 项"),
            String(localized: "拷贝 \(3) 个文件路径"), String(localized: "将 \(3) 项移到废纸篓"),
        ])
    }

    @Test("图标视图单张菜单没有旋转和编辑（spec M2-04）")
    @MainActor
    func singleMenu() throws {
        let (model, _) = try makeGrid()
        pick(model, [2])
        #expect(model.fileMenu(.gridItem).compactMap(\.action) == [.reveal, .copy, .copyPath, .toggleInfo, .trash])
    }

    @Test("没有选中时「⋯」菜单里针对文件的几项置灰（spec M4-02）")
    @MainActor
    func nothingSelected() throws {
        let (model, _) = try makeGrid()
        model.deselectAllInGrid()
        let menu = model.fileMenu(.more)
        for action in [FileAction.reveal, .copy, .copyPath, .trash] {
            #expect(menu.first { $0.action == action }?.enabled == false)
        }
        #expect(menu.first { $0.action == .open }?.enabled == true)
    }

    @Test("拷贝 N 个文件路径：每行一个，按列表顺序（spec X4-04）；拷贝文件也按列表顺序（spec X5-01）")
    @MainActor
    func copyOrder() throws {
        let (model, _) = try makeGrid()
        pick(model, [4, 1, 3])
        let board = NSPasteboard(name: .init("yilan-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.copySelectedPaths(pasteboard: board)
        let expected = [1, 3, 4].map { model.items[$0].url.path }
        #expect(board.string(forType: .string) == expected.joined(separator: "\n"))
        model.copyFiles(model.selectedItems, pasteboard: board)
        #expect(board.pasteboardItems?.compactMap { $0.string(forType: .string) } == expected)
    }
}
