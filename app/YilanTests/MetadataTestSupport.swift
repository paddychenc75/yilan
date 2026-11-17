import CryptoKit
import Foundation
import ImageIO
@testable import Yilan

/// 评星写入测试的公共工具。所有测试都在临时目录里的副本上做，不碰仓库里的样例和用户的文件
enum MetaFixtures {
    static let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// 样例所在目录。可以用环境变量 YILAN_FIXTURES_DIR（xcodebuild 里写成 TEST_RUNNER_YILAN_FIXTURES_DIR）
    /// 指向一份放在 /tmp 的镜像，避免测试宿主程序每次重新编译后访问“桌面”时等系统授权
    static let fixtures: URL = ProcessInfo.processInfo.environment["YILAN_FIXTURES_DIR"].map(URL.init(fileURLWithPath:))
        ?? appDir.appendingPathComponent("Fixtures")
    static let sample = fixtures.appendingPathComponent("sample")
    /// 本机才有的 RAW 样张（不进仓库），没有时相关测试跳过
    static let raw = fixtures.appendingPathComponent("raw")

    /// 新建一个临时目录，把指定的样例复制进去
    static func copy(_ names: [String], from dir: URL = sample) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yilan-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for n in names { try FileManager.default.copyItem(at: dir.appendingPathComponent(n), to: dest.appendingPathComponent(n)) }
        return dest
    }

    static var rawSamples: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func item(_ url: URL) throws -> MediaItem {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileIdentifierKey])
        guard let format = SupportedFormats.format(forExtension: url.pathExtension) else { throw CocoaError(.fileReadUnknown) }
        return MediaItem(url: url, format: format, fileSize: Int64(v.fileSize ?? 0),
                         modificationDate: v.contentModificationDate ?? .distantPast, fileID: v.fileIdentifier)
    }

    static func index(_ folder: URL) throws -> SidecarIndex {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let items = names.compactMap { try? item(folder.appendingPathComponent($0)) }
        return SidecarIndex.scan(folder: folder, media: items)
    }

    /// 解码出的像素（原始字节）
    static func pixels(_ url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return img.dataProvider?.data as Data?
    }

    static func properties(_ url: URL, _ key: CFString) -> NSDictionary? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return p[key] as? NSDictionary
    }

    /// 修改时间（纳秒）
    static func mtime(_ url: URL) -> timespec {
        var st = stat()
        stat(url.path, &st)
        return st.st_mtimespec
    }

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// HEIC：按 iloc 取出每个项目的数据（项目编号 → (类型, 数据)）
    static func heifItems(_ url: URL) throws -> [Int: (String, Data)] {
        let b = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func boxes(_ start: Int, _ end: Int) -> [(String, Int, Int)] {
            var i = start
            var out: [(String, Int, Int)] = []
            while i + 8 <= end {
                var size = u32(i)
                let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? "?"
                var header = 8
                if size == 1 { size = (0..<8).reduce(0) { $0 << 8 | Int(b[i + 8 + $1]) }; header = 16 }
                if size == 0 { size = end - i }
                out.append((type, i + header, i + size))
                i += size
            }
            return out
        }
        guard let meta = boxes(0, b.count).first(where: { $0.0 == "meta" }) else { return [:] }
        let inner = boxes(meta.1 + 4, meta.2)
        guard let iinf = inner.first(where: { $0.0 == "iinf" }), let iloc = inner.first(where: { $0.0 == "iloc" }) else { return [:] }
        // iinf：每个 infe 的项目编号和类型
        var types: [Int: String] = [:]
        let iinfVersion = b[iinf.1]
        var p = iinf.1 + (iinfVersion == 0 ? 6 : 8)
        while p < iinf.2 {
            let size = u32(p)
            let v = b[p + 8]
            if v >= 2 {
                let id = v == 2 ? Int(b[p + 12]) << 8 | Int(b[p + 13]) : u32(p + 12)
                let q = v == 2 ? p + 16 : p + 18
                types[id] = String(bytes: b[q..<(q + 4)], encoding: .ascii)
            }
            p += size
        }
        // iloc
        var q = iloc.1
        let version = b[q]
        let offsetSize = Int(b[q + 4] >> 4), lengthSize = Int(b[q + 4] & 15)
        let baseSize = Int(b[q + 5] >> 4), indexSize = version == 1 || version == 2 ? Int(b[q + 5] & 15) : 0
        q += 6
        func read(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            let v = (0..<n).reduce(0) { $0 << 8 | Int(b[q + $1]) }
            q += n
            return v
        }
        let count = version < 2 ? read(2) : read(4)
        var result: [Int: (String, Data)] = [:]
        for _ in 0..<count {
            let id = version < 2 ? read(2) : read(4)
            if version == 1 || version == 2 { _ = read(2) }
            _ = read(2)
            let base = read(baseSize)
            let extents = read(2)
            var data = Data()
            for _ in 0..<extents {
                if indexSize > 0 { _ = read(indexSize) }
                let off = read(offsetSize), len = read(lengthSize)
                data.append(contentsOf: b[(base + off)..<(base + off + len)])
            }
            result[id] = (types[id] ?? "?", data)
        }
        return result
    }

    /// TIFF：第一个 IFD 的条带数据
    static func tiffStrips(_ url: URL) throws -> Data {
        let b = [UInt8](try Data(contentsOf: url))
        let little = b[0] == 0x49
        func u16(_ i: Int) -> Int { little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int { little ? u16(i) | u16(i + 2) << 16 : u16(i) << 16 | u16(i + 2) }
        let ifd = u32(4)
        var tags: [Int: (Int, Int, Int)] = [:]
        for k in 0..<u16(ifd) {
            let e = ifd + 2 + 12 * k
            tags[u16(e)] = (u16(e + 2), u32(e + 4), e + 8)
        }
        func values(_ tag: Int) -> [Int] {
            guard let (type, count, at) = tags[tag] else { return [] }
            let size = type == 3 ? 2 : 4
            let start = count * size <= 4 ? at : u32(at)
            return (0..<count).map { size == 2 ? u16(start + $0 * 2) : u32(start + $0 * 4) }
        }
        var out = Data()
        for (o, c) in zip(values(273), values(279)) { out.append(contentsOf: b[o..<(o + c)]) }
        return out
    }
}

/// 仿 Lightroom Classic 的小文件（测试代码自己写的文本，不是任何用户的文件）
let lightroomStyleXMP = """
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
    xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:yx="http://example.com/unknown-tool/1.0/"
   xmp:CreatorTool="Adobe Photoshop Lightroom Classic 14.0 (Macintosh)"
   xmp:Rating="2"
   xmp:Label="Red"
   crs:Version="17.0"
   crs:Exposure2012="+0.35"
   crs:Highlights2012="-48"
   crs:HasSettings="True"
   yx:Custom="keep-me">
   <crs:ToneCurvePV2012>
    <rdf:Seq>
     <rdf:li>0, 0</rdf:li>
     <rdf:li>64, 58</rdf:li>
     <rdf:li>255, 255</rdf:li>
    </rdf:Seq>
   </crs:ToneCurvePV2012>
   <xmpMM:History>
    <rdf:Seq>
     <rdf:li stEvt:action="saved" stEvt:instanceID="xmp.iid:1" stEvt:changed="/metadata"/>
    </rdf:Seq>
   </xmpMM:History>
   <dc:subject><rdf:Bag><rdf:li>旅行</rdf:li><rdf:li>Kyoto</rdf:li></rdf:Bag></dc:subject>
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">清水寺 &amp; 晨光</rdf:li></rdf:Alt></dc:title>
   <lr:hierarchicalSubject><rdf:Bag><rdf:li>地点|京都</rdf:li></rdf:Bag></lr:hierarchicalSubject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""

/// 仿 darktable + Capture One：xpacket 包裹、两段 Description、星级用元素写法（ImageIO 改写时会丢 exif:DateTimeOriginal）
let darktableStyleXMP = """
<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmlns:darktable="http://darktable.sf.net/"
    exif:DateTimeOriginal="2026-10-12T09:41:22"
    darktable:history_end="2">
   <darktable:history>
    <rdf:Seq>
     <rdf:li darktable:num="0" darktable:operation="exposure" darktable:params="0000000000000000"/>
     <rdf:li darktable:num="1" darktable:operation="colorin" darktable:params="gz02eJxjYGBgYAFiCQYYgNA="/>
    </rdf:Seq>
   </darktable:history>
  </rdf:Description>
  <rdf:Description rdf:about="" xmlns:xap="http://ns.adobe.com/xap/1.0/" xmlns:c1="http://www.captureone.com/ns/1.0/" c1:Variant="1">
   <xap:Rating>1</xap:Rating>
   <c1:Keywords><rdf:Bag><rdf:li>a</rdf:li></rdf:Bag></c1:Keywords>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""
