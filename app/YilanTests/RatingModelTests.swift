import AppKit
import Foundation
import Testing
@testable import Yilan

// 第 2 阶段：评星接进浏览模型（spec 第 1–5、7 节）。全部在临时目录的样例副本上做

private func defaults() -> UserDefaults { suite().defaults }

private func suite() -> (defaults: UserDefaults, name: String) {
    let name = "yilan-rating-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, name)
}

/// 模型里某个文件名对应的星级（目录列出的路径可能是 /private/var…，不能直接拿 URL 比）
@MainActor
private func rating(_ model: BrowserModel, _ name: String) -> Int? {
    model.allItems.first { $0.name == name }.flatMap { model.ratings[$0.url] }
}

@MainActor
private func makeModel(_ folder: URL, initial: Int = 0, settings: AppSettings? = nil) throws -> BrowserModel {
    let model = BrowserModel(settings: settings ?? AppSettings(defaults: defaults()), recents: RecentFolders(defaults: defaults()))
    let items = try FolderScanner.scan(folder: folder)
    model.apply(FolderScanner.Result(folder: folder, items: items, initialIndex: initial,
                                     sidecars: SidecarIndex.scan(folder: folder, media: items)))
    return model
}

/// 等到条件成立（最多 5 秒）
@MainActor
@discardableResult
private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
private func idle(_ model: BrowserModel) async {
    await model.ratingWriter.waitUntilIdle()
    await waitFor { model.pendingRatingWrites == 0 }
}

@Suite("评星：按键")
struct RatingKeyTests {
    @Test("主键盘和小键盘的 0–5")
    func keys() {
        #expect(BrowserModel.ratingKey(29) == 0)
        #expect(BrowserModel.ratingKey(18) == 1)
        #expect(BrowserModel.ratingKey(23) == 5)
        #expect(BrowserModel.ratingKey(82) == 0)
        #expect(BrowserModel.ratingKey(87) == 5)
        #expect(BrowserModel.ratingKey(22) == nil)   // 6
        #expect(BrowserModel.ratingKey(25) == nil)   // 9
    }

    @Test("从 v0.2 升级才显示快捷键变化，新装不显示，只显示一次")
    @MainActor
    func upgradeNotice() {
        let old = suite()
        old.defaults.set("all", forKey: MediaFilter.defaultsKey)
        let upgraded = AppSettings(defaults: old.defaults, domainName: old.name)
        #expect(upgraded.consumeUpgradeFromV02(currentVersion: "0.3.0"))
        #expect(!upgraded.consumeUpgradeFromV02(currentVersion: "0.3.0"))
        let new = suite()
        let fresh = AppSettings(defaults: new.defaults, domainName: new.name)
        #expect(!fresh.consumeUpgradeFromV02(currentVersion: "0.3.0"))
    }
}

@Suite("评星：浏览模型", .serialized)
@MainActor
struct RatingModelTests {
    @Test("打星：界面立即变化，写进文件；⌘Z 恢复，文件同步恢复")
    func rateAndUndo() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir)
        let item = try #require(model.current)
        await waitFor { model.ratingsLoaded }
        #expect(model.currentRating == 0)

        model.rateCurrent(4, fromKeyboard: true)
        #expect(model.currentRating == 4)                 // 不等写盘
        #expect(model.ratingFlash?.value == 4)
        #expect(model.undoMenuTitle == String(localized: "撤销“评星”"))
        await idle(model)
        #expect(ImageIOMetadata.rating(at: item.url) == 4)

        model.rateCurrent(4, fromKeyboard: true)          // 相同数字：不进记录
        #expect(model.undoHistory.entries.count == 1)

        await model.undoLast()
        #expect(model.currentRating == 0)
        await idle(model)
        #expect(RatingValue.display(ImageIOMetadata.rating(at: item.url)) == 0)
        #expect(!model.canUndo)
    }

    @Test("清除星级有提示；未评星时按 0 什么都不做")
    func clear() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir)
        await waitFor { model.ratingsLoaded }
        model.rateCurrent(0, fromKeyboard: true)
        #expect(!model.canUndo)
        #expect(model.toast == nil)
        model.rateCurrent(2, fromKeyboard: true)
        model.rateCurrent(0, fromKeyboard: true)
        #expect(model.toast?.text == String(localized: "已清除星级"))
        #expect(model.undoHistory.entries.count == 2)
        await idle(model)
    }

    @Test("评星和删除共用撤销记录，按时间倒序撤销")
    func sharedHistory() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg", "aurora.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir)
        await waitFor { model.ratingsLoaded }
        let first = try #require(model.current)
        model.rateCurrent(3, fromKeyboard: true)
        await idle(model)
        await model.performDelete(first)
        #expect(model.undoMenuTitle == String(localized: "撤销“移到废纸篓”"))
        await model.undoLast()                             // 先放回文件
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(model.undoMenuTitle == String(localized: "撤销“评星”"))
        await model.undoLast()                             // 再撤销评星，并回到那张
        #expect(model.current?.url == first.url)
        await idle(model)
        #expect(RatingValue.display(ImageIOMetadata.rating(at: first.url)) == 0)
    }

    @Test("删除带 .xmp 的文件：小文件一起进废纸篓，撤销后一起回来")
    func trashSidecar() async throws {
        let dir = try MetaFixtures.copy(["gears.gif", "IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir)
        let gif = try #require(model.current)
        #expect(gif.name == "gears.gif")
        await waitFor { model.ratingsLoaded }
        model.rateCurrent(5, fromKeyboard: true)
        await idle(model)
        let side = dir.appendingPathComponent("gears.xmp")
        #expect(FileManager.default.fileExists(atPath: side.path))
        await model.performDelete(gif)
        #expect(!FileManager.default.fileExists(atPath: side.path))
        await model.undoLast()
        #expect(FileManager.default.fileExists(atPath: gif.url.path))
        #expect(FileManager.default.fileExists(atPath: side.path))
    }

    @Test("位置不可写：提示，星级不变，不进撤销记录")
    func readOnly() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        chmod(dir.path, 0o555)
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        let model = try makeModel(dir)
        #expect(!model.folderWritable)
        #expect(!model.canRateCurrent)
        model.rateCurrent(3, fromKeyboard: true)
        #expect(model.currentRating ?? 0 == 0)
        #expect(!model.canUndo)
        #expect(model.toast?.text == String(localized: "无法保存星级：此位置不可写"))
        #expect(model.toast?.tone == .warning)
    }

    @Test("写盘失败：界面恢复、这次操作从撤销记录里拿掉")
    func writeFailureReverts() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir)
        await waitFor { model.ratingsLoaded }
        let item = try #require(model.current)
        await model.ratingWriter.setDelayForTesting(.milliseconds(300))
        model.rateCurrent(2, fromKeyboard: true)
        // 写之前把文件夹改成只读：写入失败
        chmod(dir.path, 0o555)
        defer { chmod(dir.path, 0o755) }
        await idle(model)
        #expect(model.ratings[item.url] == 0)
        #expect(!model.canUndo)
        #expect(model.toast?.tone == .warning)
        await model.ratingWriter.setDelayForTesting(nil)
    }

    @Test("打开文件夹后读出已有星级（内嵌和小文件）")
    func loadsExisting() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "gears.gif", "IMG_2031.heic"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try MetaFixtures.index(dir)
        _ = try RatingFileIO.write(3, for: MetaFixtures.item(dir.appendingPathComponent("IMG_2034.jpg")), mode: .embedded, sidecars: index)
        _ = try RatingFileIO.write(5, for: MetaFixtures.item(dir.appendingPathComponent("gears.gif")), mode: .embedded, sidecars: index)
        let model = try makeModel(dir)
        await waitFor { model.ratingsLoaded }
        #expect(rating(model, "IMG_2034.jpg") == 3)
        #expect(rating(model, "gears.gif") == 5)
        #expect(rating(model, "IMG_2031.heic") == 0)
    }

    @Test("一览自己写星级不算文件被改：当前图片不重载；其他软件改了小文件会重读")
    func syncIgnoresOwnWrites() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try makeModel(dir, initial: 1)
        await waitFor { model.ratingsLoaded }
        let jpeg = try #require(model.current)
        #expect(jpeg.name == "IMG_2034.jpg")
        model.rateCurrent(4, fromKeyboard: true)
        await idle(model)
        let scanned = try FolderScanner.scan(folder: dir)
        model.applySync(scanned, sidecars: SidecarIndex.scan(folder: dir, media: scanned))
        #expect(model.current == jpeg)                      // 还是同一个条目，没有重新加载
        #expect(model.toast?.text != String(localized: "当前文件已被删除或移走"))

        // 其他软件新建了 gears.gif 的小文件
        let side = dir.appendingPathComponent("gears.xmp")
        try Data(lightroomStyleXMP.utf8).write(to: side)
        let again = try FolderScanner.scan(folder: dir)
        model.applySync(again, sidecars: SidecarIndex.scan(folder: dir, media: again))
        #expect(await waitFor { rating(model, "gears.gif") == 2 })
    }

    @Test("闪现只在按键时出现；设置关掉后不闪；鼠标点星不闪（R3a）")
    func flashRules() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: defaults())
        #expect(settings.flashRatingOnStage)
        let model = try makeModel(dir, settings: settings)
        await waitFor { model.ratingsLoaded }
        model.rateCurrent(2, fromKeyboard: false)
        #expect(model.ratingFlash == nil)
        model.rateCurrent(3, fromKeyboard: true)
        #expect(model.ratingFlash?.value == 3)
        model.ratingFlash = nil
        settings.flashRatingOnStage = false
        model.rateCurrent(4, fromKeyboard: true)
        #expect(model.ratingFlash == nil)
        #expect(model.currentRating == 4)
        await idle(model)
    }

    @Test("打星后自动下一张：键盘评星后跳到下一张，鼠标不跳")
    func autoAdvance() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg", "aurora.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: defaults())
        settings.autoAdvanceAfterRating = true
        let model = try makeModel(dir, settings: settings)
        await waitFor { model.ratingsLoaded }
        #expect(model.currentIndex == 0)
        model.rateCurrent(3, fromKeyboard: true)
        #expect(model.currentIndex == 1)
        model.rateCurrent(2, fromKeyboard: false)
        #expect(model.currentIndex == 1)
        await idle(model)
    }
}
