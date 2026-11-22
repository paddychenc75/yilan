import CoreGraphics
import Foundation
import ImageIO

/// 导出文件的命名（spec C6-06）：「原名 导出.jpg」/「name exported.jpg」，重名时「原名 导出 2.jpg」…
enum ExportNaming {
    /// 不带扩展名的文件名；n 从 1 开始，1 不带序号
    static func baseName(_ base: String, attempt n: Int) -> String {
        n <= 1 ? String(localized: "\(base) 导出", comment: "RAW 导出为 JPEG 的文件名（不含扩展名）；%@ 是原文件名")
            : String(localized: "\(base) 导出 \(n)", comment: "RAW 导出为 JPEG 的文件名，重名时带序号；%1$@ 是原文件名，%2$lld 是序号")
    }

    /// 和 RAW 同一个文件夹里第一个不重名的位置，绝不指向已有的文件
    static func exportURL(for raw: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = raw.deletingLastPathComponent()
        let base = raw.deletingPathExtension().lastPathComponent
        let ext = EditTarget.rawExport.pathExtension
        var n = 1
        while true {
            let url = dir.appendingPathComponent(baseName(base, attempt: n) + ".\(ext)")
            if !exists(url) { return url }
            n += 1
        }
    }
}

/// 把一张 RAW 原样导出成 JPEG（spec C6-04 ~ C6-06、C6-11）。
/// 只读 RAW，不写它（字节和修改时间都不变）；先写临时文件，检查通过再改成正式名字；失败时什么都不留下。
/// 同步函数，必须在后台线程调用
enum RawExport {
    struct Written: Equatable, Sendable {
        let url: URL
        /// 导出的是相机预览图（系统解不了这张 RAW，spec C6-05）
        let cameraPreview: Bool
    }

    /// cameraPreview：已经知道这张 RAW 处在相机预览图状态（spec C1-17，只记在内存里），直接取内嵌 JPEG
    static func export(_ item: MediaItem, cameraPreview knownPreview: Bool) throws -> Written {
        let raw = item.url
        let dir = raw.deletingLastPathComponent()
        do {
            guard FileManager.default.fileExists(atPath: raw.path) else { throw EditSaveError.vanished }
            guard SafeReplace.isWritable(folder: dir) else { throw EditSaveError.notWritable(folder: dir.lastPathComponent) }
            let temp = SafeReplace.tempURL(for: dir.appendingPathComponent("x." + EditTarget.rawExport.pathExtension))
            // 成功时临时文件已经改名，这里删不到东西；失败时删掉写了一半的（spec C6-11）
            defer { try? FileManager.default.removeItem(at: temp) }
            var usedPreview = knownPreview
            let full = knownPreview ? false : try writeFull(raw, to: temp)
            if !full {
                // 系统完整解码不了（spec C1-02 同样的判断）：改为导出相机预览图
                try? FileManager.default.removeItem(at: temp)
                try writeCameraPreview(item, to: temp)
                usedPreview = true
            }
            // 换名：目标已存在时 moveItem 会失败，不会覆盖别人的文件；换个序号再试（spec C6-06）
            for _ in 0..<20 {
                let dest = ExportNaming.exportURL(for: raw)
                do {
                    try FileManager.default.moveItem(at: temp, to: dest)
                    return Written(url: dest, cameraPreview: usedPreview)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
            }
            throw EditSaveError.other(String(localized: "找不到可用的文件名。"))
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    /// 完整解码的全尺寸画面，按文件记录的方向转正（spec C6-04）。系统解不了时返回 false（什么都没写）
    static func writeFull(_ raw: URL, to temp: URL) throws -> Bool {
        guard let size = EditWriter.orientedSize(raw), size.width > 0, size.height > 0 else { return false }
        // 不带浏览时临时转的角度：不旋转、不裁切、不缩小
        let plan = EditPlan(source: raw, imageSize: size, quarterTurns: 0, crop: PixelRect(size: size), output: size)
        guard let image = try? EditWriter.render(plan) else { return false }
        try EditWriter.encode(image, from: raw, isRaw: true, hasAlpha: false, target: EditTarget.rawExport, to: temp)
        guard EditWriter.orientedSize(temp) == size else {
            throw EditSaveError.other(String(localized: "写出的文件检查没有通过。"))
        }
        return true
    }

    /// 相机预览图（文件里最大的内嵌 JPEG），方向和界面上显示的相同（spec C6-05、C1-04）
    static func writeCameraPreview(_ item: MediaItem, to temp: URL) throws {
        let shown: DecodedImage
        do {
            shown = try ImageDecoder.decodeCameraPreview(item, maxPixel: nil)
        } catch let failure as DecodeFailure {
            switch failure.kind {
            case .missing: throw EditSaveError.vanished
            default: throw EditSaveError.other(failure.reason)
            }
        }
        let image = shown.image
        try EditWriter.encode(image, properties: properties(item.url), isRaw: true, hasAlpha: false,
                              target: EditTarget.rawExport, to: temp)
        guard EditWriter.orientedSize(temp) == PixelSize(width: image.width, height: image.height) else {
            throw EditSaveError.other(String(localized: "写出的文件检查没有通过。"))
        }
    }

    /// 拍摄信息：系统读得出 RAW 的就用 RAW 的；读不出（系统不认识这种文件）时用内嵌 JPEG 自己带的（同 spec C1-16c）
    static func properties(_ raw: URL) -> [String: Any] {
        if let src = CGImageSourceCreateWithURL(raw as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(src) > 0,
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           p[kCGImagePropertyExifDictionary as String] != nil {
            return p
        }
        guard let info = EmbeddedPreview.largestInfo(url: raw) else { return [:] }
        return Dictionary(info.properties.map { ($0.key as String, $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}
