import Foundation

/// PNG：自己替换或插入 iTXt（关键字 XML:com.adobe.xmp）块，其他块原样拷贝（技术方案 3.1）。
/// 不用 ImageIO：实测对原本没有 XMP 的 PNG 会返回成功却没写进去
enum PNGXMPWriter {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let keyword = Array("XML:com.adobe.xmp".utf8)

    struct Chunk {
        let type: String
        /// 整块（长度 + 类型 + 数据 + CRC）
        let range: Range<Int>
        let body: Range<Int>
    }

    static func chunks(_ data: Data) throws -> [Chunk] {
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<8]) == signature else { throw RatingWriteError.unsupported("不是 PNG") }
        var i = 8
        var out: [Chunk] = []
        while i + 12 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 0, i + 12 + len <= b.count else { throw RatingWriteError.unsupported("PNG 块长度异常") }
            let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? "????"
            out.append(Chunk(type: type, range: i..<(i + 12 + len), body: (i + 8)..<(i + 8 + len)))
            i += 12 + len
            if type == "IEND" { break }
        }
        return out
    }

    private static func isXMP(_ c: Chunk, _ b: [UInt8]) -> Bool {
        c.type == "iTXt" && c.body.count > keyword.count && Array(b[c.body.prefix(keyword.count + 1)]) == keyword + [0]
    }

    /// iTXt：关键字\0 压缩标志 压缩方法 语言\0 翻译后的关键字\0 正文
    private static func text(of c: Chunk, _ b: [UInt8]) throws -> Data {
        var p = c.body.lowerBound + keyword.count + 1
        guard p + 2 <= c.body.upperBound else { throw RatingWriteError.unsupported("iTXt 异常") }
        guard b[p] == 0 else { throw RatingWriteError.unsupported("XMP 是压缩存储的") }
        p += 2
        while p < c.body.upperBound, b[p] != 0 { p += 1 }
        p += 1
        while p < c.body.upperBound, b[p] != 0 { p += 1 }
        p += 1
        guard p <= c.body.upperBound else { throw RatingWriteError.unsupported("iTXt 异常") }
        return Data(b[p..<c.body.upperBound])
    }

    static func packet(in data: Data) throws -> Data? {
        let data = Data(data)
        let b = [UInt8](data)
        guard let c = try chunks(data).first(where: { isXMP($0, b) }) else { return nil }
        return try text(of: c, b)
    }

    static func rewrite(_ data: Data, edit: (XMPPacket) -> Void) throws -> Data {
        let data = Data(data)
        let b = [UInt8](data)
        let list = try chunks(data)
        let existing = list.first { isXMP($0, b) }
        guard let idat = list.first(where: { $0.type == "IDAT" }) else { throw RatingWriteError.unsupported("PNG 没有图像数据") }
        let packet: XMPPacket
        if let existing {
            guard let p = try? XMPPacket(data: try text(of: existing, b)) else { throw RatingWriteError.unsupported("原 XMP 无法解析") }
            packet = p
        } else {
            packet = XMPPacket.makeNew()
        }
        edit(packet)
        let body = keyword + [0, 0, 0, 0, 0] + [UInt8](packet.packetData(padding: 0))
        let typeAndBody = Array("iTXt".utf8) + body
        let chunk = be32(UInt32(body.count)) + typeAndBody + be32(crc32(typeAndBody))
        var out = Data(capacity: data.count + chunk.count)
        let cut = existing?.range ?? (idat.range.lowerBound..<idat.range.lowerBound)
        out.append(data[..<cut.lowerBound])
        out.append(contentsOf: chunk)
        out.append(data[cut.upperBound...])
        return out
    }

    /// 去掉 XMP 块后的全部字节（测试和自检用）
    static func bytesOutsideXMP(_ data: Data) throws -> Data {
        let data = Data(data)
        let b = [UInt8](data)
        guard let c = try chunks(data).first(where: { isXMP($0, b) }) else { return data }
        var out = Data(data[..<c.range.lowerBound])
        out.append(data[c.range.upperBound...])
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in bytes { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
