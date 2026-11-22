import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Yilan

// MARK: - 工具：现场造图片和假 RAW，不用任何素材文件

/// 一张左半红、右半蓝的图（能看出有没有转对方向）
private func halves(_ width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return ctx.makeImage()!
}

private func jpegData(_ image: CGImage, orientation: Int? = nil) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// 不含 FF 的垃圾字节（不会被误认成 JPEG 开头）
private func junk(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
}

private func tempFile(_ name: String, _ data: Data) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yilan-embedded-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// 某一点的颜色（左上角为原点）
private func color(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

// MARK: - 找内嵌 JPEG（spec C1-03）

@Suite("内嵌预览图")
struct EmbeddedPreviewTests {
    @Test("文件里有大小两张 JPEG：取到大的那张")
    func picksLargest() throws {
        let small = jpegData(halves(320, 240)), big = jpegData(halves(1200, 800))
        let url = try tempFile("fake.arw", junk(4096) + small + junk(1000) + big + junk(50_000))
        let found = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil))
        #expect(found.pixelSize == CGSize(width: 1200, height: 800))
        #expect(found.image.width == 1200 && found.image.height == 800)
    }

    @Test("按 maxPixel 缩小解码，尺寸仍报内嵌 JPEG 本身的")
    func downsamples() throws {
        let url = try tempFile("fake.srw", junk(100) + jpegData(halves(1200, 800)) + junk(100))
        let found = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: 300))
        #expect(max(found.image.width, found.image.height) == 300)
        #expect(found.pixelSize == CGSize(width: 1200, height: 800))
    }

    @Test("最大的那张是坏的：退到下一张能解码的")
    func skipsBroken() throws {
        var broken = jpegData(halves(1600, 1200))
        broken = broken.prefix(broken.count / 3) + junk(200)   // 只留开头：读得到宽高，解不出画面
        let good = jpegData(halves(640, 480))
        let url = try tempFile("fake.x3f", junk(64) + good + junk(64) + broken)
        let found = EmbeddedPreview.largestJPEG(url: url, maxPixel: nil)
        // 系统对截断的 JPEG 有时能解出一部分：两种结果都接受，但不能是空的
        #expect(found != nil)
        if let found { #expect(found.pixelSize.width >= 640) }
    }

    @Test("没有 JPEG、空文件、很小的文件：返回 nil，不崩溃")
    func nothing() throws {
        #expect(EmbeddedPreview.largestJPEG(url: try tempFile("a.arw", junk(100_000)), maxPixel: nil) == nil)
        #expect(EmbeddedPreview.largestJPEG(url: try tempFile("b.arw", Data()), maxPixel: nil) == nil)
        #expect(EmbeddedPreview.largestJPEG(url: try tempFile("c.arw", Data([0xFF, 0xD8, 0xFF])), maxPixel: nil) == nil)
        #expect(EmbeddedPreview.largestJPEG(url: URL(fileURLWithPath: "/tmp/yilan-no-such-file.arw"), maxPixel: nil) == nil)
    }

    @Test("只取尺寸：和解码出来的那张一致，竖拍的已经转正；系统读不到尺寸的 RAW 在文件信息里带上它（spec C1-16）")
    func sizeOnly() async throws {
        let url = try tempFile("fake.x3f", junk(4096) + jpegData(halves(320, 240)) + junk(100) + jpegData(halves(1200, 800), orientation: 6) + junk(5000))
        #expect(EmbeddedPreview.largestSize(url: url) == CGSize(width: 800, height: 1200))
        #expect(EmbeddedPreview.largestSize(url: url) == EmbeddedPreview.largestJPEG(url: url, maxPixel: 200)?.pixelSize)
        #expect(EmbeddedPreview.largestSize(url: try tempFile("a.arw", junk(100_000))) == nil)
        // 系统不认识的假 RAW：读不到像素尺寸，文件信息里记下预览图的尺寸
        let meta = await MetadataReader.read(try MetaFixtures.item(url))
        #expect(meta.pixelWidth == nil && meta.cameraPreviewSize == CGSize(width: 800, height: 1200))
        // 系统能解的 RAW 不带
        if let name = MetaFixtures.rawSamples.first {
            let m = await MetadataReader.read(try MetaFixtures.item(MetaFixtures.raw.appendingPathComponent(name)))
            #expect(m.pixelWidth != nil && m.cameraPreviewSize == nil)
        }
    }

    @Test("系统不认识的 RAW：快速预览用内嵌 JPEG 缩小后的画面，尺寸报内嵌 JPEG 本身的；没有内嵌 JPEG 就没有快速预览")
    func quickPreview() async throws {
        let url = try tempFile("fake.x3f", junk(4096) + jpegData(halves(4000, 3000)) + junk(5000))
        let quick = try await ImageDecoder.decode(try MetaFixtures.item(url), variant: .rawPreview)
        #expect(quick.isPreview && !quick.isCameraPreview)
        #expect(max(quick.image.width, quick.image.height) == ImageDecoder.quickCameraPreviewPixel)
        #expect(quick.pixelSize == CGSize(width: 4000, height: 3000))
        let none = try MetaFixtures.item(try tempFile("none.x3f", junk(50_000)))
        await #expect(throws: DecodeFailure.self) { try await ImageDecoder.decode(none, variant: .rawPreview) }
    }

    @Test("系统读不出拍摄信息的 RAW：信息面板用内嵌 JPEG 自己带的拍摄信息")
    func captureFromPreview() async throws {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifISOSpeedRatings: [400]],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TESTCAM", kCGImagePropertyTIFFModel: "X-99"],
        ]
        CGImageDestinationAddImage(dest, halves(1200, 800), props as CFDictionary)
        CGImageDestinationFinalize(dest)
        let url = try tempFile("fake.x3f", junk(4096) + (data as Data) + junk(5000))
        let meta = await MetadataReader.read(try MetaFixtures.item(url))
        #expect(meta.capture?.fNumber == 2.8 && meta.capture?.iso == 400)
        #expect(meta.capture?.camera?.contains("X-99") == true)
        #expect(meta.pixelWidth == nil && meta.cameraPreviewSize == CGSize(width: 1200, height: 800))
    }

    @Test("太小的内嵌缩略图（160 × 120）不算预览图")
    func ignoresTiny() throws {
        let url = try tempFile("fake.arw", junk(64) + jpegData(halves(160, 120)) + junk(64))
        #expect(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil) == nil)
    }

    @Test("取预览图不改动文件")
    func readOnly() throws {
        let url = try tempFile("fake.arw", junk(4096) + jpegData(halves(800, 600)) + junk(4096))
        let before = try sha(url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = EmbeddedPreview.largestJPEG(url: url, maxPixel: 320)
        _ = EmbeddedPreview.largestJPEG(url: url, maxPixel: nil)
        #expect(try sha(url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtime)
    }

    @Test("方向：JPEG 没带标记时用 RAW 的方向；6 = 顺时针转 90° 才正")
    func orientationFromRaw() throws {
        // 原图横着：左红右蓝。方向 6：显示时顺时针转 90°，于是上红下蓝，竖图
        let url = try tempFile("fake.arw", junk(64) + jpegData(halves(800, 600)) + junk(64))
        let found = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil, orientation: 6))
        #expect(found.pixelSize == CGSize(width: 600, height: 800))
        #expect(found.image.width == 600 && found.image.height == 800)
        let top = color(found.image, x: 300, y: 100), bottom = color(found.image, x: 300, y: 700)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
    }

    @Test("方向 8（逆时针 90°）和 3（180°）")
    func orientation8and3() throws {
        let url = try tempFile("fake.arw", junk(64) + jpegData(halves(800, 600)) + junk(64))
        let eight = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil, orientation: 8))
        // 逆时针转 90°：左边的红到了下面
        #expect(color(eight.image, x: 300, y: 700).r > 200)
        #expect(color(eight.image, x: 300, y: 100).b > 200)
        let three = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil, orientation: 3))
        #expect(three.pixelSize == CGSize(width: 800, height: 600))
        #expect(color(three.image, x: 100, y: 300).b > 200)   // 转 180°：左边变成蓝
        #expect(color(three.image, x: 700, y: 300).r > 200)
    }

    @Test("JPEG 自己带方向标记时用它自己的，不用 RAW 的")
    func ownOrientationWins() throws {
        let url = try tempFile("fake.raf", junk(64) + jpegData(halves(800, 600), orientation: 6) + junk(64))
        let found = try #require(EmbeddedPreview.largestJPEG(url: url, maxPixel: nil, orientation: 1))
        #expect(found.pixelSize == CGSize(width: 600, height: 800))
    }
}

// MARK: - 相机预览图解码（spec C1-02、C1-11、C1-12）

@Suite("相机预览图解码")
struct CameraPreviewDecodeTests {
    private func item(_ url: URL) throws -> MediaItem {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!,
                         fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                         modificationDate: attrs[.modificationDate] as? Date ?? Date())
    }

    @Test("系统不认识的文件（假 RAW）：完整解码失败，相机预览图取得出来")
    func fallsBack() async throws {
        let url = try tempFile("fake.x3f", junk(4096) + jpegData(halves(1200, 800)) + junk(4096))
        let item = try item(url)
        await #expect(throws: DecodeFailure.self) { try await ImageDecoder.decode(item, variant: .display(maxPixel: 2000)) }
        let preview = try await ImageDecoder.decode(item, variant: .cameraPreview(maxPixel: 600))
        #expect(preview.isCameraPreview)
        #expect(!preview.isPreview)
        #expect(preview.pixelSize == CGSize(width: 1200, height: 800))   // 预览图自己的尺寸（spec C1-06）
        #expect(preview.originalPixelSize == nil)                          // 系统读不到原片尺寸（spec C1-11）
        #expect(preview.isDownsampled)
        let full = try await ImageDecoder.decode(item, variant: .cameraPreview(maxPixel: nil))
        #expect(full.image.width == 1200 && !full.isDownsampled)
    }

    @Test("连预览图都没有：抛出带说明的失败")
    func noPreview() async throws {
        let url = try tempFile("broken.arw", junk(20_000))
        let item = try item(url)
        do {
            _ = try await ImageDecoder.decode(item, variant: .cameraPreview(maxPixel: 600))
            Issue.record("应该失败")
        } catch let failure as DecodeFailure {
            #expect(failure.kind == .corrupt)
            #expect(!failure.reason.isEmpty)
        }
    }

    @Test("缩略图：系统生成不出来时用内嵌 JPEG（spec C1-15）")
    func thumbnail() async throws {
        let url = try tempFile("fake.x3f", junk(4096) + jpegData(halves(1200, 800)) + junk(4096))
        let thumb = await ThumbnailGenerator.generate(try item(url))
        let image = try #require(thumb.image)
        #expect(max(image.width, image.height) == ThumbnailGenerator.maxPixel)
        // 不是 RAW 的坏文件不走这条路
        let bad = try tempFile("bad.png", junk(4096) + jpegData(halves(1200, 800)))
        #expect(await ThumbnailGenerator.generate(try item(bad)).image == nil)
    }
}

// MARK: - 新扩展名（spec C3、C4）

@Suite("新认识的格式")
struct NewFormatTests {
    static let newRaw = ["srw", "pef", "3fr", "fff", "iiq", "x3f", "erf", "mrw", "srf", "sr2",
                         "crw", "nrw", "rwl", "dcr", "kdc", "mef", "mos", "gpr"]

    @Test("新扩展名都是 RAW，大小写都认", arguments: newRaw)
    func isRaw(_ ext: String) {
        #expect(SupportedFormats.format(forExtension: ext) == .raw)
        #expect(SupportedFormats.format(forExtension: ext.uppercased()) == .raw)
        #expect(SupportedFormats.displayName(forExtension: ext).hasSuffix(" RAW"))
    }

    @Test("新 RAW 和原来的 RAW 一样受保护：星级只写小文件、不能原地旋转、编辑另存成 JPEG", arguments: newRaw)
    func protected(_ ext: String) {
        let url = URL(fileURLWithPath: "/tmp/yilan-fake/IMG_0001.\(ext.uppercased())")
        let item = MediaItem(url: url, format: SupportedFormats.format(forExtension: ext)!, fileSize: 100,
                             modificationDate: Date(timeIntervalSince1970: 1000))
        #expect(RatingFileIO.kind(for: item) == .sidecarOnly)
        #expect(FormatGroup.of(item) == .raw)
        let index = SidecarIndex(folder: url.deletingLastPathComponent(), sidecars: [], media: [item])
        #expect(index.writeURL(for: item).lastPathComponent == "IMG_0001.xmp")
        // 编辑只能另存成 JPEG / HEIF，不会沿用原格式，也就不会替换原文件
        let target = EditTarget.decide(for: item, sourceType: nil, hasAlpha: false, rawChoice: .jpeg)
        #expect(target.pathExtension == "jpg")
        #expect(!target.canReplaceOriginal)
    }

    @Test(".hif 是 HEIF 图片")
    func hif() {
        #expect(SupportedFormats.format(forExtension: "HIF") == .standard)
        #expect(SupportedFormats.displayName(forExtension: "hif") == "HEIF")
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/a.HIF"), format: .standard, fileSize: 1, modificationDate: Date())
        #expect(FormatGroup.of(item) == .heic)
        #expect(RatingFileIO.kind(for: item) == .imageIO)
    }
}

// MARK: - 信息行里的标签让位（spec C1-07）

@Suite("信息行：相机预览图标签")
struct PreviewTagLayoutTests {
    @Test("放得下：标签显示，文件名让出标签的宽度")
    func shows() {
        let l = InfoRowLayout.decide(width: 876, dims: 80, trailing: 150, tag: 70, name: 110)
        #expect(l.showTag && l.showDims && l.showTrailing)
        #expect(l.nameMax == l.side - 70 - InfoRowLayout.spacing)
    }

    @Test("窄：右边先让位，然后才是标签；标签不显示时文件名用满左半边")
    func givesWay() {
        // 左半边只有 110：放不下 70 的标签加至少 72 的文件名
        let width = (110 + InfoRowLayout.gap) * 2 + InfoRowLayout.starsWidth
        let l = InfoRowLayout.decide(width: width, dims: 80, trailing: 150, tag: 70, name: 200)
        #expect(!l.showTag && !l.showTrailing && l.showDims)
        #expect(l.nameMax == l.side)
    }

    @Test("没有标签时和以前一样")
    func noTag() {
        let l = InfoRowLayout.decide(width: 876, dims: 80, trailing: 150)
        #expect(!l.showTag && l.nameMax == l.side)
    }
}
