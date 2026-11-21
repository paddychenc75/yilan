import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Yilan

/// RAW 完整解码自己做（F2-06）：什么时候接手、接手后画面和系统的做法一致
@Suite("RAW 完整解码（省内存的做法）")
struct RawFullDecodeTests {
    // MARK: 什么时候接手

    @Test("系统会完整解码的情形才接手：预览图小、要的尺寸不低于原片一半")
    func applies() {
        // 索尼 2400 万像素：内嵌 1616，屏幕 3456
        #expect(RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 3456, orientation: 1))
        // 富士 2600 万像素：内嵌 4416（比屏幕大，但不是全尺寸，系统照样完整解码）
        #expect(RawFullDecode.applies(nativeLong: 6240, previewLong: 4416, target: 3456, orientation: 6))
        // 原始分辨率
        #expect(RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 6000, orientation: 1))
        // 有全尺寸 JPEG（尼康、佳能 CR3、iPhone DNG）：系统用那张，不接手
        #expect(!RawFullDecode.applies(nativeLong: 6048, previewLong: 6048, target: 3456, orientation: 1))
        #expect(!RawFullDecode.applies(nativeLong: 4032, previewLong: 4032, target: 3456, orientation: 6))
        // 预览图接近全尺寸：没验证过系统怎么选，不接手
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 4500, target: 3456, orientation: 1))
        // 要的尺寸不到原片一半（小屏幕、高像素机身）：系统走半尺寸的路，不接手；正好一半也留余量不接手
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 2560, orientation: 1))
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 3000, orientation: 1))
        #expect(!RawFullDecode.applies(nativeLong: 9504, previewLong: 1616, target: 3456, orientation: 1))
        // 比原片还大、读不到预览图、镜像方向：不接手
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 6001, orientation: 1))
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: nil, target: 3456, orientation: 1))
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 3456, orientation: 2))
        #expect(!RawFullDecode.applies(nativeLong: 6000, previewLong: 1616, target: 3456, orientation: 5))
        #expect(!RawFullDecode.applies(nativeLong: 0, previewLong: 0, target: 3456, orientation: 1))
    }

    @Test("不是 RAW 的文件、系统读不到 {raw} 信息的文件：不接手")
    func notRaw() throws {
        let url = try Self.write(Self.quadrants(60, 40), type: .jpeg, name: "a.jpg")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(RawFullDecode.largestPreviewLong(source) == nil)
        #expect(try RawFullDecode.decode(url, source: source, target: 40) == nil)
    }

    // MARK: 缩小、转方向（和系统一致）

    @Test("缩小：长边到要的尺寸，短边四舍五入（和系统一致）；不需要缩小时原样返回")
    func scale() throws {
        let image = Self.quadrants(600, 400)
        let a = try #require(RawFullDecode.scale(image, longSide: 300))
        #expect(a.width == 300 && a.height == 200)
        let b = try #require(RawFullDecode.scale(image, longSide: 301))   // 200.67 → 201
        #expect(b.width == 301 && b.height == 201)
        let c = try #require(RawFullDecode.scale(Self.quadrants(6048, 4024), longSide: 3456))   // 2299.4 → 2299（系统给的也是 2299）
        #expect(c.width == 3456 && c.height == 2299)
        #expect(RawFullDecode.scale(image, longSide: 600) === image)
        #expect(RawFullDecode.scale(image, longSide: 900) === image)
    }

    @Test("转方向：3、6、8 和系统按 EXIF 方向转正的结果逐像素一样")
    func rotate() throws {
        let image = Self.quadrants(6, 4)
        for orientation in [1, 3, 6, 8] {
            // 系统的做法：同一张图存成带方向的 TIFF（无损），取缩略图时按方向转正
            let url = try Self.write(image, type: .tiff, name: "o\(orientation).tiff", orientation: orientation)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let system = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6,
            ] as CFDictionary))
            let own = try #require(RawFullDecode.rotate(image, orientation: orientation))
            #expect(own.width == system.width && own.height == system.height, "方向 \(orientation)")
            #expect(Self.pixels(own) == Self.pixels(system), "方向 \(orientation)")
        }
        #expect(RawFullDecode.rotate(image, orientation: 2) == nil)
    }

    // MARK: 真 RAW 样张（本机才有，没有时跳过）

    @Test("样张：画廊尺寸和原始分辨率下，结果和系统的做法逐像素比平均差 < 0.5/255、尺寸相同；索尼、富士由这里接手")
    func matchesSystem() throws {
        let samples = MetaFixtures.rawSamples
        guard !samples.isEmpty else { return }
        for name in samples {
            let url = MetaFixtures.raw.appendingPathComponent(name)
            let item = try MetaFixtures.item(url)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
            let long = Int(max(ImageDecoder.orientedPixelSize(source).width, ImageDecoder.orientedPixelSize(source).height))
            for target in [3456, long] {
                let own = try ImageDecoder.decodeStill(item, maxPixel: target).image
                let system = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(target, long),
                ] as CFDictionary))
                #expect(own.width == system.width && own.height == system.height, "\(name) \(target)")
                let diff = Self.meanDifference(own, system)
                #expect(diff < 0.5, "\(name) \(target)：平均差 \(diff)/255")
                // 哪些由这里接手：系统完整解码的（16 位）才接手
                let taken = try RawFullDecode.decode(url, source: source, target: min(target, long)) != nil
                if #available(macOS 27, *) {
                    #expect(taken == (system.bitsPerComponent > 8), "\(name) \(target)")
                }
            }
        }
    }

    // MARK: - 工具

    /// 四个象限四种颜色（能看出方向）
    static func quadrants(_ width: Int, _ height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for (i, color) in colors.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: i % 2 * width / 2, y: i / 2 * height / 2, width: width - width / 2, height: height - height / 2))
        }
        // 左下角一个白点，区分镜像
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, type: UTType, name: String, orientation: Int? = nil) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yilan-rawfull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// 画成同一种 8 位 sRGB 位图后的像素
    static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// 两张同尺寸的图画到 a 的色彩空间（16 位）后，RGB 的平均差（单位 1/255）
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = a.width, h = a.height
        func px(_ image: CGImage) -> [UInt16] {
            var data = [UInt16](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                space: a.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        let x = px(a), y = px(b)
        var sum = 0.0, n = 0
        for i in 0..<x.count where i % 4 != 3 {
            sum += Double(abs(Int(x[i]) - Int(y[i])))
            n += 1
        }
        return sum / Double(max(n, 1)) / 257
    }
}
