import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Yilan

// MARK: - 工具

private let zh = Locale(identifier: "zh-Hans")
private let en = Locale(identifier: "en")

private func freshDefaults() -> UserDefaults {
    let name = "yilan-v02-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// 把 app/Fixtures/sample 里的几个文件复制到 /tmp 下的新文件夹
private func fixtureCopy(_ names: [String]) throws -> URL {
    let source = MetaFixtures.sample   // scripts/run-tests.sh 会指向 /tmp 里的镜像
    let dest = URL(fileURLWithPath: "/tmp/yilan-v02-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    for name in names {
        try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: dest.appendingPathComponent(name))
    }
    return dest
}

private func item(_ url: URL) throws -> MediaItem {
    try #require(FolderScanner.item(at: url))
}

private func fakeItem(_ name: String, folder: String = "/tmp/yilan-fake", id: UInt64? = nil,
                      modified: TimeInterval = 1_000) -> MediaItem {
    let url = URL(fileURLWithPath: "\(folder)/\(name)")
    return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!,
                     fileSize: 100, modificationDate: Date(timeIntervalSince1970: modified), fileID: id)
}

/// 写一张带相机 EXIF 和 GPS 的 JPEG（数值固定，用来检查每一项的写法；真实照片见 realCameraJPEG）
private func writeExifJPEG(to url: URL) throws {
    let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(ctx.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    let props: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 16 Pro",
        ] as [CFString: Any],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:14 11:20:36",
            kCGImagePropertyExifFNumber: 1.78,
            kCGImagePropertyExifExposureTime: 0.0008,
            kCGImagePropertyExifISOSpeedRatings: [50],
            kCGImagePropertyExifFocalLength: 6.765,
            kCGImagePropertyExifFocalLenIn35mmFilm: 24,
            kCGImagePropertyExifExposureBiasValue: -0.7,
            kCGImagePropertyExifFlash: 16,
            kCGImagePropertyExifWhiteBalance: 0,
            kCGImagePropertyExifLensModel: "iPhone 16 Pro back triple camera 6.765mm f/1.78",
        ] as [CFString: Any],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 35.011444,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 135.772722,
            kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 48,
            kCGImagePropertyGPSAltitudeRef: 0,
        ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

// MARK: - 信息面板：读取

@Suite("信息面板：读取样例文件")
struct MetadataFixtureTests {
    @Test("JPEG（没有相机数据）：尺寸、色彩描述文件，没有拍摄和位置")
    func jpegWithoutExif() async throws {
        let folder = try fixtureCopy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = await MetadataReader.read(try item(folder.appendingPathComponent("IMG_2034.jpg")))
        #expect(meta.isComplete)
        #expect((meta.pixelWidth ?? 0) > 0 && (meta.pixelHeight ?? 0) > 0)
        #expect(meta.colorProfile != nil)
        #expect(meta.capture == nil)
        #expect(meta.location == nil)
        let content = InfoContent.make(meta, locale: zh)
        #expect(!content.hasCapture)
        #expect(content.location == nil)
        #expect(content.subtitle == "图片 · JPEG")
        #expect(content.file.contains { $0.label == "像素尺寸" && $0.value == "\(meta.pixelWidth!) × \(meta.pixelHeight!)" })
    }

    @Test("真实相机照片（CC0 样例 IMG_2052.jpg，iPhone 11 Pro）：拍摄参数和 GPS 位置")
    func realCameraJPEG() async throws {
        let folder = try fixtureCopy(["IMG_2052.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = await MetadataReader.read(try item(folder.appendingPathComponent("IMG_2052.jpg")))
        #expect(meta.pixelWidth == 4032 && meta.pixelHeight == 3024)
        let c = try #require(meta.capture)
        #expect(c.camera == "iPhone 11 Pro")
        #expect(c.iso == 20)
        let content = InfoContent.make(meta, locale: zh)
        #expect(content.hasCapture)
        #expect(content.tiles.map(\.label) == ["光圈", "快门", "ISO", "焦距"])
        #expect(content.tiles.first?.value == "f/2.4")
        #expect(content.captureTop.first { $0.label == "拍摄时间" }?.value == "2020-08-01 09:12")
        let location = try #require(content.location)
        #expect(location.first?.value.hasSuffix(" N") == true)
        #expect(location.dropFirst().first?.value.hasSuffix(" E") == true)
        let coords = try #require(content.coordinates)
        #expect(coords.hasPrefix("46.65634"), "\(coords)")
        #expect(coords.contains(", 9.54982"), "\(coords)")
    }

    @Test("HEIC：读出尺寸，副标题是 HEIF")
    func heic() async throws {
        let folder = try fixtureCopy(["IMG_2031.heic"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = await MetadataReader.read(try item(folder.appendingPathComponent("IMG_2031.heic")))
        #expect((meta.pixelWidth ?? 0) > 0)
        #expect(InfoContent.make(meta, locale: zh).subtitle.hasSuffix("HEIF"))
        #expect(InfoContent.make(meta, locale: en).subtitle.hasPrefix("Image · "))
    }

    @Test("PNG：没有拍摄信息；英文标签")
    func pngWithoutExif() async throws {
        let folder = try fixtureCopy(["harbor_night.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = await MetadataReader.read(try item(folder.appendingPathComponent("harbor_night.png")))
        #expect(meta.capture == nil)
        let content = InfoContent.make(meta, locale: en)
        #expect(!content.hasCapture)
        #expect(content.file.map(\.label).contains("Size"))
        #expect(content.file.map(\.label).contains("Dimensions"))
    }

    @Test("视频：时长、分辨率、编码、帧率、码率、音频")
    func video() async throws {
        let folder = try fixtureCopy(["river.mp4"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = await MetadataReader.read(try item(folder.appendingPathComponent("river.mp4")))
        let v = try #require(meta.video)
        #expect((v.duration ?? 0) > 0)
        #expect(v.codec != nil)
        #expect((v.frameRate ?? 0) > 0)
        #expect((v.bitrate ?? 0) > 0)
        #expect((meta.pixelWidth ?? 0) > 0)
        let zhContent = InfoContent.make(meta, locale: zh)
        let rows = try #require(zhContent.video)
        #expect(rows.map(\.label).starts(with: ["时长", "分辨率", "编码", "帧率", "码率"]))
        #expect(zhContent.file.contains { $0.label == "格式" && $0.value == "MPEG-4 影片" })
        #expect(zhContent.subtitle.hasPrefix("视频 · "))
        let enContent = InfoContent.make(meta, locale: en)
        #expect(enContent.video?.first?.label == "Duration")
        #expect(enContent.file.contains { $0.value == "MPEG-4 Movie" })
    }

    @Test("带 EXIF 和 GPS 的 JPEG：拍摄参数方块、位置、拷贝文字")
    func jpegWithExif() async throws {
        let folder = URL(fileURLWithPath: "/tmp/yilan-v02-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("IMG_9001.jpg")
        try writeExifJPEG(to: url)
        let meta = await MetadataReader.read(try item(url))
        let c = try #require(meta.capture)
        #expect(c.camera == "iPhone 16 Pro")
        #expect(c.iso == 50)
        #expect(c.focalLength == 24)   // 用 35mm 等效焦距
        #expect(c.flashFired == false)
        let content = InfoContent.make(meta, locale: zh)
        #expect(content.tiles.map(\.value) == ["f/1.78", "1/1250", "50", "24mm"])
        #expect(content.tiles.map(\.label) == ["光圈", "快门", "ISO", "焦距"])
        #expect(content.captureTop.first { $0.label == "拍摄时间" }?.value == "2026-10-14 11:20")
        #expect(content.captureBottom.first { $0.label == "曝光补偿" }?.value == "−0.7 EV")
        #expect(content.captureBottom.first { $0.label == "闪光灯" }?.value == "未闪光")
        let location = try #require(content.location)
        #expect(location.map(\.value) == ["35°00′41.2″ N", "135°46′21.8″ E", "48 m"])
        #expect(content.coordinates == "35.011444, 135.772722")

        let zhCopy = content.copyText(locale: zh)
        #expect(zhCopy.hasPrefix("IMG_9001.jpg\n"))
        #expect(zhCopy.contains("光圈：f/1.78"))
        #expect(zhCopy.contains("\n位置\n纬度：35°00′41.2″ N"))
        let enCopy = InfoContent.make(meta, locale: en).copyText(locale: en)
        #expect(enCopy.contains("Aperture: f/1.78"))
        #expect(enCopy.contains("Flash: Off"))
    }
}

// MARK: - 信息面板：数值写法

@Suite("信息面板：数值写法")
struct InfoFormatTests {
    @Test("快门、光圈、焦距")
    func exposure() {
        #expect(InfoFormat.shutter(1.0 / 1250) == "1/1250")
        #expect(InfoFormat.shutter(0.0008) == "1/1250")
        #expect(InfoFormat.shutter(1.0 / 3) == "1/3")
        #expect(InfoFormat.shutter(0.4) == "0.4s")
        #expect(InfoFormat.shutter(2) == "2s")
        #expect(InfoFormat.aperture(1.78) == "f/1.78")
        #expect(InfoFormat.aperture(4) == "f/4")
        #expect(InfoFormat.aperture(2.8) == "f/2.8")
        #expect(InfoFormat.focalLength(24) == "24mm")
        #expect(InfoFormat.focalLength(4.2) == "4.2mm")
    }

    @Test("曝光补偿带正负号")
    func bias() {
        #expect(InfoFormat.exposureBias(0.33) == "+0.3 EV")
        #expect(InfoFormat.exposureBias(-0.7) == "−0.7 EV")
        #expect(InfoFormat.exposureBias(0) == "0 EV")
        #expect(InfoFormat.exposureBias(-0.01) == "0 EV")
        #expect(InfoFormat.exposureBias(1) == "+1 EV")
    }

    @Test("GPS 度分秒")
    func dms() {
        #expect(InfoFormat.dms(35.011444, isLatitude: true) == "35°00′41.2″ N")
        #expect(InfoFormat.dms(-33.8568, isLatitude: true) == "33°51′24.5″ S")
        #expect(InfoFormat.dms(-84.6817, isLatitude: false) == "84°40′54.1″ W")
        // 59.99″ 进位成整分，不出现 60.0″
        #expect(InfoFormat.dms(10 + 59.0 / 60 + 59.99 / 3600, isLatitude: true) == "11°00′00.0″ N")
        #expect(InfoFormat.coordinates(latitude: 35.011444, longitude: -84.6817) == "35.011444, -84.681700")
    }

    @Test("码率、帧率、采样率、海拔：中英文一样")
    func units() {
        for locale in [zh, en] {
            #expect(InfoFormat.bitrate(40_400_000, locale: locale) == "40.4 Mbps")
            #expect(InfoFormat.bitrate(850_000, locale: locale) == "850 kbps")
            #expect(InfoFormat.frameRate(60, locale: locale) == "60.00 fps")
            #expect(InfoFormat.frameRate(29.97, locale: locale) == "29.97 fps")
            #expect(InfoFormat.sampleRate(48_000, locale: locale) == "48 kHz")
            #expect(InfoFormat.sampleRate(44_100, locale: locale) == "44.1 kHz")
            #expect(InfoFormat.altitude(48, locale: locale) == "48 m")
            #expect(InfoFormat.altitude(-12.4, locale: locale) == "−12 m")
        }
    }

    @Test("编码名、EXIF 时间")
    func names() {
        #expect(InfoFormat.codecName("hvc1") == "HEVC（H.265）")
        #expect(InfoFormat.codecName("avc1") == "H.264")
        #expect(InfoFormat.exifDate("2026:10:14 11:20:36") == "2026-10-14 11:20")
        #expect(InfoFormat.exifDate("2026:10:14") == nil)
        #expect(InfoFormat.exifDate("garbage") == nil)
        #expect(InfoFormat.cameraName(make: "Apple", model: "iPhone 16 Pro") == "iPhone 16 Pro")
    }
}

// MARK: - 删除到废纸篓

@Suite("删除：之后显示哪一个")
struct DeleteSelectionTests {
    @Test("删中间的：显示下一个（新列表同一位置）")
    func middle() { #expect(DeleteSelection.index(afterRemoving: 2, newCount: 4) == 2) }

    @Test("删最后一个：显示上一个")
    func last() { #expect(DeleteSelection.index(afterRemoving: 4, newCount: 4) == 3) }

    @Test("删第一个：显示新的第一个")
    func first() { #expect(DeleteSelection.index(afterRemoving: 0, newCount: 4) == 0) }

    @Test("删掉唯一的一个：没有可显示的")
    func only() { #expect(DeleteSelection.index(afterRemoving: 0, newCount: 0) == nil) }

    @Test("撤销记录：后删的先撤销")
    func undoStack() {
        var stack = UndoHistory()
        #expect(!stack.canUndo)
        let a = TrashEntry(item: fakeItem("a.jpg"), trashedURL: URL(fileURLWithPath: "/tmp/t/a.jpg"))
        let b = TrashEntry(item: fakeItem("b.jpg"), trashedURL: URL(fileURLWithPath: "/tmp/t/b.jpg"))
        stack.push(.trash(a))
        stack.push(.trash(b))
        #expect(stack.pop() == .trash(b))
        #expect(stack.pop() == .trash(a))
        #expect(stack.pop() == nil)
    }
}

@Suite("删除：移到废纸篓再撤销（临时文件夹）", .serialized)
@MainActor
struct TrashRoundTripTests {
    @Test("移到废纸篓后原位置没有了；放回去后内容不变")
    func roundTrip() throws {
        let folder = try fixtureCopy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("IMG_2034.jpg")
        let original = try Data(contentsOf: url)
        let trashed = try TrashService.trash(url)
        // 测试里只能进假废纸篓（/tmp 下），不能进用户的 ~/.Trash
        let fake = try #require(TrashService.fakeTrashDirectory)
        #expect(trashed.path.hasPrefix(fake.path))
        #expect(!trashed.path.contains("/.Trash/"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        try TrashService.restore(TrashEntry(item: try fakeAt(url), trashedURL: trashed))
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
    }

    @Test("原位置又有了同名文件：撤销失败，不覆盖")
    func originalExists() throws {
        let folder = try fixtureCopy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("IMG_2034.jpg")
        let entry = TrashEntry(item: try fakeAt(url), trashedURL: try TrashService.trash(url))
        defer { try? FileManager.default.removeItem(at: entry.trashedURL) }
        try Data("new".utf8).write(to: url)
        #expect(throws: TrashService.Failure.self) { try TrashService.restore(entry) }
        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test("在一览里删除：显示下一个、数量更新、提示可撤销；连续撤销两次都放回来")
    func modelDeleteAndUndo() async throws {
        let names = ["IMG_2034.jpg", "IMG_2052.jpg", "aurora.jpg", "harbor_night.png"]
        let folder = try fixtureCopy(names)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(settings: AppSettings(defaults: freshDefaults()),
                                 recents: RecentFolders(defaults: freshDefaults()))
        let scanned = try FolderScanner.scan(folder: folder)
        model.apply(FolderScanner.Result(folder: folder, items: scanned, initialIndex: 1))
        let second = try #require(model.current)
        let third = scanned[2]

        await model.performDelete(second)
        #expect(!FileManager.default.fileExists(atPath: second.url.path))
        #expect(model.current == third)                  // 下一个
        #expect(model.items.count == 3)
        #expect(model.counts[.all] == 3)
        #expect(model.toast?.action == .undoDelete)
        #expect(model.canUndoDelete)

        await model.performDelete(third)
        #expect(model.current == scanned[3])
        #expect(model.items.count == 2)

        await model.undoDelete()
        #expect(FileManager.default.fileExists(atPath: third.url.path))
        #expect(model.current?.url == third.url)
        await model.undoDelete()
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        #expect(model.current?.url == second.url)
        #expect(model.items.map(\.name) == scanned.map(\.name))
        #expect(!model.canUndoDelete)
    }

    @Test("删掉最后一个显示上一个；删光后没有当前项")
    func modelDeleteLastAndOnly() async throws {
        let folder = try fixtureCopy(["IMG_2034.jpg", "IMG_2052.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(settings: AppSettings(defaults: freshDefaults()),
                                 recents: RecentFolders(defaults: freshDefaults()))
        let scanned = try FolderScanner.scan(folder: folder)
        model.apply(FolderScanner.Result(folder: folder, items: scanned, initialIndex: 1))
        await model.performDelete(scanned[1])
        #expect(model.current == scanned[0])
        await model.performDelete(scanned[0])
        #expect(model.current == nil)
        #expect(model.allItems.isEmpty)
        // 收尾：放回去，不在废纸篓里留测试文件
        await model.undoDelete()
        await model.undoDelete()
        #expect(model.allItems.count == 2)
    }

    private func fakeAt(_ url: URL) throws -> MediaItem {
        MediaItem(url: url, format: try #require(SupportedFormats.format(forExtension: url.pathExtension)),
                  fileSize: 1, modificationDate: Date())
    }
}

// MARK: - 文件夹变化同步

@Suite("文件夹同步：比较两次扫描")
struct FolderDiffTests {
    @Test("新增、删除、修改")
    func addedRemovedModified() {
        let a = fakeItem("a.jpg", id: 1), b = fakeItem("b.jpg", id: 2), c = fakeItem("c.jpg", id: 3)
        let d = fakeItem("d.jpg", id: 4)
        let c2 = fakeItem("c.jpg", id: 3, modified: 2_000)
        let diff = FolderDiff(old: [a, b, c], new: [a, c2, d])
        #expect(diff.added == [d])
        #expect(diff.removed == [b])
        #expect(diff.modified == [c2])
        #expect(diff.renamed.isEmpty)
        #expect(diff.changedURLs == Set([b.url, c.url, d.url]))
        #expect(FolderDiff(old: [a, b], new: [a, b]).isEmpty)
    }

    @Test("改名：同一个文件编号，算改名，不算一删一增")
    func renamed() {
        let a = fakeItem("a.jpg", id: 1), b = fakeItem("b.jpg", id: 2)
        let b2 = fakeItem("beach.jpg", id: 2)
        let diff = FolderDiff(old: [a, b], new: [a, b2])
        #expect(diff.renamed == [b: b2])
        #expect(diff.added.isEmpty && diff.removed.isEmpty)
    }

    @Test("当前文件不见了：显示后面第一个还在的；后面都没了显示前面的")
    func replacement() {
        let items = (0..<5).map { fakeItem("\($0).jpg") }
        let r1 = SyncSelection.replacement(for: items[1], oldList: items, newList: [items[0], items[3], items[4]])
        #expect(r1?.item == items[3] && r1?.isNext == true)
        let r2 = SyncSelection.replacement(for: items[4], oldList: items, newList: [items[0], items[1]])
        #expect(r2?.item == items[1] && r2?.isNext == false)
        #expect(SyncSelection.replacement(for: items[0], oldList: items, newList: []) == nil)
    }
}

@Suite("文件夹同步：更新列表")
@MainActor
struct ApplySyncTests {
    private func makeModel(_ items: [MediaItem], current: Int) -> BrowserModel {
        let model = BrowserModel(settings: AppSettings(defaults: freshDefaults()),
                                 recents: RecentFolders(defaults: freshDefaults()))
        model.apply(FolderScanner.Result(folder: URL(fileURLWithPath: "/tmp/yilan-fake"), items: items, initialIndex: current))
        return model
    }

    @Test("新增文件：插到排好序的位置，当前项不变，提示新增数量，缩略图高亮")
    func added() {
        let a = fakeItem("a.jpg", id: 1), c = fakeItem("c.jpg", id: 3)
        let b = fakeItem("b.jpg", id: 2), d = fakeItem("d.jpg", id: 4)
        let model = makeModel([a, c], current: 1)
        model.applySync([a, b, c, d])
        #expect(model.items == [a, b, c, d])
        #expect(model.current == c)
        #expect(model.currentIndex == 2)
        #expect(model.toast?.text == String(localized: "新增 \(2) 个文件"))
        #expect(model.freshURLs == [b.url, d.url])
    }

    @Test("当前文件被删：显示下一个并提示")
    func currentRemoved() {
        let items = (0..<4).map { fakeItem("\($0).jpg", id: UInt64($0 + 1)) }
        let model = makeModel(items, current: 1)
        model.applySync([items[0], items[2], items[3]])
        #expect(model.current == items[2])
        #expect(model.toast?.text == String(localized: "当前文件已被删除或移走"))
        #expect(model.toast?.detail == String(localized: "已显示下一个"))
        #expect(model.counts[.all] == 3)
    }

    @Test("其他文件被删：当前项不变，不提示")
    func otherRemoved() {
        let items = (0..<4).map { fakeItem("\($0).jpg", id: UInt64($0 + 1)) }
        let model = makeModel(items, current: 2)
        model.applySync([items[1], items[2], items[3]])
        #expect(model.current == items[2])
        #expect(model.currentIndex == 1)
        #expect(model.toast == nil)
    }

    @Test("当前文件被改名：继续显示它，不提示")
    func currentRenamed() {
        let items = (0..<3).map { fakeItem("\($0).jpg", id: UInt64($0 + 1)) }
        let model = makeModel(items, current: 1)
        let renamed = fakeItem("z.jpg", id: 2)
        model.applySync([items[0], items[2], renamed])
        #expect(model.current == renamed)
        #expect(model.toast == nil)
    }
}

// MARK: - 信息面板：浮在图片上

@Suite("信息面板：任何宽度都浮在图片上，只移动右箭头")
@MainActor
struct FloatingPanelLayoutTests {
    private let widths: [CGFloat] = [640, 760, 899, 900, 1280, 1920]

    @Test("开关面板：图片区边距、左箭头都不变（窄窗口和宽窗口一样）")
    func contentDoesNotMove() {
        for fullScreen in [false, true] {
            for w in widths {
                let size = CGSize(width: w, height: 800)
                let closed = StageLayout(size: size, fullScreen: fullScreen, panelOpen: false)
                let open = StageLayout(size: size, fullScreen: fullScreen, panelOpen: true)
                #expect(open.imageSideInset == closed.imageSideInset)
                #expect(open.leftArrowX == closed.leftArrowX)
            }
        }
        #expect(StageLayout(size: CGSize(width: 1280, height: 800), fullScreen: false, panelOpen: true).imageSideInset
            == Theme.imageInsetSide)
    }

    @Test("右箭头：面板打开时不移动，留在窗口边（被面板盖住）")
    func rightArrowStaysUnderPanel() {
        let half = StageLayout.arrowSize / 2
        for fullScreen in [false, true] {
            for w in widths {
                let size = CGSize(width: w, height: 800)
                let open = StageLayout(size: size, fullScreen: fullScreen, panelOpen: true)
                let closed = StageLayout(size: size, fullScreen: fullScreen, panelOpen: false)
                #expect(open.panelLeft == w - InfoPanel.trailing - InfoPanel.width)
                #expect(open.rightArrowX == closed.rightArrowX)        // 开关面板箭头不动
                #expect(w - (closed.rightArrowX + half) == closed.edge)
                #expect(open.rightArrowX - half >= open.panelLeft)      // 在面板下面
            }
        }
        #expect(StageLayout(size: CGSize(width: 1280, height: 800), fullScreen: false, panelOpen: false).edge == 20)
        #expect(StageLayout(size: CGSize(width: 1280, height: 800), fullScreen: true, panelOpen: false).edge == 24)
    }

    @Test("面板高度：不盖住缩略图栏和视频控制条；底部控件没显示时到距底 16")
    func panelStopsAboveBottomChrome() {
        // 照片 + 缩略图栏：缩略图栏上沿 132，面板到 144
        let dock = StageLayout.bottomChromeTop(isVideo: false, stripVisible: true, shown: true)
        #expect(dock == Theme.imageInsetBottom)
        #expect(StageLayout.panelBottomMargin(chromeTop: dock) == 144)
        // 视频 + 缩略图栏：控制条上沿 128 + 46
        let vbar = StageLayout.bottomChromeTop(isVideo: true, stripVisible: true, shown: true)
        #expect(vbar == Theme.videoBarBottom + Theme.videoBarHeight)
        #expect(StageLayout.panelBottomMargin(chromeTop: vbar) == vbar + 12)
        // 视频、没有缩略图栏：控制条距底 16
        #expect(StageLayout.bottomChromeTop(isVideo: true, stripVisible: false, shown: true)
            == Theme.videoBarBottomNoStrip + Theme.videoBarHeight)
        // 缩略图栏关掉、或全屏时底部控件藏起来：到距底 16
        #expect(StageLayout.panelBottomMargin(chromeTop: StageLayout.bottomChromeTop(isVideo: false, stripVisible: false, shown: true)) == 16)
        #expect(StageLayout.panelBottomMargin(chromeTop: StageLayout.bottomChromeTop(isVideo: true, stripVisible: true, shown: false)) == 16)
    }
}

@Suite("视频缩略图")
struct VideoThumbnailTests {
    @Test("取帧时间：时长的 40%，最多 6 秒；读不到时长就取第 0 秒")
    func frameTime() {
        #expect(ThumbnailGenerator.videoFrameTime(duration: 10).seconds == 4)
        #expect(ThumbnailGenerator.videoFrameTime(duration: 600).seconds == 6)
        #expect(ThumbnailGenerator.videoFrameTime(duration: nil) == .zero)
        #expect(ThumbnailGenerator.videoFrameTime(duration: .nan) == .zero)
        #expect(ThumbnailGenerator.videoFrameTime(duration: 0) == .zero)
    }

    @Test("样例视频 river.mp4能生成有画面的缩略图，带时长；缓存键已换版本")
    func trailThumbnail() async throws {
        let folder = try fixtureCopy(["river.mp4"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let thumb = await ThumbnailGenerator.generate(try item(folder.appendingPathComponent("river.mp4")))
        let image = try #require(thumb.image)
        #expect(max(image.width, image.height) <= ThumbnailGenerator.maxPixel)
        #expect(abs(try #require(thumb.duration) - 10.64) < 0.1)
        #expect(ThumbnailCacheKey.version >= 2)
    }
}

@Suite("缩略图磁盘缓存")
struct ThumbnailDiskCacheTests {
    @Test("视频缩略图写进磁盘缓存再读回来，时长不丢（缩略图栏的时长角标靠它）")
    func durationSurvivesCache() throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(ctx.makeImage())
        let url = URL(fileURLWithPath: "/tmp/yilan-cache-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        ThumbnailGenerator.writeCache(url, image: image, duration: 10.64)
        let back = try #require(ThumbnailGenerator.readCache(url))
        #expect(abs(try #require(back.duration) - 10.64) < 0.001)
        ThumbnailGenerator.writeCache(url, image: image, duration: nil)
        #expect(ThumbnailGenerator.readCache(url)?.duration == nil)
    }
}
