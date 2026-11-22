import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Yilan

// RAW 不能编辑，改为「导出为 JPEG」（spec C6-01 ~ C6-13）。
// 写文件、删文件都只在临时目录的副本上做；撤销用的是测试进程里的假废纸篓（见 TrashService.fakeTrashDirectory）。
// 「假 RAW」：垃圾字节里夹一张 JPEG，扩展名是 RAW 的，系统解不了 → 相机预览图状态（spec C1-02）。
// 系统能完整解码的 RAW 用本机的样张（app/Fixtures/raw，不进仓库），没有时那几项只做假 RAW 的部分

// MARK: - 工具

/// 左半红、右半蓝（存储方向）：方向 6 显示时左边转到上面，能看出有没有转对
private func halves(_ width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return ctx.makeImage()!
}

/// 带拍摄信息的内嵌 JPEG
private func previewJPEG(_ width: Int = 1200, _ height: Int = 800, orientation: Int? = nil) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:20:30"] as CFDictionary,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T-1"] as CFDictionary,
    ]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, halves(width, height), props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// 不含 FF 的垃圾字节
private func junk(_ count: Int) -> Data { Data((0..<count).map { UInt8($0 % 251) }) }

/// 新建临时文件夹，放进假 RAW 和样例里的文件
private func folder(fakeRaw: [String: Data] = [:], samples: [String] = [], raws: [String] = []) throws -> URL {
    let dir = try MetaFixtures.copy(samples)
    for name in raws { try FileManager.default.copyItem(at: MetaFixtures.raw.appendingPathComponent(name), to: dir.appendingPathComponent(name)) }
    for (name, data) in fakeRaw { try data.write(to: dir.appendingPathComponent(name)) }
    return dir
}

private func fakeRaw(orientation: Int? = nil) -> Data { junk(4096) + previewJPEG(orientation: orientation) + junk(8192) }

/// 文件夹里所有文件（包括隐藏的临时文件）
private func allNames(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }

private func exportName(_ base: String, _ n: Int = 1) -> String { ExportNaming.baseName(base, attempt: n) + ".jpg" }

/// 本机有的、系统能完整解码的 RAW 样张：优先索尼（带厂商私有数据），其次 DNG
private var fullRawSample: String? {
    let all = MetaFixtures.rawSamples
    return all.first { $0.uppercased().hasSuffix(".ARW") } ?? all.first { $0.uppercased().hasSuffix(".DNG") }
}

private func color(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

private func image(_ url: URL) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

private func props(_ url: URL) -> [CFString: Any] {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
}

private func shiftCmdE() throws -> NSEvent { try T5.key(14, "e", [.command, .shift]) }

// MARK: - 写文件

@Suite("RAW 导出为 JPEG：写文件")
struct RawExportWriterTests {
    @Test("命名：「原名 导出.jpg」，已有时加编号，和 RAW 同一个文件夹（spec C6-06）")
    func naming() {
        let raw = URL(fileURLWithPath: "/tmp/a/DSC_0821.ARW")
        let first = ExportNaming.exportURL(for: raw, exists: { _ in false })
        #expect(first.deletingLastPathComponent().path == "/tmp/a")
        #expect(first.lastPathComponent == exportName("DSC_0821"))
        let taken: Set<String> = [exportName("DSC_0821"), exportName("DSC_0821", 2)]
        let third = ExportNaming.exportURL(for: raw, exists: { taken.contains($0.lastPathComponent) })
        #expect(third.lastPathComponent == exportName("DSC_0821", 3))
        // 中文界面「导出」，英文界面「exported」（TX-E8）
        let suffix = ExportNaming.baseName("", attempt: 1)
        #expect(suffix == " 导出" || suffix == " exported")
        #expect(ExportNaming.baseName("X", attempt: 2) == "X" + suffix + " 2")
    }

    @Test("相机预览图状态的 RAW：导出最大的内嵌 JPEG，按方向转正，方向标记写成 1，带拍摄信息；RAW 不变（spec C6-04、C6-05）")
    func cameraPreview() throws {
        let dir = try folder(fakeRaw: ["DSC_0001.x3f": fakeRaw(orientation: 6)])
        let raw = dir.appendingPathComponent("DSC_0001.x3f")
        let before = try T5.snapshot(dir)
        let written = try RawExport.export(try MetaFixtures.item(raw), cameraPreview: false)
        #expect(written.cameraPreview)   // 系统解不了：自己退到相机预览图
        #expect(written.url.lastPathComponent == exportName("DSC_0001"))
        // 1200 × 800 竖拍（方向 6）→ 800 × 1200，左半（红）转到上面
        #expect(EditWriter.orientedSize(written.url) == PixelSize(width: 800, height: 1200))
        #expect(EditWriter.sourceInfo(written.url).orientation == 1)
        #expect(EditWriter.sourceInfo(written.url).typeIdentifier == "public.jpeg")
        let out = try #require(image(written.url))
        let top = color(out, x: 400, y: 100), bottom = color(out, x: 400, y: 1100)
        #expect(top.r > 200 && top.b < 80 && bottom.b > 200 && bottom.r < 80)
        // 系统读不了 RAW 的信息：用内嵌 JPEG 自己带的
        let exif = props(written.url)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:01 10:20:30")
        let tiff = props(written.url)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "TestCam")
        // RAW 一个字节都没改、修改时间不变；除了导出的 JPEG 没有别的文件（临时文件已改名）
        var after = try T5.snapshot(dir)
        after[written.url.lastPathComponent] = nil
        #expect(after == before)
        #expect(allNames(dir) == ["DSC_0001.x3f", written.url.lastPathComponent])
    }

    @Test("已有同名的导出文件：不覆盖，新文件名后面加编号（spec C6-06）")
    func noOverwrite() throws {
        let dir = try folder(fakeRaw: ["DSC_0002.srw": fakeRaw()])
        let raw = dir.appendingPathComponent("DSC_0002.srw")
        let existing = dir.appendingPathComponent(exportName("DSC_0002"))
        try Data("别人的文件".utf8).write(to: existing)
        let item = try MetaFixtures.item(raw)
        let second = try RawExport.export(item, cameraPreview: true)
        #expect(second.url.lastPathComponent == exportName("DSC_0002", 2))
        #expect(try Data(contentsOf: existing) == Data("别人的文件".utf8))
        let third = try RawExport.export(item, cameraPreview: true)
        #expect(third.url.lastPathComponent == exportName("DSC_0002", 3))
    }

    @Test("失败：文件夹不可写、RAW 不在原处、解码失败——不留任何文件，RAW 不变（spec C6-11）")
    func failures() throws {
        // 文件夹不可写
        let dir = try folder(fakeRaw: ["DSC_0003.x3f": fakeRaw()])
        let raw = dir.appendingPathComponent("DSC_0003.x3f")
        let item = try MetaFixtures.item(raw)
        let before = try T5.snapshot(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: EditSaveError.notWritable(folder: dir.lastPathComponent)) { try RawExport.export(item, cameraPreview: false) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(allNames(dir) == ["DSC_0003.x3f"])
        #expect(try T5.snapshot(dir) == before)

        // 解码失败：文件里连一张 JPEG 都没有。临时文件也不留下
        let broken = try folder(fakeRaw: ["broken.arw": junk(30_000)])
        let brokenItem = try MetaFixtures.item(broken.appendingPathComponent("broken.arw"))
        do {
            _ = try RawExport.export(brokenItem, cameraPreview: false)
            Issue.record("应该失败")
        } catch let error as EditSaveError {
            #expect(!error.message.isEmpty)
        }
        #expect(allNames(broken) == ["broken.arw"])

        // RAW 已经不在原处
        try FileManager.default.removeItem(at: raw)
        #expect(throws: EditSaveError.vanished) { try RawExport.export(item, cameraPreview: false) }
        #expect(allNames(dir).isEmpty)
    }

    @Test("系统能完整解码的 RAW：全尺寸、按文件方向转正、方向标记 1，带拍摄时间和相机，去掉厂商私有数据；RAW 逐字节不变、修改时间不变（spec C6-04，本机有样张时）")
    func fullDecode() throws {
        guard let name = fullRawSample else { return }
        let dir = try folder(raws: [name])
        let raw = dir.appendingPathComponent(name)
        let sha = try MetaFixtures.sha(raw)
        let mtime = MetaFixtures.mtime(raw)
        let size = try #require(EditWriter.orientedSize(raw))
        let written = try RawExport.export(try MetaFixtures.item(raw), cameraPreview: false)
        #expect(!written.cameraPreview)
        #expect(written.url.pathExtension == "jpg" && written.url.deletingLastPathComponent() == raw.deletingLastPathComponent())
        #expect(EditWriter.orientedSize(written.url) == size)
        let p = props(written.url)
        #expect(p[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] != nil)
        let rawTiff = props(raw)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == rawTiff?[kCGImagePropertyTIFFMake] as? String)
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == rawTiff?[kCGImagePropertyTIFFModel] as? String)
        if props(raw)[kCGImagePropertyGPSDictionary] != nil { #expect(p[kCGImagePropertyGPSDictionary] != nil) }
        #expect(!p.keys.contains { ($0 as String).hasPrefix("{Maker") })
        #expect(image(written.url)?.colorSpace != nil)
        #expect(try MetaFixtures.sha(raw) == sha)
        let after = MetaFixtures.mtime(raw)
        #expect(after.tv_sec == mtime.tv_sec && after.tv_nsec == mtime.tv_nsec)
        #expect(allNames(dir) == [name, written.url.lastPathComponent])
    }

    @Test("固定 JPEG、质量 0.92（spec C6-04）")
    func format() {
        #expect(EditTarget.rawExport.typeIdentifier == "public.jpeg" && EditTarget.rawExport.pathExtension == "jpg")
        #expect(EditTarget.rawExport.reason == .raw && !EditTarget.rawExport.canReplaceOriginal)
        #expect(EditWriter.quality == 0.92)
    }
}

// MARK: - 模型流程

@Suite("RAW 导出为 JPEG：模型流程")
@MainActor
struct RawExportModelTests {
    /// 假 RAW 进入相机预览图状态
    private func previewModel(_ dir: URL, initial: Int = 0, settings: AppSettings? = nil) async throws -> BrowserModel {
        let m = try T5.model(dir, initial: initial, settings: settings)
        #expect(await T5.waitFor { m.showingCameraPreview })
        await T5.waitFor { m.ratingsLoaded }
        return m
    }

    @Test("系统能完整解码的 RAW 也不能编辑：按钮按「不支持」置灰、提示先导出，E 没反应，菜单的「编辑」置灰；旋转只改显示、不出「保存旋转」（spec C6-01、C6-02，本机有样张时）")
    func fullRawNotEditable() async throws {
        guard let name = fullRawSample else { return }
        let dir = try folder(raws: [name])
        let before = try T5.snapshot(dir)
        let m = try T5.model(dir)
        #expect(await T5.waitFor { m.displayed != nil && m.displayedItem == m.current && !m.isDecodingRaw })
        #expect(!m.showingCameraPreview)
        #expect(m.editUnsupported && m.editBlockedByRaw && !m.canEditCurrent)
        #expect(m.handleKey(try T5.key(14, "e")))
        m.enterEdit()
        #expect(m.edit == nil)
        #expect(m.fileMenu(.single).first { $0.action == .edit }?.enabled == false)
        _ = m.handleKey(try T5.key(15, "r"))
        #expect(m.rotation == 1)
        #expect(!m.showsSaveRotation)
        _ = m.handleKey(try T5.key(15, "r", .shift))
        _ = m.handleKey(try T5.key(15, "r", .shift))
        #expect(m.rotation == 3 && !m.showsSaveRotation)
        #expect(try T5.snapshot(dir) == before)
    }

    @Test("相机预览图状态：编辑置灰，提示仍用相机预览图那句；不出「保存旋转」（spec C6-01、C6-02）")
    func previewRawNotEditable() async throws {
        let m = try await previewModel(try folder(fakeRaw: ["DSC_0010.x3f": fakeRaw()]))
        #expect(m.editUnsupported && !m.canEditCurrent)
        // 界面先看相机预览图（TX-09），再看 RAW（TX-E0）
        #expect(m.showingCameraPreview && m.editBlockedByRaw)
        _ = m.handleKey(try T5.key(14, "e"))
        #expect(m.edit == nil)
        m.rotate(1)
        #expect(m.rotation == 1 && !m.showsSaveRotation)
    }

    @Test("菜单：单张右键菜单紧跟「编辑」、图标视图单选在「显示信息」之前、「⋯」在「移到废纸篓」之前；只在 RAW 上有（spec C6-03）")
    func menus() async throws {
        let dir = try folder(fakeRaw: ["DSC_0011.x3f": fakeRaw()], samples: ["aurora.jpg"])
        let m = try T5.model(dir)
        m.select(m.items.firstIndex { $0.name == "DSC_0011.x3f" })
        #expect(m.current?.name == "DSC_0011.x3f")
        await T5.waitFor { m.showingCameraPreview }
        let single = m.fileMenu(.single).compactMap(\.action)
        #expect(single == [.reveal, .copy, .copyPath, .rotateLeft, .rotateRight, .edit, .exportJPEG, .toggleInfo, .copyTo, .moveTo, .trash])
        let row = try #require(m.fileMenu(.single).first { $0.action == .exportJPEG })
        #expect(row.title == String(localized: "导出为 JPEG") && row.enabled)
        #expect(row.shortcut == MenuShortcut(key: "e", command: true, shift: true))
        let more = m.fileMenu(.more)
        #expect(more.compactMap(\.action) == [.reveal, .copy, .copyPath, .exportJPEG, .trash, .open])
        #expect(more.allSatisfy { $0.shortcut == nil })
        // 系统菜单（右键菜单）也照清单来
        let menu = ContextMenuPresenter.make(m.fileMenu(.single)) { _ in }
        #expect(menu.items.contains { $0.title == String(localized: "导出为 JPEG") && $0.isEnabled })
        // 不是 RAW：右键菜单和「⋯」菜单都没有这一项，也不能导出
        m.select(m.items.firstIndex { $0.name == "aurora.jpg" })
        #expect(m.current?.name == "aurora.jpg")
        #expect(!m.fileMenu(.single).contains { $0.action == .exportJPEG })
        #expect(!m.fileMenu(.more).contains { $0.action == .exportJPEG })
        #expect(!m.canExportCurrent)
        // 图标视图单选
        m.setViewMode(.grid)
        // 用列表里的位置（临时目录在列表里是解析过符号链接的 /private/var/…）
        m.gridClick(try #require(m.items.first { $0.name == "DSC_0011.x3f" }).url, command: false, shift: false)
        #expect(m.current?.name == "DSC_0011.x3f")
        #expect(m.fileMenu(.gridItem).compactMap(\.action) == [.reveal, .copy, .copyPath, .exportJPEG, .toggleInfo, .copyTo, .moveTo, .trash])
        #expect(m.canExportCurrent)
    }

    @Test("置灰：出错卡片、正在导出时不能导出（spec C6-03）")
    func disabled() async throws {
        let dir = try folder(fakeRaw: ["broken.arw": junk(30_000)])
        let m = try T5.model(dir)
        #expect(await T5.waitFor { m.failure != nil })
        #expect(m.showsExportItem && !m.canExportCurrent)
        #expect(m.fileMenu(.single).first { $0.action == .exportJPEG }?.enabled == false)
        m.exportCurrentAsJPEG()
        #expect(m.exportingURL == nil && allNames(dir) == ["broken.arw"])
    }

    @Test("导出相机预览图：后台进行、期间提示「正在导出」、再按没有反应；成功后跳到新 JPEG，它能编辑，提示带撤销；星级带过去；⌘Z 撤销回到 RAW（spec C6-05、C6-07 ~ C6-10）")
    func exportAndUndo() async throws {
        let dir = try folder(fakeRaw: ["DSC_0020.x3f": fakeRaw()], samples: ["aurora.jpg", "IMG_2034.jpg"])
        // 列表：DSC_0020.x3f、aurora.jpg、IMG_2034.jpg（自然排序，大写在前）
        let m = try T5.model(dir)
        let raw = try #require(m.items.first { $0.name == "DSC_0020.x3f" })
        let start = try #require(m.items.firstIndex(of: raw))
        m.select(start)
        #expect(await T5.waitFor { m.showingCameraPreview })
        await T5.waitFor { m.ratingsLoaded }
        m.rateCurrent(3, fromKeyboard: true)
        await m.ratingWriter.waitUntilIdle()
        await T5.waitFor { m.pendingRatingWrites == 0 }
        let rawSidecar = dir.appendingPathComponent("DSC_0020.xmp")
        #expect(FileManager.default.fileExists(atPath: rawSidecar.path))
        let before = try T5.snapshot(dir)
        m.rotate(1)   // 浏览时转的角度不带进导出

        m.exportCurrentAsJPEG()
        #expect(m.exportingURL == raw.url)
        #expect(m.toast?.text == String(localized: "正在导出为 JPEG…"))
        #expect(!m.canExportCurrent)
        m.exportCurrentAsJPEG()   // 再按一次：没有反应
        #expect(await T5.waitFor { m.exportingURL == nil })

        let jpegName = exportName("DSC_0020")
        let jpeg = dir.appendingPathComponent(jpegName)
        #expect(allNames(dir).filter { $0.hasSuffix(".jpg") && $0.contains("DSC_0020") } == [jpegName])
        #expect(EditWriter.orientedSize(jpeg) == PixelSize(width: 1200, height: 800))
        // 跳到新文件，它在按文件名排序的位置
        #expect(m.current?.name == jpegName)
        let exported = try #require(m.current?.url)
        #expect(m.items.map(\.name) == FolderScanner.naturalSorted(m.items).map(\.name))
        #expect(m.items.contains { $0.name == "DSC_0020.x3f" })
        #expect(m.toast?.text == String(localized: "已把相机预览图导出为「\(jpegName)」"))
        #expect(m.toast?.action == .undoEdit && m.toast?.bottom == true)
        // 星级：默认写新文件旁的 .xmp
        let jpegSidecar = dir.appendingPathComponent(ExportNaming.baseName("DSC_0020", attempt: 1) + ".xmp")
        #expect(try XMPPacket(data: Data(contentsOf: jpegSidecar)).rating == 3)
        #expect(m.ratings[exported] == 3)
        // RAW 和它的 .xmp 都没动
        var after = try T5.snapshot(dir)
        after[jpegName] = nil
        after[jpegSidecar.lastPathComponent] = nil
        #expect(after == before)
        // 导出的 JPEG 可以编辑
        #expect(await T5.waitFor { m.canEditCurrent })

        // 撤销：和评星共用记录，菜单栏写「撤销“导出为 JPEG”」
        #expect(m.undoMenuTitle == String(localized: "撤销“导出为 JPEG”"))
        await m.undoLast()
        #expect(!FileManager.default.fileExists(atPath: jpeg.path))
        #expect(!FileManager.default.fileExists(atPath: jpegSidecar.path))
        #expect(m.current?.url == raw.url)
        #expect(!m.allItems.contains { $0.url == exported })
        // 下一条是评星
        #expect(m.undoMenuTitle == String(localized: "撤销“评星”"))
    }

    @Test("导出期间翻到别的文件：照常翻，成功后不跳（spec C6-08、C6-09）")
    func noJumpWhenMovedOn() async throws {
        let dir = try folder(fakeRaw: ["DSC_0030.x3f": fakeRaw()], samples: ["aurora.jpg"])
        let m = try T5.model(dir)
        m.select(m.items.firstIndex { $0.name == "DSC_0030.x3f" })
        #expect(await T5.waitFor { m.showingCameraPreview })
        m.exportCurrentAsJPEG()
        #expect(m.exportingURL != nil)
        m.select(m.items.firstIndex { $0.name == "aurora.jpg" })
        #expect(m.current?.name == "aurora.jpg")
        #expect(await T5.waitFor { m.exportingURL == nil })
        #expect(m.current?.name == "aurora.jpg")
        #expect(m.allItems.contains { $0.name == exportName("DSC_0030") })
        #expect(m.toast?.action == .undoEdit)
    }

    @Test("筛选把 JPEG 挡在外面：不跳，只提示（spec C6-09）")
    func noJumpWhenFiltered() async throws {
        let dir = try folder(fakeRaw: ["DSC_0040.x3f": fakeRaw(), "DSC_0041.x3f": fakeRaw()])
        let m = try await previewModel(dir)
        var f = BrowseFilter()
        f.format.selected = [.raw]
        m.setBrowseFilter(f)
        #expect(m.current?.name == "DSC_0040.x3f")
        m.exportCurrentAsJPEG()
        #expect(await T5.waitFor { m.exportingURL == nil })
        #expect(m.current?.name == "DSC_0040.x3f")
        #expect(m.allItems.contains { $0.name == exportName("DSC_0040") })
        #expect(!m.items.contains { $0.name == exportName("DSC_0040") })
        #expect(m.toast?.text == String(localized: "已把相机预览图导出为「\(exportName("DSC_0040"))」"))
    }

    @Test("失败：文件夹不可写时提示「无法导出：原因」，不产生任何文件（spec C6-11）")
    func failureToast() async throws {
        let dir = try folder(fakeRaw: ["DSC_0050.x3f": fakeRaw()])
        let m = try await previewModel(dir)
        let before = try T5.snapshot(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        m.exportCurrentAsJPEG()
        #expect(await T5.waitFor { m.exportingURL == nil })
        let reason = EditSaveError.notWritable(folder: dir.lastPathComponent).message
        #expect(m.toast?.text == String(localized: "无法导出：\(reason)"))
        #expect(m.toast?.tone == .warning)
        #expect(allNames(dir) == ["DSC_0050.x3f"])
        #expect(try T5.snapshot(dir) == before)
        #expect(m.undoHistory.entries.isEmpty)
        #expect(m.current?.name == "DSC_0050.x3f")
    }

    @Test("简洁模式：右键菜单、「⋯」菜单都没有这一项，⇧⌘E 没有反应；多选时也没有；图标视图里单选一张 RAW 时可以（spec C6-12）")
    func simpleModeAndSelection() async throws {
        let dir = try folder(fakeRaw: ["DSC_0060.x3f": fakeRaw(), "DSC_0061.x3f": fakeRaw()])
        let m = try await previewModel(dir)
        m.setSimpleMode(true)
        for context in [FileMenuContext.single, .more, .gridItem] {
            #expect(!m.fileMenu(context).contains { $0.action == .exportJPEG })
        }
        #expect(!m.canExportCurrent && !m.exportEnabled)
        // ⇧⌘E 由菜单栏的「导出为 JPEG」接（按键分流不吃掉它）；简洁模式里菜单栏没有这一项
        #expect(!m.handleKey(try shiftCmdE()))
        m.exportCurrentAsJPEG()
        #expect(m.exportingURL == nil)
        #expect(allNames(dir) == ["DSC_0060.x3f", "DSC_0061.x3f"])
        m.setSimpleMode(false)

        // 图标视图：多选没有这一项，也不能导出
        m.setViewMode(.grid)
        m.selectAllInGrid()
        #expect(m.isMultiSelection)
        #expect(!m.fileMenu(.gridItem).contains { $0.action == .exportJPEG })
        #expect(!m.fileMenu(.more).contains { $0.action == .exportJPEG })
        #expect(!m.canExportCurrent)
        m.perform(.exportJPEG)
        #expect(m.exportingURL == nil)
        // 只选中一张：可以，⇧⌘E 同样交给菜单栏
        m.gridClick(try #require(m.items.first { $0.name == "DSC_0061.x3f" }).url, command: false, shift: false)
        #expect(!m.isMultiSelection && m.canExportCurrent)
        #expect(!m.handleKey(try shiftCmdE()))
        m.perform(.exportJPEG)
        #expect(await T5.waitFor { m.exportingURL == nil && m.toast?.action == .undoEdit })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(exportName("DSC_0061")).path))
        // 还停在这张上：图标视图里选中新文件
        #expect(m.current?.name == exportName("DSC_0061"))
    }

    @Test("系统能完整解码的 RAW：导出后提示「已导出为」，跳到新 JPEG（spec C6-09，本机有样张时）")
    func fullRawExport() async throws {
        guard let name = fullRawSample else { return }
        let dir = try folder(raws: [name])
        let m = try T5.model(dir)
        #expect(await T5.waitFor { m.displayed != nil && m.displayedItem == m.current && !m.isDecodingRaw })
        let raw = dir.appendingPathComponent(name)
        let sha = try MetaFixtures.sha(raw)
        m.exportCurrentAsJPEG()
        for _ in 0..<5 where m.exportingURL != nil { await T5.waitFor { m.exportingURL == nil } }
        let jpegName = exportName(raw.deletingPathExtension().lastPathComponent)
        #expect(m.toast?.text == String(localized: "已导出为「\(jpegName)」"))
        #expect(m.current?.name == jpegName)
        #expect(try MetaFixtures.sha(raw) == sha)
    }
}

// MARK: - 快捷键页、旧设置

@Suite("RAW 导出为 JPEG：快捷键页和旧设置")
struct RawExportMiscTests {
    @Test("快捷键页：「编辑」那一行下面加一行「把 RAW 导出为 JPEG ⇧⌘E」；简洁模式里不列（spec C6-13）")
    @MainActor
    func shortcuts() throws {
        let all = ShortcutsPane.sections(rating: true, filter: true, edit: true)
        let section = try #require(all.first { $0.rows.contains { $0.id == "编辑" } })
        let ids = section.rows.map(\.id)
        let i = try #require(ids.firstIndex(of: "编辑"))
        #expect(ids[i + 1] == "把 RAW 导出为 JPEG")
        #expect(section.rows[i + 1].keys == [[.text("⇧⌘E")]])
        let off = ShortcutsPane.sections(rating: false, filter: false, edit: false)
        #expect(!off.flatMap(\.rows).contains { $0.id == "把 RAW 导出为 JPEG" })
    }

    @Test("v0.3 存过的「RAW 另存选 HEIF」设置不影响启动")
    @MainActor
    func oldSetting() {
        let (defaults, _) = T5.suite()
        defaults.set("heif", forKey: "editRawFormat")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.simpleMode)
        #expect(EditTarget.rawExport.pathExtension == "jpg")
    }
}
