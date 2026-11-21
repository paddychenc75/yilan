import AppKit
import Foundation
import Testing
@testable import Yilan

// 批量评星（spec X7）：图标视图多选时按 1–5 / 0

@MainActor
private func makeGrid(_ files: [String], settings: AppSettings? = nil, prepare: (URL) throws -> Void = { _ in }) async throws -> (BrowserModel, URL) {
    let folder = try MetaFixtures.copy(files)
    try prepare(folder)
    let model = try T5.model(folder, settings: settings)
    model.setViewMode(.grid)
    _ = await T5.waitFor { model.ratingsLoaded }
    return (model, folder)
}

@MainActor
private func pick(_ model: BrowserModel, _ names: [String]) {
    model.deselectAllInGrid()
    for (n, name) in names.enumerated() {
        if let item = model.items.first(where: { $0.name == name }) { model.gridClick(item.url, command: n > 0, shift: false) }
    }
}

@MainActor
private func press(_ model: BrowserModel, _ digit: Int) throws {
    #expect(model.handleKey(try T5.key(T5.digitKeyCodes[digit]!, "\(digit)")))
}

@MainActor
private func idle(_ model: BrowserModel) async {
    await model.ratingWriter.waitUntilIdle()
    _ = await T5.waitFor { model.pendingRatingWrites == 0 && model.ratingBatches.isEmpty }
}

@MainActor
private func rating(_ model: BrowserModel, _ name: String) -> Int? {
    model.allItems.first { $0.name == name }.flatMap { model.ratings[$0.url] }
}

/// 一张一张地打星（单选时的老路径），用来准备初始星级
@MainActor
private func rateOne(_ model: BrowserModel, _ name: String, _ value: Int) async {
    pick(model, [name])
    model.rateCurrent(value, fromKeyboard: false)
    await idle(model)
}

/// 从磁盘重新读一个文件的星级（确认真的写进去了）
private func diskRating(_ folder: URL, _ name: String) throws -> Int {
    let items = try FolderScanner.scan(folder: folder)
    let item = try #require(items.first { $0.name == name })
    return RatingFileIO.read(item, sidecars: SidecarIndex.scan(folder: folder, media: items)).value
}

@Suite("批量评星")
struct BatchRatingTests {
    @Test("多选按数字键：图片全部设成这个星级，视频跳过；闪现写张数，提示条说明跳过的视频（spec X7-01、X7-02）")
    @MainActor
    func ratesSelection() async throws {
        let (model, folder) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "river.mp4"])
        model.selectAllInGrid()
        try press(model, 4)
        for name in ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"] { #expect(rating(model, name) == 4) }
        #expect(rating(model, "river.mp4") == nil)
        #expect(model.ratingFlash?.value == 4 && model.ratingFlash?.count == 3)
        #expect(model.toast?.text == String(localized: "已给 \(3) 张图片评 \(4) 星，\(1) 个视频已跳过"))
        #expect(model.toast?.action == .undo)
        #expect(model.grid.selection.count == 4)            // 选择不变
        await idle(model)
        for name in ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"] { #expect(try diskRating(folder, name) == 4) }
    }

    @Test("已经是这个星级的不动；整批一条撤销记录，⌘Z 每张恢复成各自原来的星级（spec X7-01、X7-03）")
    @MainActor
    func undoRestoresEach() async throws {
        let (model, folder) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        await rateOne(model, "aurora.jpg", 2)
        await rateOne(model, "IMG_2034.jpg", 5)
        let before = model.undoHistory.entries.count
        pick(model, ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        try press(model, 5)
        // IMG_2034 已经是 5 星：不算在改动里
        #expect(model.ratingFlash?.count == 2)
        #expect(model.toast?.text == String(localized: "已给 \(2) 张图片评 \(5) 星"))
        #expect(model.undoHistory.entries.count == before + 1)
        #expect(model.undoMenuTitle == String(localized: "撤销“评星”"))
        await idle(model)
        await model.undoLast()
        #expect(rating(model, "aurora.jpg") == 2 && rating(model, "IMG_2034.jpg") == 5 && rating(model, "IMG_2052.jpg") == 0)
        await idle(model)
        #expect(try diskRating(folder, "aurora.jpg") == 2)
        #expect(try diskRating(folder, "IMG_2034.jpg") == 5)
        #expect(try diskRating(folder, "IMG_2052.jpg") == 0)
        #expect(model.undoHistory.entries.count == before)
    }

    @Test("按 0：选中的图片全部清除星级（spec X7-01）")
    @MainActor
    func clears() async throws {
        let (model, _) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg"])
        await rateOne(model, "aurora.jpg", 3)
        await rateOne(model, "IMG_2034.jpg", 1)
        model.selectAllInGrid()
        try press(model, 0)
        #expect(rating(model, "aurora.jpg") == 0 && rating(model, "IMG_2034.jpg") == 0)
        await idle(model)
        await model.undoLast()
        #expect(rating(model, "aurora.jpg") == 3 && rating(model, "IMG_2034.jpg") == 1)
    }

    @Test("有的文件写不进去：它的星恢复原状，提示失败数，其余保持新星级；撤销只管写成的（spec X7-04）")
    @MainActor
    func partialFailure() async throws {
        // IMG_2034.jpg 的小文件位置被一个同名文件夹占着：这一张写不进去
        let (model, folder) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"]) { folder in
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("IMG_2034.xmp"), withIntermediateDirectories: false)
        }
        model.selectAllInGrid()
        try press(model, 5)
        await idle(model)
        #expect(rating(model, "IMG_2034.jpg") == 0)
        #expect(rating(model, "aurora.jpg") == 5 && rating(model, "IMG_2052.jpg") == 5)
        #expect(model.toast?.text == String(localized: "有 \(1) 张的星级无法保存：此位置不可写"))
        #expect(model.toast?.tone == .warning)
        guard case .ratingBatch(let batch)? = model.undoHistory.last else {
            Issue.record("撤销记录里应该有这次批量评星")
            return
        }
        #expect(Set(batch.changes.map(\.item.name)) == ["aurora.jpg", "IMG_2052.jpg"])
        await model.undoLast()
        await idle(model)
        #expect(try diskRating(folder, "aurora.jpg") == 0)
        #expect(try diskRating(folder, "IMG_2052.jpg") == 0)
    }

    @Test("整个位置不可写：一张都不改，提示失败数，不进撤销记录（spec X7-04）")
    @MainActor
    func readOnlyFolder() async throws {
        let (model, folder) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg"]) { folder in
            chmod(folder.path, 0o555)
        }
        defer { chmod(folder.path, 0o755) }
        #expect(!model.folderWritable)
        model.selectAllInGrid()
        try press(model, 3)
        #expect(rating(model, "aurora.jpg") ?? 0 == 0 && rating(model, "IMG_2034.jpg") ?? 0 == 0)
        #expect(model.toast?.text == String(localized: "有 \(2) 张的星级无法保存：此位置不可写"))
        #expect(!model.canUndo)
    }

    @Test("星级筛选生效时：改完不符合条件的全部暂留，选中集合变化时一起消失（spec X7-05）")
    @MainActor
    func stickyWhileFiltered() async throws {
        let (model, _) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "harbor_night.png"])
        for name in ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"] { await rateOne(model, name, 3) }
        var f = BrowseFilter()
        f.rating.mode = .stars(3)
        model.setBrowseFilter(f)
        try #require(model.items.count == 3)
        pick(model, ["aurora.jpg", "IMG_2034.jpg"])
        try press(model, 1)
        await idle(model)
        // 两张都不符合了，但都还在原位
        #expect(model.items.map(\.name) == ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        #expect(model.grid.selection.count == 2)
        // 选中别的：两张一起消失
        pick(model, ["IMG_2052.jpg"])
        #expect(model.items.map(\.name) == ["IMG_2052.jpg"])
    }

    @Test("评星关掉时：多选按数字键没有任何反应（spec X7-06）")
    @MainActor
    func ratingOff() async throws {
        let settings = T5.settings()
        let (model, folder) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg"], settings: settings)
        settings.featureRating = false
        let before = try T5.snapshot(folder)
        model.selectAllInGrid()
        model.hideToast()
        try press(model, 4)
        #expect(model.ratings.values.allSatisfy { $0 == 0 })
        #expect(model.toast == nil && model.ratingFlash == nil && !model.canUndo)
        await idle(model)
        #expect(try T5.snapshot(folder) == before)
    }

    @Test("选中的全是视频：1–5 提示不支持，什么都不写（spec X7-01）")
    @MainActor
    func onlyVideos() async throws {
        let (model, folder) = try await makeGrid(["river.mp4", "IMG_2036.mov", "aurora.jpg"])
        let before = try T5.snapshot(folder)
        pick(model, ["river.mp4", "IMG_2036.mov"])
        try press(model, 2)
        #expect(model.toast?.text == String(localized: "视频暂不支持评星"))
        #expect(!model.canUndo)
        #expect(try T5.snapshot(folder) == before)
    }

    @Test("关掉评星时批量评星的撤销记录一起丢弃（spec T2-07）")
    @MainActor
    func featureOffDropsBatchUndo() async throws {
        let settings = T5.settings()
        let (model, _) = try await makeGrid(["aurora.jpg", "IMG_2034.jpg"], settings: settings)
        model.selectAllInGrid()
        try press(model, 2)
        await idle(model)
        #expect(model.canUndo)
        settings.featureRating = false
        #expect(!model.canUndo)
    }
}
