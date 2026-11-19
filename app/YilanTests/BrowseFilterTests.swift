import AppKit
import Foundation
import Testing
@testable import Yilan

// 筛选（spec 第 6 节）

private func item(_ name: String) -> MediaItem {
    let url = URL(fileURLWithPath: "/tmp/yilan-filter/\(name)")
    return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!, fileSize: 1,
                     modificationDate: Date(timeIntervalSince1970: 1_000))
}

private func defaults() -> UserDefaults {
    let name = "yilan-filter-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Suite("筛选模型")
struct BrowseFilterModelTests {
    let items = ["a.ARW", "b.CR3", "c.jpg", "d.JPEG", "e.heic", "f.HEIF", "g.png", "h.mov", "i.mp4", "j.gif"].map(item)

    @Test("格式分组：RAW 合并，heic/heif、jpg/jpeg 合并")
    func groups() {
        #expect(items.map { FormatGroup.of($0) } == [.raw, .raw, .jpeg, .jpeg, .heic, .heic, .png, .mov, .mp4, .gif])
        #expect(FormatGroup.mp4.kind == .video)
    }

    @Test("星级：不低于 N、未评星；没读出来的按未评星")
    func rating() {
        let f = RatingCriterion(mode: .stars(3))
        #expect(f.matches(ItemFacts(item: items[0], rating: 4)))
        #expect(!f.matches(ItemFacts(item: items[0], rating: 2)))
        #expect(!f.matches(ItemFacts(item: items[0], rating: nil)))
        #expect(RatingCriterion(mode: .unrated).matches(ItemFacts(item: items[0], rating: nil)))
    }

    @Test("格式之间是或，星级和格式之间是且；摘要和种类数")
    func combine() {
        var f = BrowseFilter()
        f.format.selected = [.raw, .jpeg]
        f.rating.mode = .stars(4)
        let ratings: [URL: Int] = [items[0].url: 5, items[2].url: 3, items[3].url: 4, items[4].url: 5]
        let result = items.filter { f.matches(ItemFacts(item: $0, rating: ratings[$0.url])) }
        #expect(result.map(\.name) == ["a.ARW", "d.JPEG"])
        #expect(f.activeKinds == 2)
        #expect(f.summaryParts.count == 2)
        f.format.selected = [.raw]
        #expect(f.summaryParts.last == "RAW")
    }

    @Test("数量：格式数按其他条件算，类型排除的不计；列出文件夹里实际有的格式")
    func facets() {
        var f = BrowseFilter()
        f.rating.mode = .stars(4)
        let ratings: [URL: Int] = [items[0].url: 5, items[3].url: 4, items[7].url: 4]
        let facets = FilterFacets.compute(items: items, ratings: ratings, type: .images, filter: f)
        #expect(facets.presentFormats == [.raw, .heic, .jpeg, .png, .gif, .mp4, .mov])
        #expect(facets.formatCounts[.raw] == 1)
        #expect(facets.formatCounts[.jpeg] == 1)
        #expect(facets.formatCounts[.mov] == nil)        // 类型是图片，视频不计
        #expect(facets.resultCount == 2)
        #expect(facets.unratedCount == 6)                // 图片里未评星的（8 张图片，2 张有星）
        #expect(facets.total == 10)
        let types = FilterFacets.typeCounts(items: items, ratings: ratings, filter: f)
        // 有星级条件时视频都不算（视频没有星级）
        #expect(types[.all] == 2 && types[.images] == 2 && types[.videos] == 0)
    }

    @Test("改条件后当前文件不在结果里：后面第一个，否则前面最近的")
    func selection() {
        let all = items
        let newList = [items[1], items[5], items[8]]
        #expect(FilterSelection.indexAfterFilterChange(keeping: items[3], in: all, newList: newList) == 1)   // d → f
        #expect(FilterSelection.indexAfterFilterChange(keeping: items[9], in: all, newList: newList) == 2)   // j → i（前面最近）
        #expect(FilterSelection.indexAfterFilterChange(keeping: items[5], in: all, newList: newList) == 1)   // 还在
        #expect(FilterSelection.indexAfterFilterChange(keeping: items[0], in: all, newList: []) == nil)
    }

    @Test("2000 个文件：过滤 + 全部数量在 20 毫秒内")
    func performance() {
        let many = (0..<2000).map { i in item("p\(i).\(["ARW", "jpg", "heic", "mov"][i % 4])") }
        var ratings: [URL: Int] = [:]
        for (i, it) in many.enumerated() { ratings[it.url] = i % 6 }
        var f = BrowseFilter()
        f.rating.mode = .stars(3)
        f.format.selected = [.raw, .jpeg]
        let start = ContinuousClock.now
        let result = many.filter { f.matches(ItemFacts(item: $0, rating: ratings[$0.url])) }
        let facets = FilterFacets.compute(items: many, ratings: ratings, type: .all, filter: f)
        _ = FilterFacets.typeCounts(items: many, ratings: ratings, filter: f)
        let elapsed = ContinuousClock.now - start
        #expect(result.count == facets.resultCount)
        #expect(elapsed < .milliseconds(20), "用了 \(elapsed)")
    }
}

@Suite("筛选：浏览模型", .serialized)
@MainActor
struct BrowseFilterBrowserTests {
    private func model(_ names: [String], ratings: [Int]) -> BrowserModel {
        let m = BrowserModel(settings: AppSettings(defaults: defaults()), recents: RecentFolders(defaults: defaults()))
        let list = names.map(item)
        m.apply(FolderScanner.Result(folder: URL(fileURLWithPath: "/tmp/yilan-filter"), items: list, initialIndex: 0))
        m.ratingLoadTask?.cancel()
        for (i, it) in list.enumerated() { m.ratings[it.url] = ratings[i] }
        m.ratingsLoaded = true
        return m
    }

    @Test("筛选后序号和方向键只在结果里；清除后回到全部")
    func basic() {
        let m = model(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], ratings: [5, 1, 4, 0])
        m.setRatingCriterion(.stars(4))
        #expect(m.items.map(\.name) == ["a.jpg", "c.jpg"])
        #expect(m.current?.name == "a.jpg")
        m.next()
        #expect(m.current?.name == "c.jpg")
        m.clearBrowseFilter()
        #expect(m.items.count == 4)
        #expect(m.current?.name == "c.jpg")
    }

    @Test("结果为 0 时清除筛选：回到设筛选前在看的那张（F1-03）")
    func clearAfterEmptyReturns() {
        let m = model(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], ratings: [1, 2, 3, 4])
        m.select(2)                                      // 在看 c
        m.setRatingCriterion(.stars(5))                  // 没有 5 星
        #expect(m.items.isEmpty)
        #expect(m.current == nil)
        m.clearBrowseFilter()
        #expect(m.items.count == 4)
        #expect(m.current?.name == "c.jpg")
    }

    @Test("结果为 0 后改成另一个有结果的条件：按变空前那张的位置选（F1-03）")
    func relaxAfterEmpty() {
        let m = model(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], ratings: [4, 1, 1, 4])
        m.select(2)                                      // 在看 c（1 星）
        m.setRatingCriterion(.stars(5))
        #expect(m.items.isEmpty)
        m.setRatingCriterion(.stars(4))                  // a、d：c 不在里面，显示它后面的第一个
        #expect(m.current?.name == "d.jpg")
    }

    @Test("结果不为 0 时清除筛选：和以前一样停在当前这张（F1-03）")
    func clearNonEmptyUnchanged() {
        let m = model(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], ratings: [5, 1, 4, 0])
        m.select(1)                                      // b
        m.setRatingCriterion(.stars(4))                  // a、c：b 不在，显示 c
        #expect(m.current?.name == "c.jpg")
        m.clearBrowseFilter()
        #expect(m.current?.name == "c.jpg")
    }

    @Test("给当前文件改星导致不符合：暂留到切走（F-01、F-02）")
    func sticky() {
        let m = model(["a.jpg", "b.jpg", "c.jpg"], ratings: [5, 5, 5])
        m.setRatingCriterion(.stars(4))
        m.next()                                         // b
        // 直接改内存里的星级（不写盘），模拟打星
        m.ratings[m.current!.url] = 2
        m.ratingsDidChange()
        #expect(m.items.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"])   // b 暂留
        #expect(m.current?.name == "b.jpg")
        m.next()
        #expect(m.current?.name == "c.jpg")
        #expect(m.items.map(\.name) == ["a.jpg", "c.jpg"])            // 切走后消失
        #expect(m.currentIndex == 1)
    }

    @Test("切换类型时另一类的已选格式、以及星级条件自动取消（R5b-07）；任何星级条件都不含视频；结果为空时显示空状态")
    func typeSwitchAndEmpty() {
        let m = model(["a.jpg", "b.mov", "c.mp4", "d.jpg"], ratings: [5, 0, 0, 0])
        m.setRatingCriterion(.unrated)
        #expect(m.items.map(\.name) == ["d.jpg"])                     // 未评星也不含视频
        var f = BrowseFilter()
        f.format.selected = [.jpeg, .mov]
        f.rating.mode = .stars(1)
        m.setBrowseFilter(f)
        m.setFilter(.images)
        m.setFilter(.all)
        m.setBrowseFilter(f)
        m.clearBrowseFilter()
        f.rating.mode = .any
        m.setBrowseFilter(f)
        m.setFilter(.videos)
        #expect(m.browseFilter.format.selected == [.mov])
        #expect(!m.browseFilter.rating.isActive)
        m.setFilter(.images)
        m.setRatingCriterion(.stars(5))
        f = m.browseFilter
        f.format.selected = [.png]
        m.setBrowseFilter(f)
        #expect(m.items.isEmpty)
        #expect(m.showsEmptyFilterResult)
        #expect(m.current == nil)
    }

    @Test("换文件夹后筛选清空")
    func resetOnFolderChange() {
        let m = model(["a.jpg", "b.jpg"], ratings: [5, 0])
        m.setRatingCriterion(.unrated)
        m.filterPanelOpen = true
        m.apply(FolderScanner.Result(folder: URL(fileURLWithPath: "/tmp/yilan-filter-2"), items: [item("x.jpg")], initialIndex: 0))
        #expect(!m.browseFilter.isActive)
        #expect(!m.filterPanelOpen)
    }

    @Test("「及以上」和「仅」：保留 N，立即生效；数量跟着变；视频不在结果里")
    func comparisonModes() {
        let m = model(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.mov"], ratings: [3, 4, 3, 0, 3])
        m.setRatingCriterion(.stars(3))
        #expect(m.items.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(m.browseFilter.summaryParts == [String(localized: "≥\(3) 星")])
        m.setRatingComparison(.exactly)
        #expect(m.browseFilter.rating.mode == .stars(3))
        #expect(m.items.map(\.name) == ["a.jpg", "c.jpg"])
        #expect(m.filterFacets.resultCount == 2)
        #expect(m.browseFilter.summaryParts == [String(localized: "仅 \(3) 星")])
        #expect(m.filterFacets.exactCounts[3] == 2 && m.filterFacets.atLeastCount(3) == 3)
    }

    @Test("5 星：两种方式是一回事，按及以上；摘要是 ≥5 星")
    func levelFive() {
        let m = model(["a.jpg", "b.jpg"], ratings: [5, 4])
        m.setRatingComparison(.exactly)
        m.setRatingCriterion(.stars(5))
        #expect(m.browseFilter.rating.effectiveComparison == .atLeast)
        #expect(m.items.map(\.name) == ["a.jpg"])
        #expect(m.browseFilter.summaryParts == [String(localized: "5 星")])
    }

    @Test("清除筛选、换文件夹后回到及以上")
    func comparisonReset() {
        let m = model(["a.jpg"], ratings: [3])
        m.setRatingCriterion(.stars(3))
        m.setRatingComparison(.exactly)
        m.clearBrowseFilter()
        #expect(m.browseFilter.rating.comparison == .atLeast)
        m.setRatingComparison(.exactly)
        m.resetBrowseFilter()
        #expect(m.browseFilter.rating.comparison == .atLeast)
    }

    @Test("面板开着时数字键只选星级、绝不评星：再按同一个数字切换方式，0 = 不限")
    func digitsInPanel() throws {
        let m = model(["a.jpg", "b.jpg"], ratings: [3, 0])
        m.filterPanelOpen = true
        func press(_ keyCode: UInt16, _ chars: String) throws {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode))
            #expect(m.handleKey(e))
        }
        try press(20, "3")
        #expect(m.browseFilter.rating.mode == .stars(3) && m.browseFilter.rating.comparison == .atLeast)
        try press(20, "3")
        #expect(m.browseFilter.rating.comparison == .exactly)
        try press(20, "3")
        #expect(m.browseFilter.rating.comparison == .atLeast)
        try press(29, "0")
        #expect(m.browseFilter.rating.mode == .any)
        // 当前照片的星级没被改，也没有写入或撤销记录
        #expect(m.ratings[m.allItems[0].url] == 3 && m.ratings[m.allItems[1].url] == 0)
        #expect(!m.canUndo)
        // 面板关上后数字键回到评星（这里的文件是假的，评星会因读不到文件而提示，不改筛选）
        m.filterPanelOpen = false
        try press(18, "1")
        #expect(m.browseFilter.rating.mode == .any)
    }

    @Test("点已选中的那颗星 = 回到不限")
    func toggleOff() {
        // StarRow 点当前已亮的最后一颗传 0，面板把 0 当成不限
        let m = model(["a.jpg"], ratings: [3])
        m.setRatingCriterion(.stars(3))
        m.setRatingCriterion(.any)
        #expect(!m.browseFilter.rating.isActive)
    }

    @Test("类型是「视频」时不会出现星级条件：切换时清掉，点星和数字键都不起作用")
    func noRatingWithVideos() {
        let m = model(["a.jpg", "b.mov"], ratings: [3, 0])
        // 有星级条件时「视频」的数量是 0，切不过去（按钮置灰）
        m.setRatingCriterion(.stars(3))
        m.setFilter(.videos)
        #expect(m.filter != .videos)
        m.setRatingCriterion(.any)
        m.setFilter(.videos)
        #expect(m.filter == .videos)
        m.setRatingCriterion(.stars(4))
        m.filterPanelOpen = true
        m.filterDigit(2)
        #expect(!m.browseFilter.rating.isActive)
        #expect(m.items.map(\.name) == ["b.mov"])
    }

    @Test("5 星的摘要写「5 星」，不写 ≥5")
    func fiveSummary() {
        let m = model(["a.jpg"], ratings: [5])
        m.setRatingCriterion(.stars(5))
        #expect(m.browseFilter.summaryParts == [String(localized: "5 星")])
    }

    @Test("面板开着时切换（方向键、滚轮、箭头按钮都走这里）先关面板")
    func navigationClosesPanel() {
        let m = model(["a.jpg", "b.jpg"], ratings: [0, 0])
        m.filterPanelOpen = true
        m.next()
        #expect(!m.filterPanelOpen)
        #expect(m.current?.name == "b.jpg")
    }
}
