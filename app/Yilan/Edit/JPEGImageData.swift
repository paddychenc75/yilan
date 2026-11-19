import Foundation

/// JPEG 的画面数据：量化表、哈夫曼表、帧头、重启间隔和压缩后的扫描数据（不含 EXIF、XMP 等信息段）。
/// 两个 JPEG 的这些字节完全相同，解出来的像素就完全相同，不用把整张图解码出来比较。
/// 用于「保存旋转」后的自检（v0.3.1 F1-06）：一亿像素的照片整张解码要占约 400 MB 一份
enum JPEGImageData {
    /// 画面数据的各段（按文件中的顺序）；不是能看懂的 JPEG 时返回 nil
    static func segments(_ data: Data) -> [Data]? {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Data]? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
            var out: [Data] = []
            var i = 2
            var inScan = false
            var scanStart = 0
            while i + 1 < n {
                if inScan {
                    // 扫描数据：FF00 是转义，FFD0–D7 是重启标记，都属于数据；FFD9 结束；
                    // 其他标记（渐进式 JPEG 中间的 DHT、SOS 等）结束这一段扫描数据
                    guard b[i] == 0xFF else { i += 1; continue }
                    let m = b[i + 1]
                    if m == 0x00 || (0xD0...0xD7).contains(m) || m == 0xFF { i += m == 0xFF ? 1 : 2; continue }
                    out.append(Data(bytes: raw.baseAddress! + scanStart, count: i - scanStart))
                    inScan = false
                    if m == 0xD9 { return out }
                    continue
                }
                guard b[i] == 0xFF else { return nil }
                let m = b[i + 1]
                if m == 0xFF { i += 1; continue }                 // 填充字节
                if m == 0xD9 { return out }                       // EOI
                if (0xD0...0xD7).contains(m) || m == 0x01 { i += 2; continue }
                guard i + 3 < n else { return nil }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard length >= 2, i + 2 + length <= n else { return nil }
                let end = i + 2 + length
                // SOFn（C0–CF，除去 C8）、DHT（C4）、DQT（DB）、DRI（DD）、SOS（DA）属于画面数据；APPn、COM 不算
                let isImage = ((0xC0...0xCF).contains(m) && m != 0xC8) || m == 0xDB || m == 0xDD || m == 0xDA
                if isImage { out.append(Data(bytes: raw.baseAddress! + i, count: end - i)) }
                i = end
                if m == 0xDA {
                    inScan = true
                    scanStart = i
                }
            }
            return nil   // 没有遇到 EOI：文件不完整
        }
    }

    /// 两个文件都是 JPEG，并且画面数据逐字节相同
    static func sameImageData(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? Data(contentsOf: a, options: .alwaysMapped),
              let y = try? Data(contentsOf: b, options: .alwaysMapped),
              let sx = segments(x), let sy = segments(y), !sx.isEmpty else { return false }
        return sx == sy
    }
}
