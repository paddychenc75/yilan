import CoreImage
import ImageIO

/// RAW 完整解码的省内存做法（F2-06）。
///
/// 系统的 `CGImageSourceCreateThumbnailAtIndex`（ImageDecoder.decodeStill 用的）对 RAW 有三条路：
/// 文件里有全尺寸 JPEG（尼康、佳能 CR3、iPhone DNG）就把它缩小；要的尺寸小于原片一半时走一条半尺寸的路；
/// 其余（例如索尼、富士在 3456 的屏幕上）完整解码。完整解码时系统内部的 Core Image 上下文每张要占 1.5–2.4 GB，
/// 解完大部分也不放，画廊视图连续翻 RAW 的内存峰值主要来自这里。
///
/// 实测（macOS 27.2）系统完整解码的结果 = CIRAWFilter 默认参数、不转方向、按原尺寸解出（16 位，文件声明的色彩空间）
/// → CG 高质量缩小到要的尺寸 → 按 EXIF 方向转正，和系统逐像素比平均差 0.05/255、最大 0.1/255。
/// 这里照这个步骤自己做，每张新建一个 Core Image 上下文、把它的工作内存限制在 96 MB，用完即放。
///
/// 只在验证过的情形接手，其余返回 nil，由调用方照旧交给系统：
/// macOS 27 及以后；文件里最大的内嵌 JPEG 不超过原片长边的 72%（验证过的是 27% 和 71%）；
/// 要的尺寸在原片长边的 51%–100%（系统的分界正好在 50%，留 1% 余量）；方向是 1、3、6、8 之一。
enum RawFullDecode {
    /// Core Image 渲染时最多用的工作内存（MB）。实测索尼 2400 万像素一张：64 → 峰值 0.7 GB、比系统慢约 10%；96 → 0.8 GB、和系统相当；128 → 1.0 GB
    static let memoryLimitMB = 96

    /// 系统这一次会不会完整解码（会，才由这里接手）。
    /// nativeLong：原片长边；previewLong：文件里最大的内嵌 JPEG 的长边（读不到为 nil）；target：要的长边
    static func applies(nativeLong: Int, previewLong: Int?, target: Int, orientation: Int) -> Bool {
        guard nativeLong > 0, let previewLong, previewLong >= 0 else { return false }
        // 有接近全尺寸的 JPEG：系统直接用那张，不接手
        guard previewLong * 100 <= nativeLong * 72 else { return false }
        // 不到一半：系统走半尺寸的路，复现不了；超过原片：调用方不会这样要
        guard target * 100 >= nativeLong * 51, target <= nativeLong else { return false }
        return [1, 3, 6, 8].contains(orientation)
    }

    /// 文件里最大的内嵌 JPEG 的长边；读不到为 nil。
    /// 来自文件级属性里的 "{raw}" → "Thumbnails"（没有公开常量；注意和单张属性里的 kCGImagePropertyRawDictionary "{Raw}" 不是一个）。
    /// 哪天系统不再给这一项，这里读不到，就不接手，照旧交给系统
    static func largestPreviewLong(_ source: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyProperties(source, nil) as? [String: Any],
              let raw = props["{raw}"] as? [String: Any],
              let thumbs = raw["Thumbnails"] as? [[String: Any]], !thumbs.isEmpty else { return nil }
        return thumbs.map { max(($0["Width"] as? Int) ?? 0, ($0["Height"] as? Int) ?? 0) }.max()
    }

    /// 文件声明的色彩空间（系统完整解码时输出用的），读不到为 nil
    static func declaredColorSpace(_ source: CGImageSource) -> CGColorSpace? {
        guard let props = CGImageSourceCopyProperties(source, nil) as? [String: Any],
              let contents = props[kCGImagePropertyFileContentsDictionary as String] as? [String: Any],
              let first = (contents["Images"] as? [[String: Any]])?.first,
              let name = first["NamedColorSpace"] as? String else { return nil }
        return CGColorSpace(name: name as CFString)
    }

    /// 适用时按系统的步骤解码，返回转正后的图；不适用或中途出任何意外都返回 nil（调用方改用系统的做法）
    static func decode(_ url: URL, source: CGImageSource, target: Int) throws -> CGImage? {
        guard #available(macOS 27, *) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard applies(nativeLong: max(width, height), previewLong: largestPreviewLong(source), target: target, orientation: orientation),
              let space = declaredColorSpace(source),
              let filter = CIRAWFilter(imageURL: url),
              // Core Image 和 ImageIO 对方向、尺寸的看法一致才接手
              filter.orientation.rawValue == UInt32(orientation) else { return nil }
        filter.orientation = .up
        guard let output = filter.outputImage,
              Int(output.extent.width) == width, Int(output.extent.height) == height else { return nil }
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: memoryLimitMB])
        guard let full = context.createCGImage(output, from: output.extent, format: .RGBA16, colorSpace: space) else { return nil }
        try Task.checkCancellation()
        guard let scaled = scale(full, longSide: target) else { return nil }
        return rotate(scaled, orientation: orientation)
    }

    /// 等比缩小到长边 longSide（宽高四舍五入，和系统一致）；不需要缩小时原样返回
    static func scale(_ image: CGImage, longSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > longSide else { return image }
        let s = Double(longSide) / Double(long)
        let w = max(1, Int((Double(image.width) * s).rounded()))
        let h = max(1, Int((Double(image.height) * s).rounded()))
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 按 EXIF 方向转正（只处理 1、3、6、8：整 90° 的旋转，不插值）
    static func rotate(_ image: CGImage, orientation: Int) -> CGImage? {
        guard orientation != 1 else { return image }
        let swap = orientation == 6 || orientation == 8
        let w = swap ? image.height : image.width
        let h = swap ? image.width : image.height
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        switch orientation {
        case 3: ctx.translateBy(x: CGFloat(w), y: CGFloat(h)); ctx.rotate(by: .pi)
        case 6: ctx.translateBy(x: 0, y: CGFloat(h)); ctx.rotate(by: -.pi / 2)
        case 8: ctx.translateBy(x: CGFloat(w), y: 0); ctx.rotate(by: .pi / 2)
        default: return nil
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
