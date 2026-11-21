import AppKit
import Foundation
import Testing
@testable import Yilan

// 功能开关（spec 第 8 节）。都在临时目录的样例副本上做

@Suite("功能开关：设置")
struct FeatureSettingsTests {
    @Test("默认都开；回调只在真的变了时触发；单独一项不保存，只有简洁模式这一个开关记得住")
    @MainActor
    func defaultsAndPersistence() {
        let s = T5.suite()
        let settings = AppSettings(defaults: s.defaults, domainName: s.name)
        #expect(settings.featureRating && settings.featureFilter && settings.featureEdit)
        var calls: [(Feature, Bool)] = []
        settings.featureChanged = { calls.append(($0, $1)) }
        settings.featureRating = false
        settings.featureRating = false
        #expect(calls.count == 1 && calls[0].0 == .rating && calls[0].1 == false)
        // 内部某一项单独改了不会保存：下次打开只看简洁模式（这里没开），三项都在
        let again = AppSettings(defaults: s.defaults, domainName: s.name)
        #expect(again.featureRating && again.featureFilter && again.featureEdit && !again.simpleMode)
    }
}

@Suite("功能开关：评星")
struct RatingSwitchTests {
    @Test("关掉后数字键没有反应，文件夹里什么都不变（spec T2-03、T3-01）")
    @MainActor
    func keysDoNothing() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg", "harbor_night.png"])
        let settings = T5.settings()
        settings.featureRating = false
        let model = try T5.model(folder, settings: settings)
        let before = try T5.snapshot(folder)
        for n in [3, 5, 0, 1] {
            #expect(model.handleKey(try T5.key(T5.digitKeyCodes[n]!, "\(n)")))   // 按键照样吃掉，不响
        }
        model.rateCurrent(4, fromKeyboard: false)
        await model.ratingWriter.waitUntilIdle()
        #expect(try T5.snapshot(folder) == before)
        #expect(model.ratings.isEmpty)
        #expect(!model.undoHistory.canUndo)
        #expect(model.toast == nil)
        #expect(model.ratingFlash == nil)
        #expect(model.currentRating == nil)
    }

    @Test("关掉的那一刻：评星的撤销记录作废，之后 ⌘Z 不改任何文件（spec T2-07）")
    @MainActor
    func dropsUndo() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        await T5.waitFor { model.ratingsLoaded }
        model.rateCurrent(4, fromKeyboard: true)
        await model.ratingWriter.waitUntilIdle()
        await T5.waitFor { model.pendingRatingWrites == 0 }
        #expect(model.undoHistory.canUndo)
        let rated = try T5.snapshot(folder)
        settings.featureRating = false
        #expect(!model.undoHistory.canUndo)
        await model.undoLast()
        await model.ratingWriter.waitUntilIdle()
        #expect(try T5.snapshot(folder) == rated)
    }

    @Test("关掉时清掉星级筛选条件，格式条件保留（spec T2-04）")
    @MainActor
    func clearsRatingFilter() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg", "harbor_night.png"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        await T5.waitFor { model.ratingsLoaded }
        var f = BrowseFilter()
        f.rating.mode = .unrated
        f.format.selected = [.jpeg]
        model.setBrowseFilter(f)
        #expect(model.items.count == 2)
        settings.featureRating = false
        #expect(!model.browseFilter.rating.isActive)
        #expect(model.browseFilter.format.selected == [.jpeg])
        // 关掉后不能再设星级条件
        model.setRatingCriterion(.stars(3))
        #expect(!model.browseFilter.rating.isActive)
    }

    @Test("重新打开：星级原样读回来（spec T3-01）")
    @MainActor
    func comesBack() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        await T5.waitFor { model.ratingsLoaded }
        model.rateCurrent(5, fromKeyboard: true)
        await model.ratingWriter.waitUntilIdle()
        await T5.waitFor { model.pendingRatingWrites == 0 }
        let url = try #require(model.current?.url)
        settings.featureRating = false
        #expect(model.currentRating == nil)
        settings.featureRating = true
        await T5.waitFor { model.ratingsLoaded && model.ratings[url] != nil }
        #expect(model.ratings[url] == 5)
    }

    @Test("快捷键页：关掉的功能不列出来（spec T2-05、T2-09、T2-12）")
    @MainActor
    func shortcutsPane() {
        let all = ShortcutsPane.sections(rating: true, filter: true, edit: true)
        let ids = { (s: [ShortcutsPane.Section]) in s.flatMap { $0.rows.map(\.id) } }
        #expect(all.first?.id == "评星")
        #expect(ids(all).contains("打开 / 关闭筛选面板") && ids(all).contains("编辑") && ids(all).contains("撤销上一次评星 / 删除（批量删除一次全部撤销）"))
        let off = ShortcutsPane.sections(rating: false, filter: false, edit: false)
        #expect(off.first?.id != "评星")
        #expect(!ids(off).contains("打开 / 关闭筛选面板") && !ids(off).contains("编辑"))
        #expect(ids(off).contains("撤销上一次删除") && !ids(off).contains("撤销上一次评星 / 删除（批量删除一次全部撤销）"))
    }
}

@Suite("功能开关：筛选和编辑")
struct FilterEditSwitchTests {
    @Test("关掉筛选：条件全部清除、面板关闭、⌘F 没有反应；类型切换照常（spec T2-09、T2-10）")
    @MainActor
    func filterOff() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg", "harbor_night.png", "river.mp4"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        var f = BrowseFilter()
        f.format.selected = [.png]
        model.setBrowseFilter(f)
        model.toggleFilterPanel()
        #expect(model.filterPanelOpen && model.items.count == 1)
        settings.featureFilter = false
        #expect(!model.filterPanelOpen && !model.browseFilter.isActive)
        #expect(model.items.count == 4)
        _ = model.handleKey(try T5.key(3, "f", .command))
        #expect(!model.filterPanelOpen)
        model.setFilter(.videos)
        #expect(model.items.count == 1)
    }

    @Test("关掉编辑：E 和菜单进不了编辑，没有「保存旋转」，R 仍然能转（spec T2-12、T2-13）")
    @MainActor
    func editOff() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        await T5.waitFor { model.displayed != nil }
        #expect(model.canEditCurrent)
        settings.featureEdit = false
        _ = model.handleKey(try T5.key(14, "e"))
        model.enterEdit()
        #expect(model.edit == nil)
        _ = model.handleKey(try T5.key(15, "r"))
        #expect(model.rotation == 1)
        #expect(!model.showsSaveRotation)
        settings.featureEdit = true
        #expect(model.showsSaveRotation)
    }

    @Test("简洁模式：一个开关，评星、编辑、复制 / 移动到文件夹一起关、一起开；筛选保留；正在编辑时不能打开（spec T1、T2-15）")
    @MainActor
    func simpleMode() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let settings = T5.settings()
        let model = try T5.model(folder, settings: settings)
        #expect(!model.simpleMode && model.ratingEnabled && model.filterEnabled && model.editEnabled && model.transferEnabled)
        model.setSimpleMode(true)
        #expect(model.simpleMode && !model.ratingEnabled && model.filterEnabled && !model.editEnabled && !model.transferEnabled)
        // 菜单里没有编辑、复制到、移动到
        let actions = model.fileMenu(.single).compactMap(\.action)
        #expect(!actions.contains(.edit) && !actions.contains(.copyTo) && !actions.contains(.moveTo))
        #expect(actions.contains(.copy) && actions.contains(.trash) && actions.contains(.rotateLeft))
        model.setSimpleMode(false)
        #expect(model.ratingEnabled && model.filterEnabled && model.editEnabled && model.transferEnabled)
        #expect(model.fileMenu(.single).compactMap(\.action).contains(.copyTo))
        _ = await T5.waitFor { model.displayed != nil }
        model.enterEdit()
        #expect(model.edit != nil)
        model.setSimpleMode(true)
        #expect(!model.simpleMode && model.editEnabled)
    }

    @Test("简洁模式记得住：下次打开还是简洁模式，三项功能跟着它，不存在别的组合（spec T1）")
    @MainActor
    func simpleModePersists() throws {
        let suite = T5.suite()
        let first = AppSettings(defaults: suite.defaults)
        #expect(!first.simpleMode && first.featureRating && first.featureFilter && first.featureEdit)
        first.simpleMode = true
        // 即使内部某一项被单独改过，重新打开时也只看简洁模式这一个开关
        first.featureRating = true
        let second = AppSettings(defaults: suite.defaults)
        #expect(second.simpleMode && !second.featureRating && second.featureFilter && !second.featureEdit)
        second.simpleMode = false
        let third = AppSettings(defaults: suite.defaults)
        #expect(!third.simpleMode && third.featureRating && third.featureFilter && third.featureEdit)
    }
}
