import AppKit
import Foundation
import Testing
@testable import Yilan

// 右键菜单、「⋯」菜单的清单和拷贝（spec 第 2 节）

@MainActor
private func titles(_ items: [FileMenuItem]) -> [String] {
    items.map { $0.action == nil ? "—" : $0.title }
}

@Suite("文件菜单清单")
struct FileMenuTests {
    @Test("单张菜单的项目和顺序（spec M1-02），「移到废纸篓」之前多一组复制到 / 移动到文件夹（spec R9-01）")
    @MainActor
    func single() async throws {
        let model = try T5.model(try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"]))
        await T5.waitFor { model.displayed != nil }
        let menu = model.fileMenu(.single)
        #expect(menu.compactMap(\.action) == [.reveal, .copy, .copyPath, .rotateLeft, .rotateRight, .edit, .toggleInfo, .copyTo, .moveTo, .trash])
        #expect(titles(menu).filter { $0 == "—" }.count == 3)
        #expect(Array(titles(menu).suffix(4)) == [String(localized: "复制到文件夹…"), String(localized: "移动到文件夹…"), "—", String(localized: "移到废纸篓")])
        #expect(menu.allSatisfy { $0.action == nil || $0.enabled })
        #expect(menu.first { $0.action == .copy }?.shortcut == MenuShortcut(key: "c", command: true))
        #expect(menu.first { $0.action == .trash }?.shortcut == .delete)
    }

    @Test("「⋯」菜单：只多一项拷贝，不显示快捷键（spec M4-01）")
    @MainActor
    func more() throws {
        let model = try T5.model(try MetaFixtures.copy(["aurora.jpg"]))
        let menu = model.fileMenu(.more)
        #expect(menu.compactMap(\.action) == [.reveal, .copy, .copyPath, .trash, .open])
        #expect(menu.allSatisfy { $0.shortcut == nil })
    }

    @Test("同名的项目在两处文字相同（spec M4-03）")
    @MainActor
    func sameTitles() throws {
        let model = try T5.model(try MetaFixtures.copy(["aurora.jpg"]))
        let single = Dictionary(uniqueKeysWithValues: model.fileMenu(.single).compactMap { i in i.action.map { ($0, i.title) } })
        for item in model.fileMenu(.more) {
            guard let action = item.action, let other = single[action] else { continue }
            #expect(other == item.title)
        }
    }

    @Test("视频：编辑置灰，旋转可用（spec M4-04）；编辑功能关掉后没有这一项（spec M4-05）")
    @MainActor
    func videoAndSwitch() async throws {
        let settings = T5.settings()
        let model = try T5.model(try MetaFixtures.copy(["river.mp4", "aurora.jpg"]), initial: 1, settings: settings)
        #expect(model.current?.kind == .video)
        let menu = model.fileMenu(.single)
        #expect(menu.first { $0.action == .edit }?.enabled == false)
        #expect(menu.first { $0.action == .rotateLeft }?.enabled == true)
        settings.featureEdit = false
        #expect(!model.fileMenu(.single).contains { $0.action == .edit })
    }

    @Test("信息面板开着时写「隐藏信息」（spec M1-07）")
    @MainActor
    func infoTitle() throws {
        let model = try T5.model(try MetaFixtures.copy(["aurora.jpg"]))
        let shown = model.fileMenu(.single).first { $0.action == .toggleInfo }?.title
        model.setInfoVisible(true)
        let hidden = model.fileMenu(.single).first { $0.action == .toggleInfo }?.title
        #expect(shown != nil && hidden != nil && shown != hidden)
    }

    @Test("没有文件、正在编辑、有确认框时不弹右键菜单（spec M1-05、M1-08）")
    @MainActor
    func canShow() async throws {
        let model = try T5.model(try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"]))
        #expect(model.canShowContextMenu)
        model.requestDelete()
        #expect(!model.canShowContextMenu)
        model.cancelDelete()
        await T5.waitFor { model.displayed != nil }
        model.enterEdit()
        #expect(!model.canShowContextMenu)
        let empty = try T5.model(try MetaFixtures.copy([]))
        #expect(!empty.canShowContextMenu)
    }

    @Test("系统菜单：项目数、分隔线、置灰都照清单来")
    @MainActor
    func nsMenu() throws {
        let model = try T5.model(try MetaFixtures.copy(["river.mp4"]))
        let items = model.fileMenu(.single)
        let menu = ContextMenuPresenter.make(items) { _ in }
        #expect(menu.items.count == items.count)
        for (entry, item) in zip(items, menu.items) {
            #expect(item.isSeparatorItem == (entry.action == nil))
            if entry.action != nil {
                #expect(item.title == entry.title)
                #expect(item.isEnabled == entry.enabled)
            }
        }
    }
}

@Suite("拷贝文件")
struct CopyFilesTests {
    @Test("剪贴板里是文件地址和路径；原文件不变（spec M3-01、M3-04）")
    @MainActor
    func copies() throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let model = try T5.model(folder)
        let before = try T5.snapshot(folder)
        let board = NSPasteboard(name: NSPasteboard.Name("yilan-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.copyFiles(model.allItems, pasteboard: board)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent).sorted() == ["IMG_2034.jpg", "aurora.jpg"])
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.string(forType: .string)?.hasSuffix(".jpg") == true)
        #expect(try T5.snapshot(folder) == before)
        #expect(model.toast != nil)
    }

    @Test("不带 .xmp 小文件（spec M3-02）")
    @MainActor
    func noSidecar() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg"])
        let model = try T5.model(folder)
        await T5.waitFor { model.ratingsLoaded }
        model.rateCurrent(4, fromKeyboard: true)
        await model.ratingWriter.waitUntilIdle()
        await T5.waitFor { model.pendingRatingWrites == 0 }
        await T5.waitFor { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).contains("aurora.xmp")) == true }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("aurora.xmp"))
        let board = NSPasteboard(name: NSPasteboard.Name("yilan-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.copyFiles(model.allItems, pasteboard: board)
        #expect(board.pasteboardItems?.count == 1)
    }

    @Test("文件已经不在原处：剪贴板不变，给提示（spec M3-04）")
    @MainActor
    func missing() throws {
        let folder = try MetaFixtures.copy(["aurora.jpg"])
        let model = try T5.model(folder)
        let board = NSPasteboard(name: NSPasteboard.Name("yilan-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("原来的内容", forType: .string)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("aurora.jpg"))
        model.copyFiles(model.allItems, pasteboard: board)
        #expect(board.string(forType: .string) == "原来的内容")
        #expect(model.toast?.tone == .warning)
    }
}

@Suite("大图区的范围")
struct StageZoneTests {
    private let size = CGSize(width: 1280, height: 800)

    @Test("顶部栏、缩略图栏、信息面板不算大图区（spec M1-01、M2-02）")
    func zones() {
        func stage(_ x: CGFloat, _ y: CGFloat, strip: Bool = true, info: Bool = false) -> Bool {
            StageZones.isStage(x: x, yFromTop: y, size: size, stripVisible: strip, infoVisible: info, fullScreen: false)
        }
        #expect(stage(640, 400))
        #expect(stage(30, 400))            // 左箭头上
        #expect(!stage(640, 20))           // 顶部栏
        #expect(!stage(640, 760))          // 缩略图栏
        #expect(stage(640, 760, strip: false))
        #expect(stage(60, 760))            // 缩略图栏两侧的空白
        #expect(!stage(1200, 300, info: true))
        #expect(stage(1200, 300))
        #expect(!stage(-5, 300))
    }
}
