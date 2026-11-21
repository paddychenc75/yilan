import AppKit
import Foundation
import Testing
@testable import Yilan

// 复制到文件夹… / 移动到文件夹…（spec R9）。每条会动用户文件的规则都比较内容和修改时间（T5.snapshot）

private let names = ["aurora.jpg", "harbor_night.png", "IMG_2034.jpg", "IMG_2052.jpg", "river.mp4"]

private func tempFolder(_ label: String = "dest") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yilan-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
}

/// 隐藏的临时文件（半成品）也算上
private func hiddenLeftovers(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".yilan-") }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// 源文件夹：五个文件，其中 aurora.jpg、IMG_2034.jpg 各带一个 .xmp 小文件
@MainActor
private func makeGrid(_ files: [String] = names) throws -> (BrowserModel, URL) {
    let folder = try MetaFixtures.copy(files)
    for base in ["aurora", "IMG_2034"] where files.contains(where: { $0.hasPrefix(base + ".") }) {
        try Data("<x:xmpmeta xmp:Rating=\"3\" \(base)/>".utf8).write(to: folder.appendingPathComponent(base + ".xmp"))
    }
    let model = try T5.model(folder)
    model.setViewMode(.grid)
    return (model, folder)
}

@MainActor
private func pick(_ model: BrowserModel, _ wanted: [String]) {
    model.deselectAllInGrid()
    for (n, name) in wanted.enumerated() {
        if let item = model.items.first(where: { $0.name == name }) { model.gridClick(item.url, command: n > 0, shift: false) }
    }
}

/// 跨磁盘：不能直接改名，走「复制、核对、删原件」
private func crossVolume(copy: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) -> BatchTransfer.Disk {
    BatchTransfer.Disk(sameVolume: { _, _ in false }, copy: copy)
}

private struct DiskFull: Error {}

@Suite("复制 / 移动：后台部分")
struct BatchTransferRunTests {
    @Test("候选名字：原名、「名字 2.扩展名」……；小文件用同样的新名字（spec R9-05）")
    func naming() {
        #expect(BatchTransfer.numbered("IMG_2035.HEIC", 1) == "IMG_2035.HEIC")
        #expect(BatchTransfer.numbered("IMG_2035.HEIC", 2) == "IMG_2035 2.HEIC")
        #expect(BatchTransfer.numbered("README", 3) == "README 3")
        let photo = URL(fileURLWithPath: "/a/IMG_2035.HEIC")
        #expect(BatchTransfer.sidecarName(URL(fileURLWithPath: "/a/IMG_2035.xmp"), photo: photo, newName: "IMG_2035 2.HEIC", numbered: true) == "IMG_2035 2.xmp")
        #expect(BatchTransfer.sidecarName(URL(fileURLWithPath: "/a/IMG_2035.HEIC.xmp"), photo: photo, newName: "IMG_2035 2.HEIC", numbered: true) == "IMG_2035 2.HEIC.xmp")
        #expect(BatchTransfer.sidecarName(URL(fileURLWithPath: "/a/IMG_2035.xmp"), photo: photo, newName: "IMG_2035.HEIC", numbered: false) == "IMG_2035.xmp")
    }

    @Test("停止：正在处理的做完后停下，其余没动（spec R9-06、X3-11）")
    func stop() throws {
        let source = try MetaFixtures.copy(names)
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        let items = try FolderScanner.scan(folder: source)
        let flag = BatchTrash.StopFlag()
        let result = BatchTransfer.run(BatchTrash.jobs(for: items, sidecars: SidecarIndex.scan(folder: source, media: items)),
                                       to: dest, mode: .move, stop: flag, progress: { done in if done == 2 { flag.stop() } })
        #expect(result.placed.count == 2 && result.untouched.count == items.count - 2)
        #expect(try listing(dest).count == 2)
        // 没动的文件内容和修改时间都没变
        let after = try T5.snapshot(source)
        for item in result.untouched { #expect(after[item.name] == before[item.name]) }
    }

    @Test("跨磁盘移动：复制到一半失败时原件不动，目标里的半成品删掉（spec R9-09）")
    func crossVolumeFailure() throws {
        let source = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        let items = try FolderScanner.scan(folder: source)
        // aurora.jpg 写了一半磁盘满了
        let disk = crossVolume(copy: { from, to in
            if from.lastPathComponent == "aurora.jpg" {
                try Data(try Data(contentsOf: from).prefix(100)).write(to: to)
                throw DiskFull()
            }
            try FileManager.default.copyItem(at: from, to: to)
        })
        let result = BatchTransfer.run(BatchTrash.jobs(for: items, sidecars: .empty), to: dest, mode: .move, stop: .init(), disk: disk)
        #expect(result.failed.map(\.item.name) == ["aurora.jpg"])
        #expect(result.placed.map(\.item.name) == ["IMG_2034.jpg"])
        #expect(try T5.snapshot(source)["aurora.jpg"] == before["aurora.jpg"])
        #expect(try listing(source) == ["aurora.jpg"])
        #expect(try listing(dest) == ["IMG_2034.jpg"])
        #expect(try hiddenLeftovers(dest).isEmpty)
        // 移过去的那个：内容和修改时间都和原来一样
        #expect(try T5.snapshot(dest)["IMG_2034.jpg"] == before["IMG_2034.jpg"])
    }

    @Test("跨磁盘移动：复制出来的大小不对就不删原件（spec R9-09）")
    func sizeMismatch() throws {
        let source = try MetaFixtures.copy(["aurora.jpg"])
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        let items = try FolderScanner.scan(folder: source)
        let disk = crossVolume(copy: { from, to in try Data(try Data(contentsOf: from).prefix(10)).write(to: to) })
        let result = BatchTransfer.run(BatchTrash.jobs(for: items, sidecars: .empty), to: dest, mode: .move, stop: .init(), disk: disk)
        #expect(result.failed.count == 1 && result.placed.isEmpty)
        #expect(try T5.snapshot(source) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test("跨磁盘移动成功：先复制、核对，再删原件；内容和修改时间不变（spec R9-09）")
    func crossVolumeSuccess() throws {
        let source = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg"])
        try Data("side".utf8).write(to: source.appendingPathComponent("aurora.xmp"))
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        let items = try FolderScanner.scan(folder: source)
        let result = BatchTransfer.run(BatchTrash.jobs(for: items, sidecars: SidecarIndex.scan(folder: source, media: items)),
                                       to: dest, mode: .move, stop: .init(), disk: crossVolume())
        #expect(result.placed.count == 2 && result.failed.isEmpty)
        #expect(try listing(source).isEmpty)
        #expect(try T5.snapshot(dest) == before)
        // 撤销：全部移回原位，内容和修改时间不变
        let back = BatchTransfer.moveBack(result.placed, disk: crossVolume())
        #expect(back.failed.isEmpty && back.restored.count == 2)
        #expect(try T5.snapshot(source) == before)
        #expect(try listing(dest).isEmpty)
    }

    @Test("小文件放不过去：照片也退回原处，这一项算失败（不丢星级）")
    func sidecarFailureRollsBack() throws {
        let source = try MetaFixtures.copy(["aurora.jpg"])
        try Data("side".utf8).write(to: source.appendingPathComponent("aurora.xmp"))
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        let items = try FolderScanner.scan(folder: source)
        let disk = crossVolume(copy: { from, to in
            if from.pathExtension == "xmp" { throw DiskFull() }
            try FileManager.default.copyItem(at: from, to: to)
        })
        for mode in [BatchTransfer.Mode.copy, .move] {
            let result = BatchTransfer.run(BatchTrash.jobs(for: items, sidecars: SidecarIndex.scan(folder: source, media: items)),
                                           to: dest, mode: mode, stop: .init(), disk: disk)
            #expect(result.failed.count == 1 && result.placed.isEmpty)
            #expect(try T5.snapshot(source) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
        }
    }
}

@Suite("复制 / 移动：接进浏览模型")
struct TransferModelTests {
    @Test("复制 5 张（2 张带小文件）：目标里 5 个文件 2 个小文件，逐字节相同；原文件不变；已有的同名文件不覆盖（PRD 验收、spec R9-04、R9-05、R9-07）")
    @MainActor
    func copyAcceptance() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder("待修")
        // 目标里已经有一个 aurora.jpg（内容不同）
        let occupied = dest.appendingPathComponent("aurora.jpg")
        try Data("someone else's photo".utf8).write(to: occupied)
        let destBefore = try T5.snapshot(dest)
        let sourceBefore = try T5.snapshot(source)
        model.selectAllInGrid()
        let selection = model.grid.selection
        await model.performTransfer(.copy, model.selectedItems, to: dest)
        #expect(!model.batchRunning && model.batchReport == nil)
        let after = try T5.snapshot(dest)
        // 已有的同名文件没有被覆盖
        #expect(after["aurora.jpg"] == destBefore["aurora.jpg"])
        // 新文件和小文件用加了序号的名字，内容和修改时间都和原文件一样
        #expect(after["aurora 2.jpg"] == sourceBefore["aurora.jpg"])
        #expect(after["aurora 2.xmp"] == sourceBefore["aurora.xmp"])
        for name in ["harbor_night.png", "IMG_2034.jpg", "IMG_2034.xmp", "IMG_2052.jpg", "river.mp4"] {
            #expect(after[name] == sourceBefore[name], "\(name)")
        }
        #expect(after.count == 1 + 5 + 2)
        #expect(try hiddenLeftovers(dest).isEmpty)
        // 原文件夹完全没变；选择不变；复制不进撤销记录
        #expect(try T5.snapshot(source) == sourceBefore)
        #expect(model.grid.selection == selection && model.items.count == 5)
        #expect(!model.canUndo)
        #expect(model.toast?.text == String(localized: "已复制 \(5) 项到“\(dest.lastPathComponent)”，其中 \(1) 项重名，已加序号"))
        #expect(model.toast?.detail == String(localized: "在访达中显示"))
        guard case .reveal(let urls)? = model.toast?.action else {
            Issue.record("提示条上应该有「在访达中显示」")
            return
        }
        #expect(urls.count == 5 && urls.allSatisfy { exists($0) })
    }

    @Test("没有重名时的提示条（spec R9-07）")
    @MainActor
    func copyPlain() async throws {
        let (model, _) = try makeGrid()
        let dest = try tempFolder()
        pick(model, ["IMG_2052.jpg", "river.mp4"])
        await model.performTransfer(.copy, model.selectedItems, to: dest)
        #expect(Set(try listing(dest)) == ["IMG_2052.jpg", "river.mp4"])
        #expect(model.toast?.text == String(localized: "已复制 \(2) 项到“\(dest.lastPathComponent)”"))
    }

    @Test("复制到当前文件夹：得到带序号的副本，出现在列表里；原文件不变（spec R9-03）")
    @MainActor
    func copyIntoSameFolder() async throws {
        let (model, source) = try makeGrid()
        let before = try T5.snapshot(source)
        pick(model, ["aurora.jpg", "IMG_2052.jpg"])
        await model.performTransfer(.copy, model.selectedItems, to: source)
        let after = try T5.snapshot(source)
        for (name, value) in before { #expect(after[name] == value) }
        #expect(after["aurora 2.jpg"] == before["aurora.jpg"])
        #expect(after["aurora 2.xmp"] == before["aurora.xmp"])
        #expect(after["IMG_2052 2.jpg"] == before["IMG_2052.jpg"])
        #expect(model.allItems.contains { $0.name == "aurora 2.jpg" } && model.allItems.count == 7)
        #expect(model.selectedItems.map(\.name) == ["aurora.jpg", "IMG_2052.jpg"])
    }

    @Test("移动到它们本来在的文件夹：提示一句，什么都不做（spec R9-03）")
    @MainActor
    func moveIntoSameFolder() async throws {
        let (model, source) = try makeGrid()
        let before = try T5.snapshot(source)
        pick(model, ["aurora.jpg", "IMG_2052.jpg"])
        await model.performTransfer(.move, model.selectedItems, to: source)
        #expect(model.toast?.text == String(localized: "这些文件已经在这个文件夹里"))
        #expect(try T5.snapshot(source) == before)
        #expect(model.items.count == 5 && model.grid.selection.count == 2 && !model.canUndo)
    }

    @Test("移动：文件从列表里消失，选中清空；⌘Z 全部移回原位并选中，内容和修改时间不变（PRD 验收、spec R9-08）")
    @MainActor
    func moveAndUndo() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder("待修")
        let before = try T5.snapshot(source)
        pick(model, ["aurora.jpg", "IMG_2034.jpg", "river.mp4"])
        let moved = model.selectedItems
        await model.performTransfer(.move, moved, to: dest)
        #expect(Set(try listing(source)) == ["harbor_night.png", "IMG_2052.jpg"])
        let there = try T5.snapshot(dest)
        for name in ["aurora.jpg", "aurora.xmp", "IMG_2034.jpg", "IMG_2034.xmp", "river.mp4"] { #expect(there[name] == before[name], "\(name)") }
        #expect(model.items.map(\.name) == ["harbor_night.png", "IMG_2052.jpg"])
        #expect(model.grid.selection.isEmpty)
        #expect(model.toast?.text == String(localized: "已移动 \(3) 项到“\(dest.lastPathComponent)”"))
        #expect(model.toast?.action == .undo)
        #expect(model.undoMenuTitle == String(localized: "撤销“移动到文件夹”"))
        await model.undoLast()
        #expect(try T5.snapshot(source) == before)
        #expect(try listing(dest).isEmpty)
        #expect(model.items.count == 5)
        #expect(Set(model.selectedItems.map(\.url)) == Set(moved.map(\.url)))
        #expect(!model.canUndo)
    }

    @Test("移动时目标里有同名文件：不覆盖，加序号（spec R9-05）")
    @MainActor
    func moveRenames() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder()
        try Data("theirs".utf8).write(to: dest.appendingPathComponent("IMG_2034.jpg"))
        let destBefore = try T5.snapshot(dest)
        let before = try T5.snapshot(source)
        pick(model, ["IMG_2034.jpg", "IMG_2052.jpg"])
        await model.performTransfer(.move, model.selectedItems, to: dest)
        let after = try T5.snapshot(dest)
        #expect(after["IMG_2034.jpg"] == destBefore["IMG_2034.jpg"])
        #expect(after["IMG_2034 2.jpg"] == before["IMG_2034.jpg"])
        #expect(after["IMG_2034 2.xmp"] == before["IMG_2034.xmp"])
        #expect(after["IMG_2052.jpg"] == before["IMG_2052.jpg"])
        await model.undoLast()
        #expect(try T5.snapshot(source) == before)
        #expect(try T5.snapshot(dest) == destBefore)
    }

    @Test("目标不可写：每一项都失败，原文件不动，提示框列出（spec R9-10）")
    @MainActor
    func destinationNotWritable() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder()
        chmod(dest.path, 0o555)
        defer { chmod(dest.path, 0o755) }
        let before = try T5.snapshot(source)
        pick(model, ["aurora.jpg", "IMG_2052.jpg"])
        await model.performTransfer(.copy, model.selectedItems, to: dest)
        var report = try #require(model.batchReport)
        #expect(report.title == String(localized: "有 \(2) 个项目无法复制"))
        #expect(report.rows.allSatisfy { $0.reason == String(localized: "没有权限") })
        model.dismissBatchReport(performAction: false)
        await model.performTransfer(.move, model.selectedItems, to: dest)
        report = try #require(model.batchReport)
        #expect(report.title == String(localized: "有 \(2) 个项目无法移动"))
        model.dismissBatchReport(performAction: false)
        #expect(try T5.snapshot(source) == before)
        #expect(model.items.count == 5 && model.grid.selection.count == 2 && !model.canUndo)
    }

    @Test("个别文件失败：其余照常，失败的留在原处并保持选中（spec R9-10）")
    @MainActor
    func partialMoveFailure() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder()
        let before = try T5.snapshot(source)
        pick(model, ["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        let disk = crossVolume(copy: { from, to in
            if from.lastPathComponent == "IMG_2052.jpg" { throw DiskFull() }
            try FileManager.default.copyItem(at: from, to: to)
        })
        await model.performTransfer(.move, model.selectedItems, to: dest, disk: disk)
        let report = try #require(model.batchReport)
        #expect(report.rows.map(\.item.name) == ["IMG_2052.jpg"])
        #expect(try T5.snapshot(source)["IMG_2052.jpg"] == before["IMG_2052.jpg"])
        #expect(model.selectedItems.map(\.name) == ["IMG_2052.jpg"])
        #expect(Set(try listing(dest)) == ["aurora.jpg", "aurora.xmp", "IMG_2034.jpg", "IMG_2034.xmp"])
        #expect(try hiddenLeftovers(dest).isEmpty)
        model.dismissBatchReport(performAction: false)
        // 移走的两张可以撤销
        await model.undoLast()
        #expect(try T5.snapshot(source) == before)
    }

    @Test("撤销移动时原位置已有同名文件：其余照常移回并选中，列出移不回的；那个文件不被覆盖（spec R9-08、X3-17）")
    @MainActor
    func undoConflict() async throws {
        let (model, source) = try makeGrid()
        let dest = try tempFolder()
        pick(model, ["aurora.jpg", "IMG_2052.jpg"])
        await model.performTransfer(.move, model.selectedItems, to: dest)
        let squatter = source.appendingPathComponent("aurora.jpg")
        try Data("new file".utf8).write(to: squatter)
        let destBefore = try T5.snapshot(dest)
        await model.undoLast()
        let report = try #require(model.batchReport)
        #expect(report.rows.map(\.item.name) == ["aurora.jpg"])
        #expect(report.rows.first?.reason == String(localized: "原位置已经有同名文件"))
        #expect(try Data(contentsOf: squatter) == Data("new file".utf8))
        #expect(try T5.snapshot(dest)["aurora.jpg"] == destBefore["aurora.jpg"])
        #expect(exists(source.appendingPathComponent("IMG_2052.jpg")))
        #expect(model.selectedItems.map(\.name) == ["IMG_2052.jpg"])
        #expect(!model.canUndo)
    }

    @Test("画廊视图里移动当前这一张：显示下一张（spec R9-01）")
    @MainActor
    func galleryMove() async throws {
        let folder = try MetaFixtures.copy(["aurora.jpg", "IMG_2034.jpg", "IMG_2052.jpg"])
        let model = try T5.model(folder, initial: 1)
        let dest = try tempFolder()
        #expect(model.transferTargets.map(\.name) == ["IMG_2034.jpg"])
        await model.performTransfer(.move, model.transferTargets, to: dest)
        #expect(model.current?.name == "IMG_2052.jpg")
        #expect(try listing(dest) == ["IMG_2034.jpg"])
        await model.undoLast()
        #expect(model.current?.name == "IMG_2034.jpg" && model.allItems.count == 3)
    }

    @Test("菜单项：有文件时可用，批量操作进行中置灰（spec R9-01、X3-08）")
    @MainActor
    func menuEnabled() throws {
        let (model, _) = try makeGrid()
        pick(model, ["aurora.jpg", "IMG_2052.jpg"])
        let pair = model.fileMenu(.gridItem).filter { $0.action == .copyTo || $0.action == .moveTo }
        #expect(pair.count == 2 && pair.allSatisfy { $0.enabled })
        model.batchProgress = BatchProgress(kind: .copy, total: 2)
        #expect(!model.canTransfer)
        model.batchProgress = nil
        model.deselectAllInGrid()
        #expect(!model.canTransfer)
    }
}
