import Foundation

/// 读写星级的唯一入口（技术方案 2.1）：其他模块不直接碰 XMP 和用户文件。
/// 全部是同步函数，必须在后台线程调用
enum RatingFileIO {
    /// 这个文件能怎样写星级
    enum Kind: Equatable, Sendable {
        /// RAW、视频、GIF、WebP、SVG、BMP：只能用小文件
        case sidecarOnly
        case jpeg
        case png
        /// HEIC / HEIF / TIFF：ImageIO 无损合并
        case imageIO
    }

    /// v0.3 只给图片评星，视频不能评（产品 2026-11-18 改定）
    static func isRatable(_ item: MediaItem) -> Bool { item.kind == .image }

    static func kind(for item: MediaItem) -> Kind {
        guard item.format == .standard else { return .sidecarOnly }
        switch item.url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif", "tif", "tiff": return .imageIO
        default: return .sidecarOnly   // WebP、BMP
        }
    }

    /// ImageIO 能不能读内部星级（视频、SVG 不能）
    private static func hasEmbeddedMetadata(_ item: MediaItem) -> Bool {
        item.format == .standard || item.format == .raw || item.format == .gif
    }

    // MARK: - 读

    /// 读一个文件的星级（spec R4-01 ~ R4-03）
    static func read(_ item: MediaItem, sidecars: SidecarIndex) -> RatingInfo {
        var info = RatingInfo.unrated
        // 视频旁边别的软件写的小文件：不读、不改
        guard isRatable(item) else { return info }
        if let url = sidecars.readURL(for: item), let data = try? Data(contentsOf: url),
           let packet = try? XMPPacket(data: data) {
            info.sidecarURL = url
            info.sidecar = packet.rating
        }
        let isDNG = item.url.pathExtension.lowercased() == "dng"
        // RAW 有带星级的小文件时不读内部（省下读 RAW 头的时间）；DNG 例外：两处都读，取较新的
        let needEmbedded = !(item.format == .raw && info.sidecar != nil) || isDNG
        if needEmbedded, hasEmbeddedMetadata(item) { info.embedded = ImageIOMetadata.rating(at: item.url) }
        if isDNG, let side = info.sidecarURL, info.sidecar != nil, info.embedded != nil {
            let dngDate = modificationDate(item.url)
            let sideDate = modificationDate(side)
            info.value = RatingValue.display(dngWinner(sidecar: info.sidecar, sidecarDate: sideDate,
                                                       embedded: info.embedded, embeddedDate: dngDate))
        } else {
            info.value = RatingValue.display(info.sidecar ?? info.embedded)
        }
        return info
    }

    /// DNG：内嵌和小文件都有星级时取较新的那个（产品决定 1）；修改时间相同算小文件赢（一览写的就是小文件）
    static func dngWinner(sidecar: Int?, sidecarDate: Date?, embedded: Int?, embeddedDate: Date?) -> Int? {
        guard let sidecar else { return embedded }
        guard let embedded else { return sidecar }
        if let e = embeddedDate, let s = sidecarDate, e > s { return embedded }
        return sidecar
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - 写

    struct WriteResult: Equatable, Sendable {
        enum Location: Equatable, Sendable { case embedded, sidecar(URL) }
        var location: Location
        /// 这次新建的小文件
        var createdSidecar: URL?
        /// 这次删掉的小文件（一览建的、清除后不剩别的信息）
        var removedSidecar: URL?
        /// 这次改动过的文件（给文件夹同步的账本用）
        var touched: [URL] = []

        /// 改动后的文件状态（大小、修改时间；删掉的文件 exists = false）
        func stamps() -> [FileStamp] { touched.map(FileStamp.init(url:)) }
    }

    /// 把星级写进文件（value 0 = 清除）。失败抛 RatingWriteError
    static func write(_ value: Int, for item: MediaItem, mode: RatingStorageMode, sidecars: SidecarIndex) throws -> WriteResult {
        precondition((0...5).contains(value))
        guard isRatable(item) else { throw RatingWriteError.unsupported("视频不能评星") }
        guard FileManager.default.fileExists(atPath: item.url.path) else { throw RatingWriteError.vanished }
        let kind = kind(for: item)
        let existingSidecar = sidecars.readURL(for: item).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if kind != .sidecarOnly, mode == .embedded {
            do {
                try writeEmbedded(value, to: item.url, kind: kind)
                var result = WriteResult(location: .embedded, touched: [item.url])
                // 已经有带星级的小文件：也改成同一个值，免得旧小文件压住新值（spec PD-05），不新建
                if let existingSidecar, let data = try? Data(contentsOf: existingSidecar),
                   let packet = try? XMPPacket(data: data), packet.rating != nil {
                    let side = try writeSidecar(value, for: item, at: existingSidecar, sidecars: sidecars)
                    result.removedSidecar = side.removedSidecar
                    result.touched += side.touched
                }
                return result
            } catch RatingWriteError.unsupported(let reason) {
                // 不能无损写进这个文件：改用小文件（spec S-21、S-22）
                Log.app.info("改用 .xmp 小文件：\(item.name, privacy: .public)，\(reason, privacy: .public)")
            }
        }
        return try writeSidecar(value, for: item, at: existingSidecar ?? sidecars.writeURL(for: item), sidecars: sidecars)
    }

    /// 写进文件内部：临时文件 + 自检 + 原子替换 + 恢复修改时间
    /// 写入后是否恢复原修改时间。调研报告指出这可能让 Lightroom / Bridge 发现不了外部修改（推断，待实测），
    /// 实测后需要改时只改这一处
    static let keepsModificationDate = true

    static func writeEmbedded(_ value: Int, to url: URL, kind: Kind) throws {
        let originalFacts = ImageIOMetadata.facts(at: url)
        let originalXMP = ImageIOMetadata.xmpPaths(at: url)
        let microsoft = ImageIOMetadata.hasMicrosoftRating(at: url)
        try SafeReplace.replace(url, keepModificationDate: keepsModificationDate) { temp in
            switch kind {
            case .jpeg, .png:
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                let edit: (XMPPacket) -> Void = { $0.setRating(value == 0 ? nil : value) }
                let out = kind == .jpeg ? try JPEGXMPWriter.rewrite(data, edit: edit) : try PNGXMPWriter.rewrite(data, edit: edit)
                // 已有的 Exif Rating / RatingPercent 原地改成同一个值（不新增）
                var bytes = [UInt8](out)
                try ExifRatingPatcher.patch(&bytes, kind: kind, rating: value)
                try Data(bytes).write(to: temp)
            case .imageIO:
                // HEIC / TIFF 删不掉这一项，清除写 0（spec S-13）；已有的 MicrosoftPhoto:Rating 一起改
                try ImageIOMetadata.write(rating: value, from: url, to: temp,
                                          microsoftPercent: microsoft ? XMPPacket.percent(for: value) : nil)
                var bytes = [UInt8](try Data(contentsOf: temp))
                if try ExifRatingPatcher.patch(&bytes, kind: kind, rating: value) { try Data(bytes).write(to: temp) }
            case .sidecarOnly:
                throw RatingWriteError.unsupported("只能用小文件")
            }
        } verify: { temp in
            try verifyEmbedded(original: url, temp: temp, kind: kind, value: value,
                               originalFacts: originalFacts, originalXMP: originalXMP)
        }
    }

    /// 自检（技术方案 3.2）：不合格抛 unsupported，调用方改用小文件
    static func verifyEmbedded(original: URL, temp: URL, kind: Kind, value: Int,
                               originalFacts: ImageIOMetadata.Facts?, originalXMP: Set<String>) throws {
        guard RatingValue.display(ImageIOMetadata.rating(at: temp)) == value else {
            throw RatingWriteError.unsupported("读回的星级不对")
        }
        guard let after = ImageIOMetadata.facts(at: temp), after == originalFacts else {
            throw RatingWriteError.unsupported("图片尺寸、数量或辅助图变了")
        }
        // 不比较星级本身和 ImageIO 自己加的标记（iio:hasXMP 等）
        // 不比较星级本身（xmp:Rating、MicrosoftPhoto:Rating、Exif 映射出的 Rating）和 ImageIO 自己加的标记
        let ignored: (String) -> Bool = { $0.contains(":Rating=") || $0.contains(":RatingPercent=") || $0.hasPrefix("iio:") }
        guard originalXMP.filter({ !ignored($0) }).isSubset(of: ImageIOMetadata.xmpPaths(at: temp)) else {
            throw RatingWriteError.unsupported("原有的 XMP 信息少了")
        }
        if kind == .jpeg || kind == .png {
            // 预期：原文件只有 Exif 里那几个星级字节变了
            var expected = [UInt8](try Data(contentsOf: original, options: .alwaysMapped))
            try ExifRatingPatcher.patch(&expected, kind: kind, rating: value)
            let a = Data(expected)
            let b = try Data(contentsOf: temp, options: .alwaysMapped)
            let same = kind == .jpeg
                ? try JPEGXMPWriter.bytesOutsideXMP(a) == JPEGXMPWriter.bytesOutsideXMP(b)
                : try PNGXMPWriter.bytesOutsideXMP(a) == PNGXMPWriter.bytesOutsideXMP(b)
            guard same else { throw RatingWriteError.unsupported("XMP 以外的字节变了") }
        }
    }

    /// 写 .xmp 小文件（spec S-10 ~ S-12）
    static func writeSidecar(_ value: Int, for item: MediaItem, at url: URL, sidecars: SidecarIndex) throws -> WriteResult {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let packet: XMPPacket
        if exists {
            do {
                packet = try XMPPacket(data: Data(contentsOf: url))
            } catch let e as XMPPacket.ParseError {
                // 别人的小文件坏了：不覆盖它
                throw RatingWriteError.other("无法解析 \(url.lastPathComponent)：\(e)")
            } catch {
                throw SafeReplace.map(error)
            }
        } else {
            // 新建的小文件写上照片的扩展名（photoshop:SidecarForExtension，产品决定 2）
            packet = XMPPacket.makeNew(sidecarFor: item.url.pathExtension)
        }
        let before = exists ? packet.flattened() : []
        if value > 0 {
            packet.setRating(value)
        } else {
            // 文件内部还有星级（RAW 机内评星、或“一律小文件”模式下图片里原有的）：写 0，保证清除后显示未评星
            let embedded = hasEmbeddedMetadata(item) ? RatingValue.display(ImageIOMetadata.rating(at: item.url)) : 0
            packet.setRating(embedded > 0 ? 0 : nil)
        }
        let removable = packet.isCreatedByYilan && !packet.hasPropertiesOtherThanRating && packet.rating == nil
        if removable {
            guard exists else { return WriteResult(location: .sidecar(url)) }
            do { try FileManager.default.removeItem(at: url) } catch { throw SafeReplace.map(error) }
            return WriteResult(location: .sidecar(url), removedSidecar: url, touched: [url])
        }
        // 别人的信息一项不能少
        if exists {
            let isRating: (String) -> Bool = { $0.hasPrefix("/\(XMPPacket.xmpNS)|Rating=") }
            guard before.filter({ !isRating($0) }).isSubset(of: packet.flattened()) else {
                throw RatingWriteError.other("改写 \(url.lastPathComponent) 会丢失信息")
            }
        }
        try SafeReplace.write(packet.sidecarData(), to: url)
        return WriteResult(location: .sidecar(url), createdSidecar: exists ? nil : url, touched: [url])
    }
}

/// 一个文件某一刻的状态：文件夹同步据此认出“一览自己刚写过的”文件（技术方案 4.5）
struct FileStamp: Hashable, Sendable {
    let path: String
    let exists: Bool
    let size: Int64
    let modificationDate: Date

    init(url: URL) {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        path = url.resolvingSymlinksInPath().path
        exists = v != nil && FileManager.default.fileExists(atPath: url.path)
        size = Int64(v?.fileSize ?? 0)
        modificationDate = v?.contentModificationDate ?? .distantPast
    }

    init(path: String, exists: Bool, size: Int64, modificationDate: Date) {
        self.path = path
        self.exists = exists
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// 一览自己写过的文件：扫描到同样状态时不算“被其他程序修改”
struct OwnWriteLedger: Sendable {
    private var stamps: [String: FileStamp] = [:]

    mutating func record(_ list: [FileStamp]) {
        for s in list { stamps[URL(fileURLWithPath: s.path).resolvingSymlinksInPath().path] = s }
    }

    /// 这个状态是一览自己写出来的（只认一次，之后再变就是别人改的）
    mutating func consume(path: String, size: Int64, modificationDate: Date) -> Bool {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let s = stamps[key], s.exists, s.size == size,
              abs(s.modificationDate.timeIntervalSince(modificationDate)) < 0.001 else { return false }
        stamps[key] = nil
        return true
    }

    /// 这个文件是一览自己删掉的
    mutating func consumeRemoval(path: String) -> Bool {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let s = stamps[key], !s.exists else { return false }
        stamps[key] = nil
        return true
    }

    mutating func removeAll() { stamps.removeAll() }
    var isEmpty: Bool { stamps.isEmpty }
}
