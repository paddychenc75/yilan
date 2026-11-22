import AppKit
import AVFoundation
import CoreMedia
import ImageIO

/// 大图解码。所有方法都是纯函数，可以在任意后台线程调用
enum ImageDecoder {
    enum Variant: Hashable, Sendable {
        /// 缩小到屏幕尺寸（maxPixel 为长边像素）
        case display(maxPixel: Int)
        /// RAW 文件里自带的预览图（秒开）
        case rawPreview
        /// 原始分辨率（放大查看细节时）
        case full
        /// 相机预览图：系统解不了这张 RAW 时，取文件里最大的内嵌 JPEG（spec C1-03）。maxPixel 为 nil 时取原始大小
        case cameraPreview(maxPixel: Int?)
    }

    /// 一次解码的长边上限：再大的图（例如几万像素的全景、扫描件）也只解到这么大，避免占满内存。
    /// 超出部分要靠分块显示，以后再做
    static let maxDecodePixel = 16384
    /// 一张动图所有帧加起来最多占用的内存
    static let animationMemoryBudget = 256 * 1024 * 1024
    static let maxAnimationFrames = 600
    /// 为了省内存缩小动图时，长边不小于这个尺寸（再小就改为少取几帧）
    static let minAnimationPixel = 480

    static func decode(_ item: MediaItem, variant: Variant) async throws -> DecodedImage {
        try Task.checkCancellation()
        if let failure = accessFailure(item) { throw failure }
        if item.fileSize == 0 {
            throw DecodeFailure(reason: String(localized: "文件是空的，或者不是有效的 \(item.formatName) 文件。", comment: "%@ 是格式名，例如 TIFF"),
                                detail: String(localized: "文件头无法识别 · \(Formatting.fileSize(0))", comment: "%@ 是文件大小"))
        }
        switch item.format {
        case .video:
            return try await decodeVideoPoster(item, maxPixel: variant.maxPixel)
        case .svg:
            return try decodeSVG(item, maxPixel: variant.maxPixel ?? 4096)
        case .gif:
            return try decodeAnimated(item, maxPixel: variant.maxPixel)
        case .standard, .raw:
            if variant == .rawPreview { return try decodeEmbeddedPreview(item) }
            if case .cameraPreview(let maxPixel) = variant { return try decodeCameraPreview(item, maxPixel: maxPixel) }
            return try decodeStill(item, maxPixel: variant.maxPixel)
        }
    }

    // MARK: - 静态图（含 RAW 完整解码）

    static func decodeStill(_ item: MediaItem, maxPixel: Int?) throws -> DecodedImage {
        let source = try makeSource(item)
        let size = orientedPixelSize(source)
        let longSide = Int(max(size.width, size.height))
        // 原图比屏幕小就按原尺寸解码；否则缩小到屏幕尺寸；原始分辨率也不超过 maxDecodePixel
        let target = min(maxPixel.map { min($0, max(longSide, 1)) } ?? max(longSide, 1), maxDecodePixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        try Task.checkCancellation()
        // RAW：系统这一次会完整解码时，改用同样的步骤自己解（画面一致，内存少得多，见 RawFullDecode）；不适用时返回 nil
        let image: CGImage
        if item.format == .raw, let own = try RawFullDecode.decode(item.url, source: source, target: target) {
            image = own
        } else {
            guard let system = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw corrupt(item, detail: String(localized: "解码失败"))
            }
            image = system
        }
        return DecodedImage(
            image: image,
            pixelSize: size == .zero ? CGSize(width: image.width, height: image.height) : size,
            isDownsampled: longSide > 0 && target < longSide
        )
    }

    /// RAW 内嵌预览：只取文件里已有的 JPEG 预览，不做完整解码
    static func decodeEmbeddedPreview(_ item: MediaItem) throws -> DecodedImage {
        // 系统连文件格式都不认识（适马 X3F）：没有系统预览可取，直接看文件里有没有内嵌 JPEG
        guard let source = try? makeSource(item) else {
            if let quick = quickCameraPreview(item, orientation: nil) { return quick }
            return try decodeEmbeddedPreviewFailure(item)
        }
        let size = orientedPixelSize(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // 系统读不到尺寸（= 解不了这张 RAW，随后会显示相机预览图）又不给预览时（旧系统上的富士压缩 RAW、尼康高效率压缩）：
            // 先把文件里的内嵌 JPEG 缩小了顶上，不让用户对着缩略图等完整尺寸的那一张
            if size == .zero {
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
                if let quick = quickCameraPreview(item, orientation: orientation) { return quick }
            }
            throw DecodeFailure(reason: "没有内嵌预览", detail: "")   // 只在内部用（调用方会改为完整解码），不显示给用户，不用翻译
        }
        // 系统读不到这张 RAW 的尺寸（不认识的机型）时，按预览图自己的尺寸算，不能是 0
        let shown = size == .zero ? CGSize(width: image.width, height: image.height) : size
        return DecodedImage(image: image, pixelSize: shown, isPreview: true, isDownsampled: true)
    }

    /// 快速预览用的相机预览图长边（和系统给的内嵌预览差不多大）
    static let quickCameraPreviewPixel = 1600

    private static func quickCameraPreview(_ item: MediaItem, orientation: Int?) -> DecodedImage? {
        guard item.format == .raw,
              let found = EmbeddedPreview.largestJPEG(url: item.url, maxPixel: quickCameraPreviewPixel, orientation: orientation) else { return nil }
        return DecodedImage(image: found.image, pixelSize: found.pixelSize, isPreview: true, isDownsampled: true)
    }

    private static func decodeEmbeddedPreviewFailure(_ item: MediaItem) throws -> DecodedImage {
        throw accessFailure(item) ?? DecodeFailure(reason: "没有内嵌预览", detail: "")
    }

    /// 相机预览图（spec C1-03、C1-04）：先在文件里找最大的内嵌 JPEG，找不到再用系统给的内嵌预览；都没有就抛错
    static func decodeCameraPreview(_ item: MediaItem, maxPixel: Int?) throws -> DecodedImage {
        // 系统对这个文件知道多少算多少：原片尺寸、方向。文件格式系统不认识时这里什么都读不到
        var original: CGSize?
        var orientation: Int?
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            let size = orientedPixelSize(source)
            if size.width > 0, size.height > 0 { original = size }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        }
        try Task.checkCancellation()
        if let found = EmbeddedPreview.largestJPEG(url: item.url, maxPixel: maxPixel, orientation: orientation) {
            let long = max(found.pixelSize.width, found.pixelSize.height)
            return DecodedImage(image: found.image, pixelSize: found.pixelSize,
                                isDownsampled: CGFloat(max(found.image.width, found.image.height)) < long,
                                isCameraPreview: true, originalPixelSize: original)
        }
        try Task.checkCancellation()
        if let fallback = try? decodeEmbeddedPreview(item) {
            return DecodedImage(image: fallback.image, pixelSize: CGSize(width: fallback.image.width, height: fallback.image.height),
                                isCameraPreview: true, originalPixelSize: original)
        }
        if let failure = accessFailure(item) { throw failure }
        // spec C1-12：两种预览都取不到
        throw DecodeFailure(reason: String(localized: "文件可能已损坏，里面也没有可以显示的预览图。"),
                            detail: Formatting.fileSize(item.fileSize))
    }

    // MARK: - GIF

    static func decodeAnimated(_ item: MediaItem, maxPixel: Int?, memoryBudget: Int = animationMemoryBudget) throws -> DecodedImage {
        let source = try makeSource(item)
        let count = CGImageSourceGetCount(source)
        let size = orientedPixelSize(source)
        let longSide = Int(max(size.width, size.height))
        let requested = min(maxPixel.map { min($0, max(longSide, 1)) } ?? max(longSide, 1), maxDecodePixel)
        // 所有帧加起来不超过内存预算：先缩小尺寸，还不够就隔几帧取一帧
        let plan = animationPlan(frameCount: count, pixelSize: size, target: requested, budget: memoryBudget)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: plan.maxPixel,
        ]
        var frames: [CGImage] = []
        var durations: [Double] = []
        for i in stride(from: 0, to: count, by: plan.step) {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            frames.append(frame)
            // 跳过的帧的时长加到取到的这一帧上，整段播放时长不变
            durations.append((i..<min(i + plan.step, count)).reduce(0) { $0 + frameDelay(source, index: $1) })
        }
        guard let first = frames.first else { throw corrupt(item, detail: String(localized: "解码失败")) }
        return DecodedImage(
            image: first,
            pixelSize: size,
            frames: frames.count > 1 ? frames : [],
            frameDurations: frames.count > 1 ? durations : [],
            isDownsampled: plan.maxPixel < longSide,
            formatDetail: count > 1 ? String(localized: "\(count) 帧", comment: "缩略图栏信息行：GIF 的帧数") : nil
        )
    }

    struct AnimationPlan: Equatable {
        /// 解码时的长边像素
        let maxPixel: Int
        /// 每隔几帧取一帧（1 = 每帧都取）
        let step: Int
    }

    /// 决定动图的解码尺寸和取帧间隔，让全部帧的内存不超过 budget
    static func animationPlan(frameCount: Int, pixelSize: CGSize, target: Int, budget: Int) -> AnimationPlan {
        let count = max(frameCount, 1)
        let long = max(pixelSize.width, pixelSize.height, 1)
        let target = max(target, 1)
        // 估算一帧的字节数（按 64 字节对齐行宽，宽高各多算 1 像素，宁可估大）
        func frameBytes(_ maxPixel: Int) -> Int {
            let s = min(1, CGFloat(maxPixel) / long)
            let w = Int((pixelSize.width * s).rounded(.up)) + 1
            let h = Int((pixelSize.height * s).rounded(.up)) + 1
            return (w * 4 + 63) / 64 * 64 * h
        }
        let wanted = min(count, maxAnimationFrames)
        var maxPixel = target
        let total = frameBytes(target) * wanted
        if total > budget {
            let shrink = (Double(budget) / Double(total)).squareRoot()
            maxPixel = max(min(target, minAnimationPixel), Int(Double(min(CGFloat(target), long)) * shrink))
        }
        let perFrame = max(frameBytes(maxPixel), 1)
        let kept = max(1, min(wanted, budget / perFrame))
        let step = (count + kept - 1) / kept
        return AnimationPlan(maxPixel: maxPixel, step: max(step, 1))
    }

    static func frameDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        let delay = unclamped > 0 ? unclamped : (gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1)
        // 与浏览器一致：小于 0.011 秒的帧按 0.1 秒播放
        return delay < 0.011 ? 0.1 : delay
    }

    // MARK: - SVG

    /// 系统的 NSImage 可以直接读取 SVG（_NSSVGImageRep），按需要的像素尺寸栅格化
    static func decodeSVG(_ item: MediaItem, maxPixel: Int) throws -> DecodedImage {
        guard let image = NSImage(contentsOf: item.url), image.size.width > 0, image.size.height > 0 else {
            throw corrupt(item, detail: String(localized: "SVG 无法解析"))
        }
        let s = image.size
        let scale = CGFloat(maxPixel) / max(s.width, s.height)
        let w = max(1, Int((s.width * scale).rounded()))
        let h = max(1, Int((s.height * scale).rounded()))
        guard let cg = render(image, width: w, height: h) else { throw corrupt(item, detail: String(localized: "SVG 渲染失败")) }
        return DecodedImage(image: cg, pixelSize: s)
    }

    static func render(_ image: NSImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - 视频第一帧（第一阶段只显示静帧，播放在第二阶段实现）

    static func decodeVideoPoster(_ item: MediaItem, maxPixel: Int?) async throws -> DecodedImage {
        let asset = AVURLAsset(url: item.url)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            if let failure = accessFailure(item) { throw failure }
            throw DecodeFailure(reason: String(localized: "文件已损坏，或者不是有效的 \(item.formatName) 视频。", comment: "%@ 是格式名，例如 MP4"),
                                detail: String(localized: "无法读取视频信息 · \(Formatting.fileSize(item.fileSize))", comment: "%@ 是文件大小"))
        }
        guard let track = tracks.first else {
            throw DecodeFailure(reason: String(localized: "这个文件里没有视频画面。"),
                                detail: String(localized: "没有视频轨道 · \(Formatting.fileSize(item.fileSize))", comment: "%@ 是文件大小"))
        }
        var pixelSize = CGSize.zero
        var codec: String?
        if let (natural, transform, formats) = try? await track.load(.naturalSize, .preferredTransform, .formatDescriptions) {
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            pixelSize = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
            if let f = formats.first { codec = codecName(CMFormatDescriptionGetMediaSubType(f)) }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let maxPixel { generator.maximumSize = CGSize(width: maxPixel, height: maxPixel) }
        do {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: .zero)
            return DecodedImage(
                image: image,
                pixelSize: pixelSize == .zero ? CGSize(width: image.width, height: image.height) : pixelSize,
                duration: duration.seconds.isFinite ? duration.seconds : nil,
                formatDetail: codec
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DecodeFailure(reason: String(localized: "系统不支持这种视频编码。"),
                                detail: String(localized: "无法取得第一帧 · \(Formatting.fileSize(item.fileSize))", comment: "%@ 是文件大小"))
        }
    }

    static func codecName(_ subtype: FourCharCode) -> String? {
        switch subtype {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy: "ProRes"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        default: nil
        }
    }

    // MARK: - 工具

    static func makeSource(_ item: MediaItem) throws -> CGImageSource {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, opts),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else {
            // 打不开时先看是不是文件不见了 / 读不了，不要误报成“已损坏”
            throw accessFailure(item) ?? corrupt(item, detail: String(localized: "文件头无法识别"))
        }
        return source
    }

    /// 文件不存在或读不了时的说明；文件正常返回 nil
    static func accessFailure(_ item: MediaItem) -> DecodeFailure? {
        let path = item.url.path
        if !FileManager.default.fileExists(atPath: path) {
            return DecodeFailure(reason: String(localized: "文件已被移走或删除。"), detail: "", kind: .missing)
        }
        if !FileManager.default.isReadableFile(atPath: path) {
            return DecodeFailure(reason: String(localized: "无法读取这个文件，可能没有访问权限，或者所在的磁盘已断开。"),
                                 detail: "", kind: .unreadable)
        }
        return nil
    }

    /// 读取像素尺寸，EXIF 方向为 5–8（旋转 90°）时宽高互换
    static func orientedPixelSize(_ source: CGImageSource) -> CGSize {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .zero }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 && orientation <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func corrupt(_ item: MediaItem, detail: String) -> DecodeFailure {
        // 图片和视频分成两句完整的话（英文里名词位置和冠词不同，不拼接）
        let reason = item.kind == .video
            ? String(localized: "文件已损坏，或者不是有效的 \(item.formatName) 视频。", comment: "%@ 是格式名，例如 MP4")
            : String(localized: "文件已损坏，或者不是有效的 \(item.formatName) 图片。", comment: "%@ 是格式名，例如 TIFF")
        // 原因和文件大小之间用“ · ”隔开，两边都是已经翻译好的短语
        return DecodeFailure(reason: reason, detail: "\(detail) · \(Formatting.fileSize(item.fileSize))")
    }
}

extension ImageDecoder.Variant {
    var maxPixel: Int? {
        switch self {
        case .display(let m): m
        case .rawPreview: nil
        case .full: nil
        case .cameraPreview(let m): m
        }
    }
}
