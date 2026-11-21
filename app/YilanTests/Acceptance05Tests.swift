import AppKit
import Foundation
import Testing
@testable import Yilan

// v0.5 验收补充测试：对着 prd.md 的验收标准，补模型层、文件层能证明的几条。
// 假文件只在临时目录里造；测试里的删除走假废纸篓。

private let sampleNames = ["aurora.jpg", "harbor_night.png", "IMG_2031.heic", "IMG_2034.jpg", "IMG_2035.heic", "IMG_2052.jpg", "river.mp4"]

@MainActor
private func gridModel(_ files: [String] = sampleNames, settings: AppSettings? = nil) throws -> (BrowserModel, URL) {
    let folder = try MetaFixtures.copy(files)
    let model = try T5.model(folder, settings: settings)
    model.setViewMode(.grid)
    return (model, folder)
}

@MainActor
private func pick(_ model: BrowserModel, _ indexes: [Int]) {
    for (n, i) in indexes.enumerated() { model.gridClick(model.items[i].url, command: n > 0, shift: false) }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite("验收 C3：新增 RAW 扩展名进列表、算作 RAW")
struct AcceptanceC3Tests {
    static let newRaw = ["srw", "pef", "3fr", "fff", "iiq", "x3f", "erf", "mrw", "srf", "sr2",
                         "crw", "nrw", "rwl", "dcr", "kdc", "mef", "mos", "gpr"]

    @Test("C3 验收：每种新增扩展名各放一个文件，全部出现在列表里，格式筛选里都算「RAW」")
    @MainActor
    func allListedAndGroupedAsRaw() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yilan-accept-c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, ext) in Self.newRaw.enumerated() {
            // 一半用大写扩展名：不分大小写
            let e = i % 2 == 0 ? ext : ext.uppercased()
            try Data("fake-\(ext)".utf8).write(to: dir.appendingPathComponent("IMG_\(String(format: "%02d", i)).\(e)"))
        }
        try Data("fake".utf8).write(to: dir.appendingPathComponent("jpegonly.jpg"))   // 凑一个非 RAW，筛选时应被排除
        let model = try T5.model(dir)
        #expect(model.allItems.count == Self.newRaw.count + 1)
        let raws = model.allItems.filter { $0.url.pathExtension.lowercased() != "jpg" }
        #expect(raws.count == Self.newRaw.count)
        #expect(Set(raws.map { $0.url.pathExtension.lowercased() }) == Set(Self.newRaw))
        #expect(raws.allSatisfy { $0.kind == .image && $0.format == .raw && FormatGroup.of($0) == .raw })
        // 格式筛选「RAW」：所有新扩展名都留下
        var f = BrowseFilter()
        f.format.selected = [.raw]
        model.setBrowseFilter(f)
        #expect(model.items.count == Self.newRaw.count)
        #expect(!model.items.contains { $0.url.lastPathComponent == "jpegonly.jpg" })
    }
}

@Suite("验收 M3、X5：拷贝只放文件本身")
struct AcceptanceCopyTests {
    private func readURLs(_ board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @Test("M3 验收：带 .xmp 的 RAW 拷贝一张，剪贴板只有这个文件，没有 .xmp；原文件内容和修改时间不变")
    @MainActor
    func copyOneNoXmp() throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.arw"))
        try Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("a.xmp"))
        try Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("aurora.jpg.xmp"))
        let model = try T5.model(folder)
        let before = try T5.snapshot(folder)
        let board = NSPasteboard(name: NSPasteboard.Name("yilan-accept-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        for name in ["a.arw", "aurora.jpg"] {
            let item = try #require(model.allItems.first { $0.name == name })
            model.copyFiles([item], pasteboard: board)
            #expect(readURLs(board).map(\.lastPathComponent) == [name])
            #expect(board.pasteboardItems?.count == 1)
        }
        #expect(try T5.snapshot(folder) == before)
    }

    @Test("X5 验收：图标视图选 5 张 ⌘C，剪贴板是这 5 个文件本身，没有 .xmp；原文件内容和修改时间不变")
    @MainActor
    func copyFiveFromGrid() throws {
        let (model, folder) = try gridModel(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "harbor_night.png", "IMG_2031.heic", "IMG_2035.heic"])
        try Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("aurora.jpg.xmp"))
        try Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("IMG_2034.jpg.xmp"))
        let before = try T5.snapshot(folder)
        pick(model, [0, 1, 2, 3, 4])
        let chosen = model.selectedItems
        #expect(chosen.count == 5)
        let board = NSPasteboard(name: NSPasteboard.Name("yilan-accept-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.copyFiles(chosen, pasteboard: board)
        let urls = readURLs(board)
        #expect(urls.map(\.lastPathComponent) == chosen.map(\.name))
        #expect(!urls.contains { $0.pathExtension == "xmp" })
        #expect(board.pasteboardItems?.count == 5)
        #expect(try T5.snapshot(folder) == before)
    }
}

@Suite("验收 V5、V6：设置写进 defaults 后读得回来")
struct AcceptanceSettingsTests {
    @Test("V5 验收：缩略图大小写进设置，同一个 defaults 新建 AppSettings 还在")
    @MainActor
    func gridSizePersists() throws {
        let (defaults, _) = T5.suite()
        let s1 = AppSettings(defaults: defaults)
        #expect(s1.gridSize == .default)
        let (model, _) = try gridModel(settings: s1)
        model.setGridSize(.xl)
        #expect(AppSettings(defaults: defaults).gridSize == .xl)
        model.stepGridSize(larger: false)
        #expect(AppSettings(defaults: defaults).gridSize == .l)
    }

    @Test("V6 验收：上次的视图、「打开文件夹时用」写进设置后读得回来；新窗口按它决定视图")
    @MainActor
    func viewPersists() throws {
        let (defaults, _) = T5.suite()
        let s1 = AppSettings(defaults: defaults)
        let folder = try MetaFixtures.copy(sampleNames)
        let model = try T5.model(folder, settings: s1)
        model.setViewMode(.grid)          // 用户主动切换
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.lastViewMode == .grid && s2.viewModeForFolder == .grid)
        s1.openFolderView = .gallery
        let s3 = AppSettings(defaults: defaults)
        #expect(s3.openFolderView == .gallery && s3.viewModeForFolder == .gallery)
        s1.openFolderView = .last
        #expect(AppSettings(defaults: defaults).viewModeForFolder == .grid)
    }

    @Test("V6 验收：从访达打开具体文件（被带进画廊）不改记住的视图，之后再开文件夹仍是用户自己选的")
    @MainActor
    func openFileKeepsRemembered() throws {
        let (defaults, _) = T5.suite()
        let s1 = AppSettings(defaults: defaults)
        s1.lastViewMode = .grid
        let folder = try MetaFixtures.copy(sampleNames)
        let model = try T5.model(folder, settings: s1)
        model.prepareView(forFolder: false)
        #expect(!model.isGrid)
        #expect(AppSettings(defaults: defaults).lastViewMode == .grid)
        model.prepareView(forFolder: true)
        #expect(model.isGrid)
    }
}

@Suite("验收 V3：全屏时 Esc")
struct AcceptanceFullScreenEscTests {
    @Test("V3 验收（模型层）：从图标视图进大图后全屏，一次 Esc 只走退出全屏这一支，不同时回图标视图")
    @MainActor
    func escInFullScreen() throws {
        let (model, _) = try gridModel()
        model.openFromGrid(model.items[2].url)
        #expect(!model.isGrid && model.cameFromGrid)
        model.isFullScreen = true      // 测试里没有真窗口，toggleFullScreen 不会真的退出
        #expect(model.handleKey(try T5.key(53)))
        #expect(!model.isGrid && model.cameFromGrid)          // 同一次 Esc 没有回图标视图
        model.isFullScreen = false
        #expect(model.handleKey(try T5.key(53)))
        #expect(model.isGrid)                                  // 退出全屏后再按一次才回去
    }
}

@Suite("验收 V8：图标视图里的筛选和同步")
struct AcceptanceGridListTests {
    @Test("V8 验收：图标视图里设「不低于 3 星」，只显示符合的")
    @MainActor
    func starFilter() async throws {
        let (model, _) = try gridModel(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "harbor_night.png"])
        await T5.waitFor { model.ratingsLoaded }
        let stars = [0: 5, 1: 3, 2: 2]
        for (i, v) in stars.sorted(by: { $0.key < $1.key }) {
            model.gridClick(model.items[i].url, command: false, shift: false)
            model.rateCurrent(v, fromKeyboard: true)
        }
        await model.ratingWriter.waitUntilIdle()
        await T5.waitFor { model.pendingRatingWrites == 0 }
        model.deselectAllInGrid()
        var f = BrowseFilter()
        f.rating.mode = .stars(3)
        model.setBrowseFilter(f)
        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { (model.ratings[$0.url] ?? 0) >= 3 })
        #expect(model.isGrid && model.current == nil)         // 没有加载大图
    }

    @Test("V8 验收：文件夹里新增文件，经同步后出现在图标视图列表里，原来的选中不变")
    @MainActor
    func addedFileAppears() throws {
        let (model, folder) = try gridModel(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        model.gridClick(model.items[1].url, command: false, shift: false)
        let kept = model.items[1].url
        try FileManager.default.copyItem(at: MetaFixtures.sample.appendingPathComponent("harbor_night.png"),
                                         to: folder.appendingPathComponent("new_shot.png"))
        model.applySync(try FolderScanner.scan(folder: folder))
        #expect(model.items.count == 4 && model.items.contains { $0.name == "new_shot.png" })
        #expect(model.grid.selection == [kept])
        #expect(model.current?.url == kept)
    }
}

@Suite("验收 X1：画廊视图没有多选")
struct AcceptanceGalleryNoMultiTests {
    @Test("X1 验收：画廊视图里 ⌘ / ⇧ + 点按不起作用，isMultiSelection 恒为 false")
    @MainActor
    func galleryNoMulti() throws {
        let folder = try MetaFixtures.copy(sampleNames)
        let model = try T5.model(folder, initial: 1)
        #expect(!model.isGrid && !model.isMultiSelection)
        let cur = model.current
        model.gridClick(model.items[3].url, command: true, shift: false)
        model.gridClick(model.items[5].url, command: false, shift: true)
        model.gridClick(model.items[2].url, command: true, shift: true)
        #expect(model.grid.selection.isEmpty && !model.isMultiSelection)
        #expect(model.current == cur)
        #expect(model.selectionCount == 1)
    }

    @Test("X1 验收：图标视图选了多张，切回画廊后选中收成一张，不再是多选")
    @MainActor
    func backToGalleryCollapses() throws {
        let (model, _) = try gridModel()
        pick(model, [0, 2, 4])
        #expect(model.isMultiSelection)
        model.setViewMode(.gallery)
        #expect(!model.isMultiSelection && model.grid.selection.count == 1 && model.current != nil)
    }
}

@Suite("验收 X3：批量删除不碰别的文件，撤销逐字节还原")
struct AcceptanceBatchDeleteTests {
    @Test("X3 验收：没被选中的文件一个不少、内容和修改时间不变；⌘Z 后被删的内容逐字节相同、星级仍在、处于选中")
    @MainActor
    func untouchedAndRestored() async throws {
        let settings = T5.settings()
        let (model, folder) = try gridModel(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg", "harbor_night.png", "IMG_2031.heic", "river.mp4"],
                                             settings: settings)
        await T5.waitFor { model.ratingsLoaded }
        settings.ratingStorage = .sidecar
        // 给将被删的两张和一张留下的打星
        let targets = [model.items[0].url, model.items[2].url]
        for i in [0, 2, 3] {
            model.gridClick(model.items[i].url, command: false, shift: false)
            model.rateCurrent(i + 1 > 5 ? 5 : i + 2, fromKeyboard: true)
        }
        await model.ratingWriter.waitUntilIdle()
        await T5.waitFor { model.pendingRatingWrites == 0 }
        let stars = Dictionary(uniqueKeysWithValues: targets.map { ($0, model.ratings[$0] ?? 0) })
        #expect(stars.values.allSatisfy { $0 > 0 })

        let before = try T5.snapshot(folder)
        pick(model, [0, 2])
        #expect(Set(model.selectedItems.map(\.url)) == Set(targets))
        model.requestBatchDelete()
        model.confirmBatchDelete()
        await T5.waitFor { !model.batchRunning && model.allItems.count == 4 }
        let goneNames = Set(targets.map(\.lastPathComponent))
        let goneStems = Set(targets.map { $0.deletingPathExtension().lastPathComponent })
        // 没选中的：文件名、内容、修改时间都不变（含它们自己的 .xmp）
        let after = try T5.snapshot(folder)
        let keepKeys = before.keys.filter { key in
            !goneNames.contains(key) && !(key.hasSuffix(".xmp") && goneStems.contains((key as NSString).deletingPathExtension))
        }
        #expect(!keepKeys.isEmpty)
        for key in keepKeys { #expect(after[key] == before[key], "\(key) 被动过") }
        #expect(after.count == keepKeys.count)
        // 选中的和它们的 .xmp 都进了废纸篓
        #expect(targets.allSatisfy { !exists($0) })
        // ⌘Z
        await model.undoLast()
        #expect(try T5.snapshot(folder) == before)            // 全部文件（含 .xmp）逐字节相同、修改时间不变
        #expect(Set(model.selectedItems.map(\.url)) == Set(targets))
        await T5.waitFor { targets.allSatisfy { model.ratings[$0] == stars[$0] } }
        for url in targets { #expect(model.ratings[url] == stars[url]) }
    }
}

@Suite("验收 T2、T3 与图标视图的组合")
struct AcceptanceFeatureGridTests {
    @Test("T2/T3 验收：评星关掉后，图标视图多选按数字键没有反应、文件不变、不弹提示")
    @MainActor
    func digitsInMultiGridWhenRatingOff() async throws {
        let settings = T5.settings()
        settings.featureRating = false
        let (model, folder) = try gridModel(settings: settings)
        pick(model, [0, 1, 2])
        #expect(model.isMultiSelection)
        let before = try T5.snapshot(folder)
        for n in [0, 1, 3, 5] {
            #expect(model.handleKey(try T5.key(T5.digitKeyCodes[n]!, "\(n)")))     // 按键被吃掉
        }
        await model.ratingWriter.waitUntilIdle()
        #expect(try T5.snapshot(folder) == before)
        #expect(model.ratings.isEmpty)
        #expect(model.toast == nil)
        #expect(!model.undoHistory.canUndo)
        #expect(model.grid.selection.count == 3)
    }

    @Test("T2/T3 验收：评星关掉后，图标视图只选一张按数字键同样没有反应、文件不变")
    @MainActor
    func digitsInSingleGridWhenRatingOff() async throws {
        let settings = T5.settings()
        settings.featureRating = false
        let (model, folder) = try gridModel(settings: settings)
        model.gridClick(model.items[1].url, command: false, shift: false)
        let before = try T5.snapshot(folder)
        for n in [5, 0, 2] { _ = model.handleKey(try T5.key(T5.digitKeyCodes[n]!, "\(n)")) }
        await model.ratingWriter.waitUntilIdle()
        #expect(try T5.snapshot(folder) == before)
        #expect(model.ratings.isEmpty && !model.undoHistory.canUndo && model.toast == nil)
    }

    @Test("T3 验收：评星关掉期间删除带 .xmp 的图片，小文件一起进废纸篓，⌘Z 一起回来")
    @MainActor
    func trashWithSidecarWhileRatingOff() async throws {
        let settings = T5.settings()
        settings.featureRating = false
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        try Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("aurora.jpg.xmp"))
        let model = try T5.model(folder, settings: settings)
        let victim = try #require(model.current)
        #expect(victim.name == "aurora.jpg")
        let before = try T5.snapshot(folder)
        model.requestDelete()
        if model.pendingDelete != nil { model.confirmDelete() }
        await T5.waitFor { !exists(victim.url) }
        #expect(!exists(folder.appendingPathComponent("aurora.jpg.xmp")))
        #expect(exists(folder.appendingPathComponent("IMG_2034.jpg")))
        await model.undoLast()
        #expect(try T5.snapshot(folder) == before)
    }
}
