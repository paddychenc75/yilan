import AppKit
import Foundation
import Testing
@testable import Yilan

// 图标视图接进浏览模型（spec 第 3、4、9 节）。用可控的假解码，数得出有没有加载大图

private actor CountingDecoder {
    private(set) var calls = 0
    func decode(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> DecodedImage {
        calls += 1
        let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: ctx.makeImage()!, pixelSize: CGSize(width: 4, height: 3))
    }
}

private let names = ["aurora.jpg", "harbor_night.png", "IMG_2031.heic", "IMG_2034.jpg", "IMG_2035.heic", "IMG_2052.jpg", "river.mp4"]

@MainActor
private func makeModel(_ files: [String] = names, initial: Int? = 0, settings: AppSettings? = nil,
                       decoder: CountingDecoder = CountingDecoder()) throws -> (BrowserModel, URL, CountingDecoder) {
    let folder = try MetaFixtures.copy(files)
    let pipeline = ImagePipeline(decode: { await decoder.decode($0, $1) })
    let model = BrowserModel(settings: settings ?? T5.settings(), recents: RecentFolders(defaults: T5.suite().defaults), pipeline: pipeline)
    let items = try FolderScanner.scan(folder: folder)
    model.apply(FolderScanner.Result(folder: folder, items: items, initialIndex: items.isEmpty ? nil : initial,
                                     sidecars: SidecarIndex.scan(folder: folder, media: items)))
    return (model, folder, decoder)
}

@MainActor
private func name(_ model: BrowserModel) -> String? { model.current?.name }

@MainActor
private func selected(_ model: BrowserModel) -> [String] { model.selectedItems.map(\.name) }

@Suite("视图切换")
struct ViewModeTests {
    @Test("画廊 → 图标：只选中当前这一张；图标 → 画廊：显示选中的那一张（spec SEL-03、SEL-04）")
    @MainActor
    func roundTrip() async throws {
        let (model, _, _) = try makeModel(initial: 2)
        let third = try #require(name(model))
        model.setViewMode(.grid)
        #expect(model.isGrid && selected(model) == [third] && name(model) == third)
        #expect(model.displayed == nil && model.displayedItem == nil)
        model.gridClick(model.items[4].url, command: false, shift: false)
        model.setViewMode(.gallery)
        #expect(!model.isGrid && name(model) == model.items[4].name)
        await T5.waitFor { model.displayed != nil }
        #expect(model.displayedItem == model.items[4])
    }

    @Test("多选时切到画廊：显示最后点的那一张，选中收成它；没有选中时显示焦点项（spec SEL-04）")
    @MainActor
    func fromMulti() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.gridClick(model.items[1].url, command: false, shift: false)
        model.gridClick(model.items[5].url, command: true, shift: false)
        model.gridClick(model.items[3].url, command: true, shift: false)
        #expect(model.isMultiSelection && model.current == nil)
        model.setViewMode(.gallery)
        #expect(name(model) == model.items[3].name)
        model.setViewMode(.grid)
        #expect(selected(model) == [model.items[3].name])
        model.deselectAllInGrid()
        model.setViewMode(.gallery)
        #expect(name(model) == model.items[3].name)      // 焦点项
    }

    @Test("图标视图里换选中、多选，都不加载大图（spec SEL-05）")
    @MainActor
    func noDecoding() async throws {
        let (model, _, decoder) = try makeModel()
        await T5.waitFor { model.displayed != nil }
        model.setViewMode(.grid)
        try? await Task.sleep(for: .milliseconds(150))
        let before = await decoder.calls
        for i in [3, 5, 1, 4] { model.gridClick(model.items[i].url, command: false, shift: false) }
        model.gridClick(model.items[2].url, command: true, shift: false)
        _ = model.handleKey(try T5.key(124))
        _ = model.handleKey(try T5.key(125))
        model.selectAllInGrid()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await decoder.calls == before)
        #expect(model.displayed == nil)
    }

    @Test("只有主动切换才记住视图；从图标视图打开一张不算（spec V6-01）")
    @MainActor
    func remembers() throws {
        let settings = T5.settings()
        let (model, _, _) = try makeModel(settings: settings)
        #expect(settings.lastViewMode == .gallery)
        model.setViewMode(.grid)
        #expect(settings.lastViewMode == .grid)
        model.openFromGrid(model.items[2].url)
        #expect(!model.isGrid && settings.lastViewMode == .grid)
        model.returnToGrid()
        #expect(model.isGrid && settings.lastViewMode == .grid)
    }

    @Test("打开文件夹按设置选视图；打开一个具体文件始终用画廊，且不改记忆（spec V6-03、V6-04）")
    @MainActor
    func openChoosesView() throws {
        let settings = T5.settings()
        settings.lastViewMode = .grid
        let (model, _, _) = try makeModel(settings: settings)
        model.prepareView(forFolder: true)
        #expect(model.isGrid)
        model.prepareView(forFolder: false)
        #expect(!model.isGrid && settings.lastViewMode == .grid)
        settings.openFolderView = .gallery
        model.prepareView(forFolder: true)
        #expect(!model.isGrid)
        settings.openFolderView = .grid
        settings.lastViewMode = .gallery
        model.prepareView(forFolder: true)
        #expect(model.isGrid)
    }

    @Test("正在编辑、有删除确认框时不能切换（spec V2-05）")
    @MainActor
    func blocked() async throws {
        let (model, _, _) = try makeModel()
        model.requestDelete()
        model.toggleViewMode()
        #expect(!model.isGrid)
        model.cancelDelete()
        await T5.waitFor { model.displayed != nil }
        model.enterEdit()
        #expect(model.edit != nil)
        _ = model.handleKey(try T5.key(5, "g"))
        #expect(!model.isGrid)
    }
}

@Suite("从图标视图进大图再回来")
struct CameFromGridTests {
    @Test("回车、空格、双击进大图；Esc 或空格回来，那一张仍然选中（spec V3-01 至 V3-05）")
    @MainActor
    func enterAndReturn() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.gridClick(model.items[3].url, command: false, shift: false)
        #expect(model.handleKey(try T5.key(36)))                 // 回车
        #expect(!model.isGrid && model.cameFromGrid && name(model) == model.items[3].name)
        #expect(model.handleKey(try T5.key(53)))                 // Esc
        #expect(model.isGrid && selected(model) == [model.items[3].name])
        #expect(model.handleKey(try T5.key(49, " ")))            // 空格
        #expect(!model.isGrid && model.cameFromGrid)
        #expect(model.handleKey(try T5.key(49, " ")))            // 再按空格回去
        #expect(model.isGrid)
    }

    @Test("在大图里用方向键换了图，标记还在，回去时选中的是现在这张（spec V3-03）")
    @MainActor
    func keepsFlagWhileBrowsing() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.openFromGrid(model.items[1].url)
        model.next()
        model.next()
        #expect(model.cameFromGrid && name(model) == model.items[3].name)
        model.returnToGrid()
        #expect(selected(model) == [model.items[3].name])
    }

    @Test("不是从图标视图进来的：Esc 和空格跟以前一样没有反应（spec V3-04）")
    @MainActor
    func notFromGrid() throws {
        let (model, _, _) = try makeModel()
        #expect(!model.handleKey(try T5.key(53)))
        #expect(!model.handleKey(try T5.key(49, " ")))
        #expect(!model.isGrid)
        // 按 G 进图标视图再按 G 回来：也不算「从图标视图进来」
        _ = model.handleKey(try T5.key(5, "g"))
        _ = model.handleKey(try T5.key(5, "g"))
        #expect(!model.isGrid && !model.cameFromGrid)
        #expect(!model.handleKey(try T5.key(53)))
    }

    @Test("视频：空格是播放 / 暂停，不是回去；Esc 才回去（spec V3-05）")
    @MainActor
    func video() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        let video = try #require(model.items.first { $0.kind == .video })
        model.openFromGrid(video.url)
        _ = model.handleKey(try T5.key(49, " "))
        #expect(!model.isGrid)
        #expect(model.handleKey(try T5.key(53)))
        #expect(model.isGrid)
    }

    @Test("多选时按回车：打开最后点的那一张，选中收成它；没有选中时没有反应（spec V3-02）")
    @MainActor
    func enterWithMulti() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.deselectAllInGrid()
        #expect(model.handleKey(try T5.key(36)))
        #expect(model.isGrid)
        model.gridClick(model.items[1].url, command: false, shift: false)
        model.gridClick(model.items[4].url, command: true, shift: false)
        _ = model.handleKey(try T5.key(36))
        #expect(!model.isGrid && name(model) == model.items[4].name)
    }

    @Test("换文件夹后标记清除（spec V3-03）")
    @MainActor
    func clearedOnNewFolder() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.openFromGrid(model.items[1].url)
        let other = try MetaFixtures.copy(["aurora.jpg"])
        let items = try FolderScanner.scan(folder: other)
        model.apply(FolderScanner.Result(folder: other, items: items, initialIndex: 0, sidecars: .empty))
        #expect(!model.cameFromGrid)
    }
}

@Suite("图标视图里的按键")
struct GridKeyTests {
    @MainActor
    private func grid(columns: Int = 3) throws -> BrowserModel {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.gridColumns = columns
        return model
    }

    @Test("方向键上下左右、Home、End（spec V4-01、V4-02）")
    @MainActor
    func arrows() throws {
        let model = try grid()          // 7 张、3 列
        model.gridClick(model.items[0].url, command: false, shift: false)
        _ = model.handleKey(try T5.key(124))
        #expect(name(model) == model.items[1].name)
        _ = model.handleKey(try T5.key(125))
        #expect(name(model) == model.items[4].name)
        _ = model.handleKey(try T5.key(123))
        #expect(name(model) == model.items[3].name)
        _ = model.handleKey(try T5.key(126))
        #expect(name(model) == model.items[0].name)
        _ = model.handleKey(try T5.key(119))
        #expect(name(model) == model.items[6].name)
        _ = model.handleKey(try T5.key(115))
        #expect(name(model) == model.items[0].name)
    }

    @Test("⌘A 全选、⌥⌘A 取消；Esc 取消选中（spec X1-05、X1-06、K-02）")
    @MainActor
    func selectAll() throws {
        let model = try grid()
        _ = model.handleKey(try T5.key(0, "a", .command))
        #expect(model.grid.selection.count == 7 && model.current == nil)
        _ = model.handleKey(try T5.key(0, "a", [.command, .option]))
        #expect(model.grid.selection.isEmpty)
        _ = model.handleKey(try T5.key(0, "a", .command))
        #expect(model.handleKey(try T5.key(53)))
        #expect(model.grid.selection.isEmpty)
        #expect(!model.handleKey(try T5.key(53)))     // 没有可做的事了
    }

    @Test("画廊视图里 ⌘A 没有反应（spec K-09）")
    @MainActor
    func selectAllInGallery() throws {
        let (model, _, _) = try makeModel()
        _ = model.handleKey(try T5.key(0, "a", .command))
        #expect(model.grid.selection.count <= 1 && !model.isGrid)
    }

    @Test("R、E、Z、T 在图标视图里没有反应（spec K-12、K-14、K-15）")
    @MainActor
    func inert() throws {
        let model = try grid()
        for (code, ch) in [(UInt16(15), "r"), (14, "e"), (6, "z"), (17, "t")] {
            #expect(model.handleKey(try T5.key(code, ch)))
        }
        #expect(model.rotation == 0 && model.edit == nil && model.stripVisible)
    }

    @Test("⌘+ / ⌘− 调缩略图大小，到头不再变（spec V5-02）")
    @MainActor
    func size() throws {
        let model = try grid()
        #expect(model.gridSize == .m)
        _ = model.handleKey(try T5.key(24, "=", .command))
        #expect(model.gridSize == .l)
        for _ in 0..<5 { _ = model.handleKey(try T5.key(24, "+", .command)) }
        #expect(model.gridSize == .xl)
        for _ in 0..<9 { _ = model.handleKey(try T5.key(27, "-", .command)) }
        #expect(model.gridSize == .xs)
        #expect(model.settings.gridSize == .xs)
    }

    @Test("数字键给选中的那一张评星；没有选中时没有反应（spec V4-04）")
    @MainActor
    func rating() async throws {
        let model = try grid()
        await T5.waitFor { model.ratingsLoaded }
        model.gridClick(model.items[0].url, command: false, shift: false)
        _ = model.handleKey(try T5.key(21, "4"))
        #expect(model.ratings[model.items[0].url] == 4)
        model.deselectAllInGrid()
        _ = model.handleKey(try T5.key(23, "5"))
        await model.ratingWriter.waitUntilIdle()
        #expect(model.ratings.values.filter { $0 == 5 }.isEmpty)
    }

    @Test("⌫：选中一张时走单张删除；删除后选中后面一张（spec V4-05、V4-06）")
    @MainActor
    func deleteSingle() async throws {
        let settings = T5.settings()
        settings.confirmBeforeDelete = false
        let (model, _, _) = try makeModel(settings: settings)
        model.setViewMode(.grid)
        model.gridClick(model.items[2].url, command: false, shift: false)
        let next = model.items[3].name
        _ = model.handleKey(try T5.key(51))
        await T5.waitFor { model.items.count == 6 }
        #expect(selected(model) == [next] && name(model) == next)
        // 没有选中时按 ⌫ 没有反应
        model.deselectAllInGrid()
        _ = model.handleKey(try T5.key(51))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.items.count == 6 && model.pendingDelete == nil)
    }
}

@Suite("图标视图：筛选和同步")
struct GridListChangeTests {
    @Test("改筛选条件后，不符合的从选中里去掉（spec V8-02）")
    @MainActor
    func filterPrunes() throws {
        let (model, _, _) = try makeModel()
        model.setViewMode(.grid)
        model.selectAllInGrid()
        var f = BrowseFilter()
        f.format.selected = [.jpeg]
        model.setBrowseFilter(f)
        #expect(model.items.count == 3)
        #expect(Set(selected(model)) == Set(model.items.map(\.name)))
        model.setFilter(.videos)     // 没有符合「JPEG」的视频：类型切换被拒绝，选中不变
        #expect(model.grid.selection.count == 3)
    }

    @Test("别的程序删了选中的文件：自动从选中里去掉（spec V8-04、EC-04）")
    @MainActor
    func syncPrunes() throws {
        let (model, folder, _) = try makeModel()
        model.setViewMode(.grid)
        model.gridClick(model.items[1].url, command: false, shift: false)
        model.gridClick(model.items[4].url, command: true, shift: false)
        let gone = model.items[4]
        try FileManager.default.removeItem(at: gone.url)
        model.applySync(try FolderScanner.scan(folder: folder))
        #expect(selected(model) == [model.items[1].name])
        #expect(name(model) == model.items[1].name)      // 只剩一张：它成了「当前」
        #expect(!model.items.contains(gone))
    }

    @Test("图标视图里给选中的文件改星导致不符合筛选：暂留，换选中时才消失（spec V8-03）")
    @MainActor
    func sticky() async throws {
        let (model, _, _) = try makeModel(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        await T5.waitFor { model.ratingsLoaded }
        model.setViewMode(.grid)
        var f = BrowseFilter()
        f.rating.mode = .unrated
        model.setBrowseFilter(f)
        #expect(model.items.count == 3)
        model.gridClick(model.items[0].url, command: false, shift: false)
        model.rateCurrent(3, fromKeyboard: true)
        #expect(model.items.count == 3)                  // 暂留
        model.gridClick(model.items[1].url, command: false, shift: false)
        #expect(model.items.count == 2 && selected(model) == [model.items[0].name])
        await model.ratingWriter.waitUntilIdle()
    }
}
