import Foundation

/// 文件里已有的 Exif Rating（0x4746）和 RatingPercent（0x4749）原地改成和星级一致（调研报告 B、产品决定 4）。
/// 只改值本身：类型是 SHORT / LONG、个数是 1（值直接放在目录项里）时按原字节序覆盖那 2 或 4 个字节，别的字节一个不动。
/// 没有这两个标签就什么都不做（不新增）；写法不是这样的（放不下、类型不对）就报 unsupported，调用方改用小文件
enum ExifRatingPatcher {
    static let ratingTag: UInt16 = 0x4746
    static let percentTag: UInt16 = 0x4749

    /// 找到文件里 Exif 的 TIFF 头位置（JPEG：Exif APP1；PNG：eXIf 块；TIFF：文件开头；HEIC：“Exif\0\0”后面）
    static func tiffHeaders(in b: [UInt8], kind: RatingFileIO.Kind) -> [Int] {
        switch kind {
        case .jpeg:
            var i = 2
            while i + 4 <= b.count, b[i] == 0xFF {
                let m = b[i + 1]
                if m == 0xDA || m == 0xD9 { break }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if m == 0xE1, i + 10 <= b.count, Array(b[(i + 4)..<(i + 10)]) == Array("Exif\0\0".utf8) { return [i + 10] }
                i += 2 + len
            }
            return []
        case .png:
            var i = 8
            while i + 12 <= b.count {
                let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                if String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) == "eXIf" { return [i + 8] }
                i += 12 + len
            }
            return []
        case .imageIO:
            if b.count > 4, (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return [0] }   // TIFF
            // HEIC：Exif 项里是 4 字节偏移 + “Exif\0\0” + TIFF 头
            let marker = Array("Exif\0\0".utf8)
            var i = 0
            while i + 10 < b.count {
                if b[i] == marker[0], Array(b[i..<(i + 6)]) == marker,
                   (b[i + 6] == 0x49 && b[i + 7] == 0x49) || (b[i + 6] == 0x4D && b[i + 7] == 0x4D) { return [i + 6] }
                i += 1
            }
            return []
        case .sidecarOnly:
            return []
        }
    }

    /// 读出 IFD0 里这两个标签当前的值（测试和检查用）
    static func values(in b: [UInt8], tiffStart t: Int) -> [UInt16: Int] {
        var out: [UInt16: Int] = [:]
        _ = try? walk(b, t) { tag, type, valueOffset, little in
            out[tag] = type == 3 ? Int(read16(b, valueOffset, little)) : Int(read32(b, valueOffset, little))
        }
        return out
    }

    /// 改写；返回是否改动了
    @discardableResult
    static func patch(_ b: inout [UInt8], kind: RatingFileIO.Kind, rating: Int) throws -> Bool {
        var changed = false
        for t in tiffHeaders(in: b, kind: kind) {
            var edits: [(Int, Int, Bool, Int)] = []   // 位置、字节数、小端、值
            try walk(b, t) { tag, type, valueOffset, little in
                let value = tag == ratingTag ? rating : XMPPacket.percent(for: rating)
                edits.append((valueOffset, type == 3 ? 2 : 4, little, value))
            }
            for (offset, size, little, value) in edits {
                let bytes: [UInt8] = size == 2
                    ? (little ? [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] : [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
                    : (little ? [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), 0, 0] : [0, 0, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
                if Array(b[offset..<(offset + size)]) != bytes {
                    b.replaceSubrange(offset..<(offset + size), with: bytes)
                    changed = true
                }
            }
        }
        return changed
    }

    /// 走一遍 IFD0，遇到这两个标签就回调（标签、类型、值所在位置、是否小端）；写法不安全时抛 unsupported
    private static func walk(_ b: [UInt8], _ t: Int, _ found: (UInt16, Int, Int, Bool) throws -> Void) throws {
        guard t + 8 <= b.count else { return }
        let little = b[t] == 0x49
        let ifd = t + Int(read32(b, t + 4, little))
        guard ifd + 2 <= b.count else { return }
        let count = Int(read16(b, ifd, little))
        for k in 0..<count {
            let e = ifd + 2 + 12 * k
            guard e + 12 <= b.count else { break }
            let tag = read16(b, e, little)
            guard tag == ratingTag || tag == percentTag else { continue }
            let type = Int(read16(b, e + 2, little))
            let n = read32(b, e + 4, little)
            guard (type == 3 || type == 4), n == 1 else {
                throw RatingWriteError.unsupported("Exif 星级标签的写法不能原地修改")
            }
            try found(tag, type, e + 8, little)
        }
    }

    private static func read16(_ b: [UInt8], _ i: Int, _ little: Bool) -> UInt16 {
        little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    private static func read32(_ b: [UInt8], _ i: Int, _ little: Bool) -> UInt32 {
        little ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            : UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
