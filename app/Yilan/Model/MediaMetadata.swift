import AVFoundation
import Foundation
import ImageIO

/// 信息面板要显示的原始数据（读文件得到，还没格式化）
struct MediaMetadata: Sendable, Equatable {
    var url: URL
    var kind: MediaKind
    /// 状态行里的格式名（HEIF、JPEG、MOV…）
    var formatName: String
    var fileSize: Int64
    var created: Date?
    var modified: Date?
    /// 图片像素尺寸（已按方向转正）；视频为画面分辨率
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// 系统读不到这张 RAW 的像素尺寸时（实测等同于系统解不了它），文件里最大的内嵌 JPEG 的尺寸（已按方向转正）。
    /// 图标视图靠它在不打开大图的情况下知道「这张会显示相机预览图」（spec C1-16）
    var cameraPreviewSize: CGSize?
    /// 色彩描述文件，例如 Display P3、sRGB
    var colorProfile: String?
    /// 拍摄信息；没有任何相机数据时为 nil
    var capture: CaptureInfo?
    var video: VideoInfo?
    var location: GeoLocation?
    /// false：只填了文件的基本信息（EXIF 还在后台读）
    var isComplete = false

    struct CaptureInfo: Sendable, Equatable {
        /// 已整理成“2026-10-14 11:20”
        var date: String?
        var camera: String?
        var lens: String?
        var fNumber: Double?
        var exposureTime: Double?
        var iso: Int?
        /// 焦距（mm）；有 35mm 等效焦距时用等效值，和“照片”App 一致
        var focalLength: Double?
        var exposureBias: Double?
        var flashFired: Bool?
        var whiteBalanceManual: Bool?

        var isEmpty: Bool {
            date == nil && camera == nil && lens == nil && fNumber == nil && exposureTime == nil && iso == nil
                && focalLength == nil && exposureBias == nil && flashFired == nil && whiteBalanceManual == nil
        }
        var hasExposureTiles: Bool { fNumber != nil || exposureTime != nil || iso != nil || focalLength != nil }
    }

    struct VideoInfo: Sendable, Equatable {
        var duration: Double?
        /// 视频编码的 FourCC（avc1、hvc1…）
        var codec: String?
        var frameRate: Double?
        /// 码率（bit/s）
        var bitrate: Double?
        var audioCodec: String?
        var audioChannels: Int?
        var audioSampleRate: Double?
    }

    struct GeoLocation: Sendable, Equatable {
        /// 北纬为正、东经为正
        var latitude: Double
        var longitude: Double
        /// 海拔（米），海平面以下为负
        var altitude: Double?
    }
}

/// 读取信息面板的数据。全部在后台线程调用（读 EXIF、打开视频都会碰磁盘）
enum MetadataReader {
    /// 只用文件夹扫描时已有的数据，不读文件：切换文件时先显示“文件”组
    static func basic(_ item: MediaItem) -> MediaMetadata {
        MediaMetadata(url: item.url, kind: item.kind, formatName: item.formatName, fileSize: item.fileSize,
                      created: nil, modified: item.modificationDate)
    }

    static func read(_ item: MediaItem) async -> MediaMetadata {
        var meta = basic(item)
        let values = try? item.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        meta.created = values?.creationDate
        meta.modified = values?.contentModificationDate ?? item.modificationDate
        if let size = values?.fileSize { meta.fileSize = Int64(size) }
        if item.kind == .video {
            await readVideo(item.url, into: &meta)
        } else {
            readImage(item.url, into: &meta)
            if item.format == .raw, meta.pixelWidth == nil, let preview = EmbeddedPreview.largestInfo(url: item.url) {
                meta.cameraPreviewSize = preview.size
                // 系统读不出拍摄信息时（旧系统上的富士压缩 RAW、适马 X3F），用内嵌 JPEG 自己带的；像素尺寸和色彩描述是预览图的，不算原片的
                if meta.capture == nil {
                    var fromPreview = meta
                    apply(imageProperties: preview.properties, to: &fromPreview)
                    meta.capture = fromPreview.capture
                    if meta.location == nil { meta.location = fromPreview.location }
                }
            }
        }
        meta.isComplete = true
        return meta
    }

    // MARK: - 图片

    static func readImage(_ url: URL, into meta: inout MediaMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return }
        apply(imageProperties: props, to: &meta)
    }

    /// 把 ImageIO 的属性字典整理进 meta（单独拿出来，方便测试）
    static func apply(imageProperties props: [CFString: Any], to meta: inout MediaMetadata) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let w = number(props[kCGImagePropertyPixelWidth]), let h = number(props[kCGImagePropertyPixelHeight]) {
            // 方向 5–8 是转了 90°：显示出来的宽高互换
            let orientation = number(props[kCGImagePropertyOrientation]) ?? 1
            let swapped = (5...8).contains(Int(orientation))
            meta.pixelWidth = Int(swapped ? h : w)
            meta.pixelHeight = Int(swapped ? w : h)
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            meta.colorProfile = InfoFormat.profileName(profile)
        }

        var capture = MediaMetadata.CaptureInfo()
        capture.date = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(InfoFormat.exifDate)
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        capture.camera = InfoFormat.cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String, model: model)
        capture.lens = (exif[kCGImagePropertyExifLensModel] as? String).map { InfoFormat.lensName($0, model: model) }
        capture.fNumber = number(exif[kCGImagePropertyExifFNumber]).flatMap { $0 > 0 ? $0 : nil }
        capture.exposureTime = number(exif[kCGImagePropertyExifExposureTime]).flatMap { $0 > 0 ? $0 : nil }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any], let iso = isos.first.flatMap(number), iso > 0 {
            capture.iso = Int(iso)
        }
        let focal35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).flatMap { $0 > 0 ? $0 : nil }
        capture.focalLength = focal35 ?? number(exif[kCGImagePropertyExifFocalLength]).flatMap { $0 > 0 ? $0 : nil }
        capture.exposureBias = number(exif[kCGImagePropertyExifExposureBiasValue])
        if let flash = number(exif[kCGImagePropertyExifFlash]) { capture.flashFired = Int(flash) & 1 == 1 }
        if let wb = number(exif[kCGImagePropertyExifWhiteBalance]) { capture.whiteBalanceManual = Int(wb) == 1 }
        meta.capture = capture.isEmpty ? nil : capture

        if let lat = number(gps[kCGImagePropertyGPSLatitude]), let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            var altitude = number(gps[kCGImagePropertyGPSAltitude])
            if let a = altitude, number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -a }
            meta.location = .init(latitude: south ? -lat : lat, longitude: west ? -lon : lon, altitude: altitude)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    // MARK: - 视频

    static func readVideo(_ url: URL, into meta: inout MediaMetadata) async {
        let asset = AVURLAsset(url: url)
        var info = MediaMetadata.VideoInfo()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        var totalRate: Double = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform, fps, rate, formats) = try? await track.load(
               .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            meta.pixelWidth = Int(abs(shown.width).rounded())
            meta.pixelHeight = Int(abs(shown.height).rounded())
            if fps > 0 { info.frameRate = Double(fps) }
            totalRate += Double(rate)
            if let format = formats.first {
                info.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let (rate, formats) = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            totalRate += Double(rate)
            if let format = formats.first {
                info.audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(format))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    info.audioChannels = Int(asbd.mChannelsPerFrame)
                    info.audioSampleRate = asbd.mSampleRate
                }
            }
        }
        // 轨道没有给码率时按文件大小估算
        if totalRate > 0 {
            info.bitrate = totalRate
        } else if let d = info.duration, d > 0, meta.fileSize > 0 {
            info.bitrate = Double(meta.fileSize) * 8 / d
        }
        meta.video = info

        // 拍摄信息：手机拍的视频带拍摄时间、机型和坐标
        let items = (try? await asset.load(.metadata)) ?? []
        var capture = MediaMetadata.CaptureInfo()
        if let item = (try? await asset.load(.creationDate)) ?? nil, let date = try? await item.load(.dateValue) {
            capture.date = InfoFormat.captureDate(date)
        }
        let model = await string(items, [.quickTimeMetadataModel, .commonIdentifierModel])
        let make = await string(items, [.quickTimeMetadataMake, .commonIdentifierMake])
        capture.camera = InfoFormat.cameraName(make: make, model: model)
        meta.capture = capture.isEmpty ? nil : capture
        if let iso6709 = await string(items, [.quickTimeMetadataLocationISO6709, .commonIdentifierLocation]) {
            meta.location = InfoFormat.parseISO6709(iso6709)
        }
    }

    private static func string(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for id in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
