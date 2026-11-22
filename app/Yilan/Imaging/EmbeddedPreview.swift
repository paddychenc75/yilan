import CoreGraphics
import Foundation
import ImageIO

/// 在文件里找相机内嵌的 JPEG（spec C1-03，调研 raw-compat.md）。
/// 系统解不了某张 RAW 时用它当「相机预览图」。不需要懂各家 RAW 的文件结构：
/// 从头扫一遍，找 JPEG 的开头标记，挑能解码的里面最大的一张。
/// 只读：文件用只读方式映射进内存，不写任何东西。纯函数，可以在任意后台线程调用
enum EmbeddedPreview {
    struct Found {
        /// 已经按方向转正、缩到 maxPixel 以内的画面
        let image: CGImage
        /// 这张内嵌 JPEG 本身的像素尺寸（已按方向转正）
        let pixelSize: CGSize
    }

    /// 最多看多少个候选：预览图都在文件靠前的位置，后面大片的是 RAW 数据
    static let maxCandidates = 60
    /// 比这还小的不算预览图（160 × 120 的小缩略图）
    static let minArea = 200 * 150
    /// 一张内嵌 JPEG 最多读这么多字节
    static let maxJPEGBytes = 64 << 20

    /// 找出最大的能解码的内嵌 JPEG。
    /// - Parameters:
    ///   - maxPixel: 解码时长边缩到多少像素以内；nil = 原始大小
    ///   - orientation: RAW 文件本身记录的方向（EXIF 1–8）。内嵌 JPEG 自己带方向标记时用它自己的，否则用这个
    static func largestJPEG(url: URL, maxPixel: Int?, orientation: Int? = nil) -> Found? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return nil }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Found? in
            guard let base = buffer.baseAddress else { return nil }
            let candidates = self.candidates(in: buffer).sorted { $0.width * $0.height > $1.width * $1.height }
            for c in candidates {
                if Task.isCancelled { return nil }
                // 不拷贝：只在这个闭包里用，解码结果是独立的位图
                let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + c.offset),
                                 count: min(buffer.count - c.offset, maxJPEGBytes), deallocator: .none)
                if let found = decode(slice, candidate: c, maxPixel: maxPixel, fallbackOrientation: orientation) { return found }
            }
            return nil
        }
    }

    /// 只要尺寸、不解码画面：文件里最大的内嵌 JPEG 转正后的像素尺寸。方向的取法和 largestJPEG 一样
    static func largestSize(url: URL) -> CGSize? { largestInfo(url: url)?.size }

    /// 最大的内嵌 JPEG 的尺寸和它自己带的属性（拍摄信息在这里面：系统读不了这张 RAW 时靠它填信息面板）
    static func largestInfo(url: URL) -> (size: CGSize, properties: [CFString: Any])? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 16 else { return nil }
        let rawOrientation = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { source -> Int? in
            guard CGImageSourceGetCount(source) > 0 else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> (size: CGSize, properties: [CFString: Any])? in
            guard let base = buffer.baseAddress,
                  let c = candidates(in: buffer).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + c.offset),
                             count: min(buffer.count - c.offset, maxJPEGBytes), deallocator: .none)
            let props = CGImageSourceCreateWithData(slice as CFData, jpegHint)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? rawOrientation ?? 1
            let size = (5...8).contains(orientation) ? CGSize(width: c.height, height: c.width) : CGSize(width: c.width, height: c.height)
            return (size, props ?? [:])
        }
    }

    struct Candidate: Equatable {
        let offset: Int
        let width: Int
        let height: Int
    }

    /// 文件里所有看起来像 JPEG 开头、并且读得出宽高的位置
    static func candidates(in buffer: UnsafeRawBufferPointer) -> [Candidate] {
        guard let base = buffer.baseAddress else { return [] }
        let bytes = buffer.bindMemory(to: UInt8.self)
        let count = buffer.count
        var result: [Candidate] = []
        var i = 0
        while i + 4 < count, result.count < maxCandidates {
            guard let hit = memchr(base + i, 0xFF, count - i - 3) else { break }
            let offset = base.distance(to: UnsafeRawPointer(hit))
            // FF D8 FF 后面是 E0（JFIF）、E1（EXIF）、DB（量化表）、C4（哈夫曼表）、EE（Adobe）之一
            let marker = bytes[offset + 3]
            if bytes[offset + 1] == 0xD8, bytes[offset + 2] == 0xFF,
               marker == 0xE0 || marker == 0xE1 || marker == 0xDB || marker == 0xC4 || marker == 0xEE {
                let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + offset),
                                 count: min(count - offset, maxJPEGBytes), deallocator: .none)
                if let size = jpegSize(slice), size.width * size.height >= minArea {
                    result.append(Candidate(offset: offset, width: size.width, height: size.height))
                }
                i = offset + 4
            } else {
                i = offset + 1
            }
        }
        return result
    }

    private static var jpegHint: CFDictionary { [kCGImageSourceTypeIdentifierHint: "public.jpeg"] as CFDictionary }

    private static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, jpegHint),
              CGImageSourceGetType(source).map({ $0 as String == "public.jpeg" }) == true,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    private static func decode(_ data: Data, candidate: Candidate, maxPixel: Int?, fallbackOrientation: Int?) -> Found? {
        guard let source = CGImageSourceCreateWithData(data as CFData, jpegHint) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let own = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let orientation = own ?? fallbackOrientation ?? 1
        let longSide = max(candidate.width, candidate.height)
        let target = min(maxPixel.map { min($0, longSide) } ?? longSide, ImageDecoder.maxDecodePixel)
        // 不让系统按 JPEG 自己的标记转：统一在下面按决定好的方向转（JPEG 没带标记时要用 RAW 的）
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let image = oriented(raw, orientation: orientation) else { return nil }
        let swaps = orientation >= 5 && orientation <= 8
        let size = swaps ? CGSize(width: candidate.height, height: candidate.width)
            : CGSize(width: candidate.width, height: candidate.height)
        return Found(image: image, pixelSize: size)
    }

    /// 按 EXIF 方向（1–8）把画面转正；1 或认不出的值原样返回
    static func oriented(_ image: CGImage, orientation: Int) -> CGImage? {
        guard (2...8).contains(orientation) else { return image }
        // 5、7 是「水平镜像再转 90°」，很少见：拆成两步
        if orientation == 5 { return oriented(image, orientation: 2).flatMap { oriented($0, orientation: 8) } }
        if orientation == 7 { return oriented(image, orientation: 2).flatMap { oriented($0, orientation: 6) } }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swaps = orientation >= 5
        let size = swaps ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // 坐标原点在左下角。每种方向：把原图画到转正后的位置
        var t = CGAffineTransform.identity
        switch orientation {
        case 2: t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)                    // 水平镜像
        case 3: t = t.translatedBy(x: w, y: h).rotated(by: .pi)                         // 转 180°
        case 4: t = t.translatedBy(x: 0, y: h).scaledBy(x: 1, y: -1)                    // 垂直镜像
        case 6: t = t.translatedBy(x: 0, y: w).rotated(by: -.pi / 2)                    // 顺时针 90° 才正
        case 8: t = t.translatedBy(x: h, y: 0).rotated(by: .pi / 2)                     // 逆时针 90° 才正
        default: break
        }
        ctx.interpolationQuality = .none
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
