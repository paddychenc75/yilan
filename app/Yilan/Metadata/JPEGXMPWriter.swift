import Foundation

/// JPEG：自己替换或插入 XMP 的 APP1 段，其他字节原样拷贝（技术方案 3.1、3.2）。
/// 不用 ImageIO：实测它会重写整个 EXIF（有理数近似、丢 Interop 目录）
enum JPEGXMPWriter {
    static let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    /// APP1 段长度字段最大 65535，减去长度字段本身和标识头
    static let maxPacketSize = 65535 - 2 - 29

    struct Layout {
        /// 已有的标准 XMP 段（整段，含 FFE1 和长度）
        var xmp: Range<Int>?
        /// MPF（多图 JPEG）APP2 段的起点
        var mpfStart: Int?
        /// 新 XMP 段应插入的位置：Exif APP1 之后；没有 Exif 时在 APP0 之后；都没有时紧跟 SOI
        var insertAt: Int
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 4 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// 扫描 SOI 到 SOS 之间的段
    static func layout(_ data: Data) throws -> Layout {
        guard isJPEG(data) else { throw RatingWriteError.unsupported("不是 JPEG") }
        let b = [UInt8](data)
        var i = 2
        var layout = Layout(insertAt: 2)
        var sawExif = false
        var sawApp0 = false
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { throw RatingWriteError.unsupported("JPEG 段结构异常") }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }   // 填充字节
            if marker == 0xD9 || marker == 0xDA { break }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { throw RatingWriteError.unsupported("JPEG 段长度异常") }
            let body = (i + 4)..<(i + 2 + length)
            let end = i + 2 + length
            if marker == 0xE1 {
                if layout.xmp == nil, b[body].starts(with: xmpHeader) { layout.xmp = i..<end }
                if !sawExif, b[body].starts(with: Array("Exif\0\0".utf8)) { sawExif = true; layout.insertAt = end }
            } else if marker == 0xE0, !sawExif, !sawApp0 {
                sawApp0 = true
                layout.insertAt = end
            } else if marker == 0xE2, layout.mpfStart == nil, b[body].starts(with: Array("MPF\0".utf8)) {
                layout.mpfStart = i
            }
            i = end
        }
        return layout
    }

    /// 读出已有的 XMP 包（没有时 nil）
    static func packet(in data: Data) throws -> Data? {
        let l = try layout(data)
        guard let r = l.xmp else { return nil }
        let start = data.startIndex + r.lowerBound + 4 + xmpHeader.count
        return data[start..<(data.startIndex + r.upperBound)]
    }

    /// 改写：edit 修改 XMP 包，返回新的文件内容
    static func rewrite(_ data: Data, edit: (XMPPacket) -> Void) throws -> Data {
        let data = Data(data)   // 下标从 0 开始
        let l = try layout(data)
        // 多图 JPEG 里，MPF 的偏移量相对 MPF 头计算：XMP 段在 MPF 前面才能安全改变长度
        if let mpf = l.mpfStart {
            if let x = l.xmp, x.lowerBound > mpf { throw RatingWriteError.unsupported("XMP 在 MPF 之后") }
            if l.xmp == nil, l.insertAt > mpf { throw RatingWriteError.unsupported("插入位置在 MPF 之后") }
        }
        let packet: XMPPacket
        if let r = l.xmp {
            let old = data[(r.lowerBound + 4 + xmpHeader.count)..<r.upperBound]
            guard let p = try? XMPPacket(data: Data(old)) else { throw RatingWriteError.unsupported("原 XMP 无法解析") }
            packet = p
        } else {
            packet = XMPPacket.makeNew()
        }
        edit(packet)
        var bytes = packet.packetData(padding: 512)
        if bytes.count > maxPacketSize { bytes = packet.packetData(padding: 0) }
        guard bytes.count <= maxPacketSize else { throw RatingWriteError.unsupported("XMP 超过 64 KB") }
        let length = 2 + xmpHeader.count + bytes.count
        var segment = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        segment.append(xmpHeader)
        segment.append(bytes)
        var out = Data(capacity: data.count + segment.count)
        if let r = l.xmp {
            out.append(data[..<r.lowerBound])
            out.append(segment)
            out.append(data[r.upperBound...])
        } else {
            out.append(data[..<l.insertAt])
            out.append(segment)
            out.append(data[l.insertAt...])
        }
        return out
    }

    /// 去掉标准 XMP 段后的全部字节（测试和自检用：改写前后应完全相同）
    static func bytesOutsideXMP(_ data: Data) throws -> Data {
        let data = Data(data)
        let l = try layout(data)
        guard let r = l.xmp else { return data }
        var out = Data(data[..<r.lowerBound])
        out.append(data[r.upperBound...])
        return out
    }
}
