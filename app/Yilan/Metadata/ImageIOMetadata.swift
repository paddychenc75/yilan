import Foundation
import ImageIO

/// 用 ImageIO 读星级、检查写入结果；HEIC / HEIF / TIFF 的无损写入（技术方案 3.1）
enum ImageIOMetadata {
    private static var noCache: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// 文件内部 xmp:Rating 的原始值（包括相机机内星级，只要系统能读出）
    static func rating(at url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
        return RatingValue.parse(CGImageMetadataCopyStringValueWithPath(md, nil, "xmp:Rating" as CFString) as String?)
    }

    /// HEIC / TIFF：CGImageDestinationCopyImageSource 合并写入（画面数据不重新压缩）。
    /// value 为 0 时写 0：这两种格式实测删不掉这一项（设 kCFNull 无效）
    static func write(rating value: Int, from source: URL, to temp: URL, microsoftPercent: Int? = nil) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw RatingWriteError.unsupported("无法读取原图")
        }
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, CGImageSourceGetCount(src), nil) else {
            throw RatingWriteError.notWritable
        }
        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(meta, nil, "xmp:Rating" as CFString, String(value) as CFString)
        if let microsoftPercent {
            CGImageMetadataRegisterNamespaceForPrefix(meta, XMPPacket.microsoftPhotoNS as CFString, "MicrosoftPhoto" as CFString, nil)
            CGImageMetadataSetValueWithPath(meta, nil, "MicrosoftPhoto:Rating" as CFString, String(microsoftPercent) as CFString)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            let message = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw RatingWriteError.unsupported(message)
        }
    }

    /// 文件的 XMP 里已经有 MicrosoftPhoto:Rating（只改已有的，不新增）
    static func hasMicrosoftRating(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return false }
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(md, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
            if (CGImageMetadataTagCopyNamespace(tag) as String?) == XMPPacket.microsoftPhotoNS,
               (CGImageMetadataTagCopyName(tag) as String?) == "Rating" { found = true }
            return !found
        }
        return found
    }

    /// 写入前后要保持不变的“画面事实”
    struct Facts: Equatable {
        var count: Int
        var width: Int
        var height: Int
        var orientation: Int
        /// 带着的辅助图（HDR 增益图、深度图等）种类
        var auxiliary: [String]
    }

    static func facts(at url: URL) -> Facts? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, noCache) as? [CFString: Any] else { return nil }
        let kinds: [CFString] = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap,
                                 kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                                 kCGImageAuxiliaryDataTypePortraitEffectsMatte]
        let aux = kinds.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil }.map { $0 as String }
        return Facts(count: CGImageSourceGetCount(src),
                     width: p[kCGImagePropertyPixelWidth] as? Int ?? -1,
                     height: p[kCGImagePropertyPixelHeight] as? Int ?? -1,
                     orientation: p[kCGImagePropertyOrientation] as? Int ?? 1,
                     auxiliary: aux)
    }

    /// ImageIO 看到的全部 XMP 项（路径 = 值）：检查写入后原有项一个不少
    static func xmpPaths(at url: URL) -> Set<String> {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return [] }
        var out = Set<String>()
        CGImageMetadataEnumerateTagsUsingBlock(md, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let value = CGImageMetadataTagCopyValue(tag)
            out.insert("\(path)=\((value as? String) ?? "")")
            return true
        }
        return out
    }
}
