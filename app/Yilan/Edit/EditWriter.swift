import CoreImage
import Foundation
import ImageIO

/// 编辑结果写成文件（技术方案 13.3、13.4）：编辑模式唯一碰用户图片文件的地方。
/// 全部是同步函数，必须在后台线程调用

/// 副本命名（spec ED-28）：「原名 编辑.ext」/「name edited.ext」，重名加序号
enum EditNaming {
    /// 不带扩展名的副本名；n 从 1 开始，1 不带序号
    static func baseName(_ base: String, attempt n: Int) -> String {
        n <= 1 ? String(localized: "\(base) 编辑", comment: "编辑后另存的副本文件名（不含扩展名）；%@ 是原文件名")
            : String(localized: "\(base) 编辑 \(n)", comment: "编辑后另存的副本文件名，重名时带序号；%1$@ 是原文件名，%2$lld 是序号")
    }

    /// 已经是副本的名字（“X 编辑”“X 编辑 3”）去掉后缀，再编辑时得到“X 编辑 2”，而不是“X 编辑 编辑”
    static func strippingCopySuffix(_ base: String) -> String {
        let suffix = baseName("", attempt: 1)          // “ 编辑” / “ edited”
        guard !suffix.isEmpty else { return base }
        var name = base
        // 去掉末尾的“ 数字”
        if let space = name.lastIndex(of: " "), name[name.index(after: space)...].allSatisfy(\.isNumber),
           name.index(after: space) < name.endIndex, name[..<space].hasSuffix(suffix) {
            name = String(name[..<space])
        }
        if name.hasSuffix(suffix), name.count > suffix.count { return String(name.dropLast(suffix.count)) }
        return base
    }

    /// 文件夹里第一个不重名的副本位置。ext 为 nil 时沿用原扩展名（大小写不变）
    static func copyURL(for original: URL, in folder: URL? = nil, ext: String? = nil,
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = folder ?? original.deletingLastPathComponent()
        let base = strippingCopySuffix(original.deletingPathExtension().lastPathComponent)
        let e = ext ?? original.pathExtension
        var n = 1
        while true {
            let name = baseName(base, attempt: n) + (e.isEmpty ? "" : ".\(e)")
            let url = dir.appendingPathComponent(name)
            if !exists(url) { return url }
            n += 1
        }
    }
}

/// RAW 存成什么（spec ED-33）
enum RawExportFormat: String, Sendable {
    case jpeg, heif
}

/// 存出的格式（spec ED-31、ED-33、ED-34）
struct EditTarget: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// 沿用原格式
        case same
        /// RAW 只能另存
        case raw
        /// 系统写不出原格式（参数是原格式名，例如 WebP）
        case unwritable(String)
    }

    /// 写出用的类型标识（public.jpeg 等）
    let typeIdentifier: String
    /// 新文件的扩展名
    let pathExtension: String
    let reason: Reason

    var isJPEG: Bool { typeIdentifier == "public.jpeg" }
    var isHEIF: Bool { typeIdentifier == "public.heic" }
    var isPNG: Bool { typeIdentifier == "public.png" }
    /// 能替换原图：只有沿用原格式时
    var canReplaceOriginal: Bool { reason == .same }

    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// 决定输出格式。sourceType 是 ImageIO 认出的原图类型
    static func decide(for item: MediaItem, sourceType: String?, hasAlpha: Bool, rawChoice: RawExportFormat,
                       writable: Set<String> = writableTypes) -> EditTarget {
        if item.format == .raw {
            return rawChoice == .heif
                ? EditTarget(typeIdentifier: "public.heic", pathExtension: "heic", reason: .raw)
                : EditTarget(typeIdentifier: "public.jpeg", pathExtension: "jpg", reason: .raw)
        }
        let ext = item.url.pathExtension
        var type = sourceType ?? ""
        // 扩展名是 .heif 的照片：ImageIO 可能认作 public.heif（不能写），按 HEIC 编码写，扩展名不变
        if type == "public.heif" || (["heif", "heic"].contains(ext.lowercased()) && type.isEmpty) { type = "public.heic" }
        if writable.contains(type) {
            return EditTarget(typeIdentifier: type, pathExtension: ext, reason: .same)
        }
        let name = SupportedFormats.displayName(forExtension: ext)
        return hasAlpha
            ? EditTarget(typeIdentifier: "public.png", pathExtension: "png", reason: .unwritable(name))
            : EditTarget(typeIdentifier: "public.jpeg", pathExtension: "jpg", reason: .unwritable(name))
    }

    /// 能不能只改方向标记（无损旋转，技术方案 13.6 实验 2）
    static func supportsOrientationOnly(_ typeIdentifier: String?) -> Bool {
        guard let t = typeIdentifier else { return false }
        return ["public.jpeg", "public.heic", "public.heif", "public.tiff"].contains(t)
    }
}

/// 一次编辑要写成什么样（可以跨线程传递）
struct EditPlan: Equatable, Sendable {
    let source: URL
    /// 原图按 EXIF 方向转正后的尺寸
    let imageSize: PixelSize
    /// 再顺时针转几个 90°（0–3）
    let quarterTurns: Int
    /// 转完之后的图上的裁切框
    let crop: PixelRect
    /// 最终输出尺寸
    let output: PixelSize

    var turns: Int { ((quarterTurns % 4) + 4) % 4 }
    /// 转完之后的图的尺寸
    var editedSize: PixelSize { turns % 2 == 1 ? imageSize.swapped : imageSize }
    /// 只旋转：没有裁切、没有缩小
    var isRotationOnly: Bool { crop.covers(editedSize) && output == crop.size }
    var isUnchanged: Bool { isRotationOnly && turns == 0 }
}

/// 保存失败的原因（spec ED-40）
enum EditSaveError: Error, Equatable {
    case notWritable(folder: String)
    case diskFull
    case vanished
    case other(String)

    var message: String {
        switch self {
        case .notWritable(let folder): String(localized: "「\(folder)」文件夹不允许写入。", comment: "保存失败的原因；%@ 是文件夹名")
        case .diskFull: String(localized: "磁盘空间不足。")
        case .vanished: String(localized: "原图已被移走或改名。")
        case .other(let reason): reason
        }
    }

    static func from(_ error: Error, folder: URL) -> EditSaveError {
        if let e = error as? EditSaveError { return e }
        switch SafeReplace.map(error) {
        case .notWritable: return .notWritable(folder: folder.lastPathComponent)
        case .diskFull: return .diskFull
        case .vanished: return .vanished
        case .other(let reason), .unsupported(let reason): return .other(reason)
        }
    }
}

enum EditWriter {
    /// JPEG、HEIC 的压缩质量（PRD：高质量）
    static let quality = 0.92

    /// 原图的类型、透明通道、方向（进入编辑时在后台读）
    struct SourceInfo: Equatable, Sendable {
        var typeIdentifier: String?
        var hasAlpha: Bool
        var orientation: Int
    }

    static func sourceInfo(_ url: URL) -> SourceInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return SourceInfo(typeIdentifier: nil, hasAlpha: false, orientation: 1)
        }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        return SourceInfo(typeIdentifier: CGImageSourceGetType(src) as String?,
                          hasAlpha: p[kCGImagePropertyHasAlpha] as? Bool ?? false,
                          orientation: p[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    // MARK: - 保存

    /// 另存为副本：写到 folder（默认原图所在文件夹）里第一个不重名的位置，返回新文件位置
    static func saveCopy(_ plan: EditPlan, target: EditTarget, in folder: URL? = nil) throws -> URL {
        let dir = folder ?? plan.source.deletingLastPathComponent()
        do {
            guard FileManager.default.fileExists(atPath: plan.source.path) else { throw EditSaveError.vanished }
            guard SafeReplace.isWritable(folder: dir) else { throw EditSaveError.notWritable(folder: dir.lastPathComponent) }
            let temp = SafeReplace.tempURL(for: dir.appendingPathComponent("x." + target.pathExtension))
            defer { try? FileManager.default.removeItem(at: temp) }
            try produce(plan, target: target, to: temp)
            // 换名：目标已存在时 moveItem 会失败，不会覆盖别人的文件；换个序号再试
            for _ in 0..<20 {
                let dest = EditNaming.copyURL(for: plan.source, in: dir, ext: target.pathExtension)
                do {
                    try FileManager.default.moveItem(at: temp, to: dest)
                    return dest
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            throw EditSaveError.other(String(localized: "找不到可用的文件名。"))
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    /// 另存到指定位置（「存到其他位置…」）：已有同名文件时由系统存储面板先问过用户，这里覆盖
    static func save(_ plan: EditPlan, target: EditTarget, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        do {
            guard FileManager.default.fileExists(atPath: plan.source.path) else { throw EditSaveError.vanished }
            let temp = SafeReplace.tempURL(for: dest)
            defer { try? FileManager.default.removeItem(at: temp) }
            try produce(plan, target: target, to: temp)
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: dest)
            }
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    /// 替换原图（spec ED-38）：先写好、检查好新文件，再把原图移进废纸篓，最后把新文件放到原位置。
    /// 返回原图在废纸篓里的记录（撤销用）
    static func replaceOriginal(_ plan: EditPlan, target: EditTarget, item: MediaItem) throws -> TrashEntry {
        let url = plan.source
        let dir = url.deletingLastPathComponent()
        do {
            guard target.canReplaceOriginal else { throw EditSaveError.other(String(localized: "这个格式不能替换原图。")) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw EditSaveError.vanished }
            guard SafeReplace.isWritable(folder: dir) else { throw EditSaveError.notWritable(folder: dir.lastPathComponent) }
            let temp = SafeReplace.tempURL(for: url)
            defer { try? FileManager.default.removeItem(at: temp) }
            try produce(plan, target: target, to: temp)
            let trashed = try TrashService.trash(url)
            do {
                try FileManager.default.moveItem(at: temp, to: url)
            } catch {
                // 放不进去：把原图放回原处
                try? FileManager.default.moveItem(at: trashed, to: url)
                throw error
            }
            return TrashEntry(item: item, trashedURL: trashed)
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    /// 浏览时的「保存旋转」改原图（spec ED-42）：只改方向标记，返回改之前、之后的方向值
    @discardableResult
    static func rotateInPlace(_ url: URL, quarterTurns: Int) throws -> (old: Int, new: Int) {
        let old = sourceInfo(url).orientation
        let new = ExifOrientation.rotating(old, quarterTurns: quarterTurns)
        try setOrientation(url, to: new)
        return (old, new)
    }

    /// 把方向标记改成 value（撤销「保存旋转」也用它）。临时文件 + 自检（画面数据必须完全相同）+ 原子替换
    static func setOrientation(_ url: URL, to value: Int) throws {
        let dir = url.deletingLastPathComponent()
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { throw EditSaveError.vanished }
            let info = sourceInfo(url)
            guard EditTarget.supportsOrientationOnly(info.typeIdentifier) else {
                throw EditSaveError.other(String(localized: "此格式无法只改方向"))
            }
            try SafeReplace.replace(url, keepModificationDate: false) { temp in
                try copy(url, orientation: value, to: temp)
            } verify: { temp in
                guard sourceInfo(temp).orientation == value,
                      let a = ImageIOMetadata.facts(at: url), let b = ImageIOMetadata.facts(at: temp),
                      a.width == b.width, a.height == b.height, a.count == b.count, a.auxiliary == b.auxiliary,
                      try storedPixels(url) == storedPixels(temp)
                else { throw RatingWriteError.other(String(localized: "检查没有通过，原图没有改动。")) }
            }
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    // MARK: - 写一个文件

    /// 往 temp 写编辑结果，并检查写出的尺寸
    static func produce(_ plan: EditPlan, target: EditTarget, to temp: URL) throws {
        let info = sourceInfo(plan.source)
        let sameType = target.reason == .same && info.typeIdentifier.map { $0 == target.typeIdentifier || $0 == "public.heif" } == true
        if plan.isUnchanged && sameType {
            // 没有任何改动：原样复制字节
            try FileManager.default.copyItem(at: plan.source, to: temp)
        } else if plan.isRotationOnly && sameType && EditTarget.supportsOrientationOnly(info.typeIdentifier) {
            // 只旋转：只改方向标记，画面数据不重新压缩（spec ED-32）
            try copy(plan.source, orientation: ExifOrientation.rotating(info.orientation, quarterTurns: plan.turns), to: temp)
        } else {
            let image = try render(plan)
            try encode(image, from: plan.source, isRaw: target.reason == .raw, hasAlpha: info.hasAlpha, target: target, to: temp)
        }
        // 自检：读得出来，转正后的尺寸和界面显示的一致
        guard let size = orientedSize(temp), size == plan.output else {
            throw EditSaveError.other(String(localized: "写出的文件检查没有通过。"))
        }
    }

    /// 只改方向标记地复制（CGImageDestinationCopyImageSource，不重新压缩）
    static func copy(_ source: URL, orientation: Int, to dest: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, type, CGImageSourceGetCount(src), nil) else {
            throw EditSaveError.other(String(localized: "无法读取原图。"))
        }
        let options: [CFString: Any] = [kCGImageDestinationOrientation: orientation, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(out, src, options as CFDictionary, &error) else {
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
            throw EditSaveError.other(message)
        }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// 按计划画出结果：转正 → 旋转 → 裁切 → 缩小（技术方案 13.2）
    static func render(_ plan: EditPlan) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(plan.source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw EditSaveError.other(String(localized: "无法读取原图。")) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let o = UInt32(props[kCGImagePropertyOrientation] as? Int ?? 1)
        var ci = CIImage(cgImage: raw).oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
        for _ in 0..<plan.turns { ci = ci.oriented(.right) }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        // 实际解出来的尺寸可能和标称差几个像素（RAW）：按比例换算裁切框
        let edited = plan.editedSize
        let sx = ci.extent.width / CGFloat(edited.width), sy = ci.extent.height / CGFloat(edited.height)
        let c = plan.crop
        // Core Image 原点在左下
        let rect = CGRect(x: CGFloat(c.x) * sx, y: CGFloat(edited.height - c.y - c.height) * sy,
                          width: CGFloat(c.width) * sx, height: CGFloat(c.height) * sy)
        ci = ci.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let kx = CGFloat(plan.output.width) / rect.width, ky = CGFloat(plan.output.height) / rect.height
        if abs(kx - 1) > 0.000_1 || abs(ky - 1) > 0.000_1 {
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(ky, forKey: kCIInputScaleKey)
            filter?.setValue(kx / ky, forKey: kCIInputAspectRatioKey)
            guard let scaled = filter?.outputImage else { throw EditSaveError.other(String(localized: "无法缩小图片。")) }
            ci = scaled
        }
        let space = raw.colorSpace?.model == .rgb ? raw.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = raw.bitsPerComponent > 8
        let out = CGRect(x: 0, y: 0, width: plan.output.width, height: plan.output.height)
        guard let image = ciContext.createCGImage(ci, from: out, format: deep ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw EditSaveError.other(String(localized: "无法生成图片。"))
        }
        return image
    }

    /// 编码写出：沿用原图的拍摄信息（Exif、GPS、TIFF、IPTC），方向改成 1，Exif 像素尺寸改成新值。
    /// 不复制 XMP（里面可能有其他软件的裁切、调色参数，放到新图上会错，技术方案 13.3）
    static func encode(_ image: CGImage, from source: URL, isRaw: Bool, hasAlpha: Bool, target: EditTarget, to dest: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, target.typeIdentifier as CFString, 1, nil)
        else { throw EditSaveError.other(String(localized: "无法写入这个格式。")) }
        var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        for key in ["PixelWidth", "PixelHeight", "Depth", "HasAlpha", "ColorModel", "ProfileName", "IsFloat", "IsIndexed",
                    "{DNG}", "{CIFF}", "{Raw}", "{HEICS}", "{GIF}", "{PNG}", "{ExifAux}", "{8BIM}", "{MakerFujiFilm}"] {
            p[key] = nil
        }
        if isRaw { for key in p.keys where key.hasPrefix("{Maker") { p[key] = nil } }
        p[kCGImagePropertyOrientation as String] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFCompression as String] = nil
            tiff[kCGImagePropertyTIFFPhotometricInterpretation as String] = nil
            p[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = image.width
            exif[kCGImagePropertyExifPixelYDimension as String] = image.height
            p[kCGImagePropertyExifDictionary as String] = exif
        }
        p[kCGImageDestinationLossyCompressionQuality as String] = quality
        // 原图没有透明通道：去掉渲染时加上的 alpha（PNG、TIFF 不会平白变大）
        let final = hasAlpha && !target.isJPEG ? image : (opaque(image) ?? image)
        CGImageDestinationAddImage(out, final, p as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw EditSaveError.other(String(localized: "无法写入这个格式。")) }
    }

    /// 去掉 alpha 通道的副本
    private static func opaque(_ image: CGImage) -> CGImage? {
        let deep = image.bitsPerComponent > 8
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: deep ? 16 : 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - 检查

    /// 文件按方向转正后的像素尺寸
    static func orientedSize(_ url: URL) -> PixelSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
    }

    /// 未转正的像素数据（判断画面有没有被重新压缩）
    static func storedPixels(_ url: URL) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = image.dataProvider?.data as Data? else {
            throw EditSaveError.other(String(localized: "无法读取原图。"))
        }
        return data
    }
}
