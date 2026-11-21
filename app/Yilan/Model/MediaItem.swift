import Foundation

/// 媒体大类：图片或视频
enum MediaKind: String, Sendable, Hashable {
    case image
    case video
}

/// 解码方式不同的几类文件
enum MediaFormat: Sendable, Hashable {
    case standard   // JPEG / PNG / HEIF / WebP / TIFF / BMP
    case raw        // 相机 RAW
    case gif
    case svg
    case video
}

/// PRD 第 9 节列出的全部支持格式
enum SupportedFormats {
    /// v0.5 新增（spec C3-01）：srw 起的各项。它们和原来的 8 种一样是 .raw：星级只写旁边的小文件，编辑只能另存
    static let raw: Set<String> = ["cr2", "cr3", "nef", "arw", "raf", "rw2", "orf", "dng",
                                   "srw", "pef", "3fr", "fff", "iiq", "x3f", "erf", "mrw", "srf", "sr2",
                                   "crw", "nrw", "rwl", "dcr", "kdc", "mef", "mos", "gpr"]
    /// hif：索尼等相机直接拍的 HEIF（spec C4-01）
    static let standardImages: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "hif", "tif", "tiff", "bmp"]
    static let videos: Set<String> = ["mp4", "m4v", "mov"]

    static let allExtensions: Set<String> =
        raw.union(standardImages).union(videos).union(["gif", "svg"])

    /// 根据扩展名判断格式；不支持的返回 nil（扩展名不区分大小写）
    static func format(forExtension ext: String) -> MediaFormat? {
        let e = ext.lowercased()
        if standardImages.contains(e) { return .standard }
        if raw.contains(e) { return .raw }
        if videos.contains(e) { return .video }
        if e == "gif" { return .gif }
        if e == "svg" { return .svg }
        return nil
    }

    /// 状态行里显示的格式名
    static func displayName(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "JPEG"
        case "png": "PNG"
        case "webp": "WebP"
        case "heic", "heif", "hif": "HEIF"
        case "tif", "tiff": "TIFF"
        case "bmp": "BMP"
        case "gif": "GIF"
        case "svg": "SVG"
        case "cr2", "cr3", "crw": "Canon RAW"
        case "nef", "nrw": "Nikon RAW"
        case "arw", "srf", "sr2": "Sony RAW"
        case "srw": "Samsung RAW"
        case "pef": "Pentax RAW"
        case "3fr", "fff": "Hasselblad RAW"
        case "iiq": "Phase One RAW"
        case "x3f": "Sigma RAW"
        case "erf": "Epson RAW"
        case "mrw": "Minolta RAW"
        case "rwl": "Leica RAW"
        case "dcr", "kdc": "Kodak RAW"
        case "mef": "Mamiya RAW"
        case "mos": "Leaf RAW"
        case "gpr": "GoPro RAW"
        case "raf": "Fujifilm RAW"
        case "rw2": "Panasonic RAW"
        case "orf": "Olympus RAW"
        case "dng": "DNG"
        case "mp4": "MP4"
        case "m4v": "M4V"
        case "mov": "MOV"
        default: ext.uppercased()
        }
    }
}

/// 文件夹里的一个文件
struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let format: MediaFormat
    let fileSize: Int64
    let modificationDate: Date
    /// 文件编号（同一个卷上改名不变）：文件夹同步时用来识别改名
    let fileID: UInt64?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: MediaKind { format == .video ? .video : .image }
    var formatName: String { SupportedFormats.displayName(forExtension: url.pathExtension) }

    init(url: URL, format: MediaFormat, fileSize: Int64, modificationDate: Date, fileID: UInt64? = nil) {
        self.url = url
        self.format = format
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.fileID = fileID
    }
}

/// 数字、大小、时长都用系统格式化，跟着当前语言和地区走（例如 1,000、3.9 MB、1:08）
enum Formatting {
    /// 文件大小，例如 3.9 MB、860 KB；0 显示“0 字节 / 0 bytes”
    static func fileSize(_ bytes: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let units: ByteCountFormatStyle.Units = bytes == 0 ? .bytes : [.kb, .mb, .gb]
        return bytes.formatted(.byteCount(style: .file, allowedUnits: units, spellsOutZero: false).locale(locale))
    }

    /// 时长，例如 0:42、1:08:03（四舍五入到秒）
    static func duration(_ seconds: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard seconds.isFinite, seconds >= 0 else { return clockText(0, locale: locale) }
        return clockText(Int(seconds.rounded()), locale: locale)
    }

    /// 播放位置：向下取整（0:59.9 仍显示 0:59，和系统播放器一致）
    static func clock(_ seconds: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard seconds.isFinite, seconds >= 0 else { return clockText(0, locale: locale) }
        return clockText(Int(seconds.rounded(.down)), locale: locale)
    }

    private static func clockText(_ seconds: Int, locale: Locale) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern).locale(locale))
    }

    /// 普通数量，例如 1,000
    static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }
}
