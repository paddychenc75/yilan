import Foundation
import ImageIO
import Testing
@testable import Yilan

// 评星写入层（技术方案第 3、5、8 节）：所有改动都在临时目录的副本上做

@Suite("XMP 定点修改")
struct XMPPacketTests {
    @Test("属性写法：改值，其他信息一项不少")
    func attributeForm() throws {
        let p = try XMPPacket(data: Data(lightroomStyleXMP.utf8))
        let before = try XMPPacket(data: Data(lightroomStyleXMP.utf8))
        #expect(p.rating == 2)
        p.setRating(5)
        let again = try XMPPacket(data: p.sidecarData())
        #expect(again.rating == 5)
        #expect(XMPPacket.keepsEverything(old: before, new: again))
        #expect(!again.isCreatedByYilan)
        #expect(again.hasPropertiesOtherThanRating)
    }

    @Test("元素写法、旧前缀 xap:、两段 Description、xpacket 包裹都保留")
    func elementForm() throws {
        let p = try XMPPacket(data: Data(darktableStyleXMP.utf8))
        let before = try XMPPacket(data: Data(darktableStyleXMP.utf8))
        #expect(p.rating == 1)
        p.setRating(4)
        let out = p.sidecarData()
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("xpacket begin") && text.contains("xpacket end"))
        let again = try XMPPacket(data: out)
        #expect(again.rating == 4)
        #expect(XMPPacket.keepsEverything(old: before, new: again))
        // ImageIO 会改写的那一项还在
        #expect(text.contains("DateTimeOriginal"))
    }

    @Test("没有星级时插入；删除；xmp 前缀被占用时换前缀")
    func insertRemove() throws {
        let p = XMPPacket.makeNew()
        #expect(p.isCreatedByYilan)
        #expect(p.rating == nil)
        p.setRating(3)
        #expect(try XMPPacket(data: p.bodyData()).rating == 3)
        p.setRating(nil)
        #expect(p.rating == nil)
        #expect(!p.hasPropertiesOtherThanRating)

        let clash = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://example.com/other/" xmp:Thing="1"/></rdf:RDF></x:xmpmeta>
        """
        let c = try XMPPacket(data: Data(clash.utf8))
        c.setRating(2)
        let back = try XMPPacket(data: c.bodyData())
        #expect(back.rating == 2)
        #expect(back.flattened().contains("/http://example.com/other/|Thing=1"))
    }

    @Test("星级值：1–5 显示，0、-1、乱码都是未评星")
    func values() {
        #expect(RatingValue.display(RatingValue.parse("4")) == 4)
        #expect(RatingValue.display(RatingValue.parse("4.0")) == 4)
        #expect(RatingValue.display(RatingValue.parse("0")) == 0)
        #expect(RatingValue.display(RatingValue.parse("-1")) == 0)
        #expect(RatingValue.display(RatingValue.parse("7")) == 0)
        #expect(RatingValue.display(RatingValue.parse("3.5")) == 0)
        #expect(RatingValue.display(RatingValue.parse("abc")) == 0)
        #expect(RatingValue.parse("-1") == -1)
    }
}

@Suite("内嵌写入：画面数据不变")
struct EmbeddedWriteTests {
    private func writeSequence(_ name: String, kind: RatingFileIO.Kind,
                               check: (URL, URL, Int) throws -> Void) throws {
        let dir = try MetaFixtures.copy([name])
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = MetaFixtures.sample.appendingPathComponent(name)
        let url = dir.appendingPathComponent(name)
        let mtime = MetaFixtures.mtime(url)
        for value in [4, 2, 0, 5] {
            try RatingFileIO.writeEmbedded(value, to: url, kind: kind)
            #expect(RatingValue.display(ImageIOMetadata.rating(at: url)) == value, "\(name) 读回 \(value)")
            let now = MetaFixtures.mtime(url)
            #expect(now.tv_sec == mtime.tv_sec && now.tv_nsec == mtime.tv_nsec, "\(name) 修改时间（纳秒）不变")
            #expect(MetaFixtures.pixels(url) == MetaFixtures.pixels(original), "\(name) 像素不变")
            try check(original, url, value)
        }
        // 临时文件没有残留
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == [name])
    }

    @Test("JPEG：除 XMP 段外逐字节相同，EXIF / GPS 不变", arguments: ["IMG_2052.jpg", "aurora.jpg", "IMG_2034.jpg"])
    func jpeg(name: String) throws {
        try writeSequence(name, kind: .jpeg) { original, url, _ in
            let a = try JPEGXMPWriter.bytesOutsideXMP(Data(contentsOf: original))
            let b = try JPEGXMPWriter.bytesOutsideXMP(Data(contentsOf: url))
            #expect(a == b)
            #expect(MetaFixtures.properties(original, kCGImagePropertyExifDictionary) == MetaFixtures.properties(url, kCGImagePropertyExifDictionary))
            #expect(MetaFixtures.properties(original, kCGImagePropertyGPSDictionary) == MetaFixtures.properties(url, kCGImagePropertyGPSDictionary))
        }
    }

    @Test("JPEG：扩展 XMP 和 HasExtendedXMP 保留（aurora.jpg）")
    func extendedXMP() throws {
        let dir = try MetaFixtures.copy(["aurora.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aurora.jpg")
        try RatingFileIO.writeEmbedded(3, to: url, kind: .jpeg)
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("http://ns.adobe.com/xmp/extension/".utf8)) != nil)
        let raw = try #require(try JPEGXMPWriter.packet(in: data))
        let packet = try XMPPacket(data: raw)
        #expect(packet.flattened().contains { $0.contains("HasExtendedXMP") })
    }

    @Test("PNG：除 XMP 块外逐字节相同")
    func png() throws {
        try writeSequence("harbor_night.png", kind: .png) { original, url, _ in
            let a = try PNGXMPWriter.bytesOutsideXMP(Data(contentsOf: original))
            let b = try PNGXMPWriter.bytesOutsideXMP(Data(contentsOf: url))
            #expect(a == b)
        }
    }

    @Test("HEIC：每个图块和 Exif 逐字节相同，清除写 0", arguments: ["IMG_2031.heic", "IMG_2035.heic"])
    func heic(name: String) throws {
        let before = try MetaFixtures.heifItems(MetaFixtures.sample.appendingPathComponent(name))
        try writeSequence(name, kind: .imageIO) { _, url, value in
            let after = try MetaFixtures.heifItems(url)
            for (id, (type, data)) in before where type != "mime" {
                #expect(after[id]?.1 == data, "\(name) 项目 \(id)（\(type)）不变")
            }
            if value == 0 { #expect(ImageIOMetadata.rating(at: url) == 0) }
        }
    }

    @Test("TIFF：条带数据逐字节相同")
    func tiff() throws {
        let strips = try MetaFixtures.tiffStrips(MetaFixtures.sample.appendingPathComponent("scan_003.tif"))
        try writeSequence("scan_003.tif", kind: .imageIO) { _, url, _ in
            let now = try MetaFixtures.tiffStrips(url)
            #expect(now == strips)
        }
    }

    @Test("多图 JPEG：XMP 段在 MPF 之后时不改，交给小文件")
    func mpfOrder() throws {
        // SOI + APP2(MPF) + APP1(XMP) + SOS…（结构测试，不是真图片）
        func seg(_ marker: UInt8, _ body: Data) -> Data {
            Data([0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]) + body
        }
        let xmp = JPEGXMPWriter.xmpHeader + XMPPacket.makeNew().packetData(padding: 0)
        var data = Data([0xFF, 0xD8])
        data += seg(0xE2, Data("MPF\0rest".utf8))
        data += seg(0xE1, xmp)
        data += Data([0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9])
        #expect(throws: RatingWriteError.self) { try JPEGXMPWriter.rewrite(data) { $0.setRating(3) } }
        // XMP 在 MPF 前面时可以改
        var ok = Data([0xFF, 0xD8])
        ok += seg(0xE1, xmp)
        ok += seg(0xE2, Data("MPF\0rest".utf8))
        ok += Data([0xFF, 0xDA, 0x00, 0x02, 0x00, 0xFF, 0xD9])
        let out = try JPEGXMPWriter.rewrite(ok) { $0.setRating(3) }
        let raw = try #require(try JPEGXMPWriter.packet(in: out))
        #expect(try XMPPacket(data: raw).rating == 3)
    }

    @Test("ImageIO 不能无损写的格式（GIF）自动改用小文件")
    func gifFallsBackToSidecar() throws {
        let dir = try MetaFixtures.copy(["gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gears.gif")
        let sha = try MetaFixtures.sha(url)
        let result = try RatingFileIO.write(4, for: MetaFixtures.item(url), mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(result.location == .sidecar(dir.appendingPathComponent("gears.xmp")))
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(RatingFileIO.read(try MetaFixtures.item(url), sidecars: try MetaFixtures.index(dir)).value == 4)
    }
}

@Suite(".xmp 小文件")
struct SidecarTests {
    @Test("RAW：生成同名 .xmp，RAW 一个字节都不变；清除后删掉一览建的小文件")
    func rawSidecar() throws {
        guard let name = MetaFixtures.rawSamples.first(where: { $0.hasSuffix(".ARW") }) ?? MetaFixtures.rawSamples.first else {
            print("没有本地 RAW 样张，跳过")
            return
        }
        let dir = try MetaFixtures.copy([name], from: MetaFixtures.raw)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let item = try MetaFixtures.item(url)
        let side = url.deletingPathExtension().appendingPathExtension("xmp")
        let r = try RatingFileIO.write(3, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(r.location == .sidecar(side))
        #expect(r.createdSidecar == side)
        #expect(try XMPPacket(data: Data(contentsOf: side)).isCreatedByYilan)
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 3)
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(MetaFixtures.mtime(url).tv_nsec == mtime.tv_nsec)
        let c = try RatingFileIO.write(0, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        // 样张的机内星级是 0 或没有：一览建的小文件清除后删掉
        if RatingValue.display(ImageIOMetadata.rating(at: url)) == 0 {
            #expect(c.removedSidecar == side)
            #expect(!FileManager.default.fileExists(atPath: side.path))
        }
        #expect(try MetaFixtures.sha(url) == sha)
    }

    @Test("已有的 Lightroom 小文件：只改星级；清除后保留文件")
    func existingSidecar() throws {
        let dir = try MetaFixtures.copy(["gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = dir.appendingPathComponent("gears.xmp")
        try Data(lightroomStyleXMP.utf8).write(to: side)
        let item = try MetaFixtures.item(dir.appendingPathComponent("gears.gif"))
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 2)
        _ = try RatingFileIO.write(5, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        let after = try XMPPacket(data: Data(contentsOf: side))
        #expect(after.rating == 5)
        #expect(XMPPacket.keepsEverything(old: try XMPPacket(data: Data(lightroomStyleXMP.utf8)), new: after))
        let c = try RatingFileIO.write(0, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(c.removedSidecar == nil)
        #expect(try XMPPacket(data: Data(contentsOf: side)).rating == nil)
        #expect(FileManager.default.fileExists(atPath: side.path))
    }

    @Test("命名：RAW 用同名；实况照片 HEIC + MOV 同名时用完整文件名")
    func naming() throws {
        let folder = URL(fileURLWithPath: "/tmp/naming")
        func item(_ n: String) -> MediaItem {
            MediaItem(url: folder.appendingPathComponent(n), format: SupportedFormats.format(forExtension: (n as NSString).pathExtension)!,
                      fileSize: 1, modificationDate: .distantPast)
        }
        let items = [item("A.CR3"), item("A.JPG"), item("B.HEIC"), item("B.MOV"), item("C.mp4")]
        let index = SidecarIndex(folder: folder, sidecars: [], media: items)
        #expect(index.writeURL(for: items[0]).lastPathComponent == "A.xmp")
        #expect(index.writeURL(for: items[1]).lastPathComponent == "A.JPG.xmp")
        #expect(index.writeURL(for: items[2]).lastPathComponent == "B.HEIC.xmp")
        #expect(index.writeURL(for: items[3]).lastPathComponent == "B.MOV.xmp")
        #expect(index.writeURL(for: items[4]).lastPathComponent == "C.xmp")
        // 已有的 A.xmp 属于 RAW，不算 JPEG 的
        let withA = SidecarIndex(folder: folder, sidecars: [.init(url: folder.appendingPathComponent("A.xmp"), modificationDate: .distantPast, size: 1)], media: items)
        #expect(withA.readURL(for: items[0]) != nil)
        #expect(withA.readURL(for: items[1]) == nil)
        // 两个 RAW 共用小文件时删除其中一个不带走小文件
        let twoRaw = SidecarIndex(folder: folder, sidecars: [.init(url: folder.appendingPathComponent("D.xmp"), modificationDate: .distantPast, size: 1)],
                                  media: [item("D.CR3"), item("D.DNG")])
        #expect(twoRaw.sidecarToMoveWith(item("D.CR3")) == nil)
        #expect(withA.sidecarToMoveWith(items[0])?.lastPathComponent == "A.xmp")
    }

    @Test("「一律使用小文件」：图片本身不动，读取以小文件为准")
    func sidecarMode() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        let item = try MetaFixtures.item(url)
        let r = try RatingFileIO.write(4, for: item, mode: .sidecar, sidecars: MetaFixtures.index(dir))
        #expect(r.location == .sidecar(dir.appendingPathComponent("IMG_2034.xmp")))
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 4)
    }

    @Test("「写入文件内部」时已有带星级的小文件：两处改成同一个值（PD-05）")
    func keepsBothInSync() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let item = try MetaFixtures.item(url)
        _ = try RatingFileIO.write(2, for: item, mode: .sidecar, sidecars: MetaFixtures.index(dir))
        _ = try RatingFileIO.write(5, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(ImageIOMetadata.rating(at: url) == 5)
        #expect(try XMPPacket(data: Data(contentsOf: dir.appendingPathComponent("IMG_2034.xmp"))).rating == 5)
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 5)
    }
}

@Suite("安全替换和错误")
struct SafeReplaceTests {
    @Test("不可写的文件夹：报 notWritable，原文件不变，没有残留")
    func readOnlyFolder() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        chmod(dir.path, 0o555)
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(!SafeReplace.isWritable(folder: dir))
        #expect(throws: RatingWriteError.notWritable) {
            try RatingFileIO.write(3, for: try MetaFixtures.item(url), mode: .embedded, sidecars: try MetaFixtures.index(dir))
        }
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["IMG_2034.jpg"])
    }

    @Test("写临时文件中途失败：原文件不变，临时文件删掉")
    func failureDuringProduce() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        #expect(throws: RatingWriteError.diskFull) {
            try SafeReplace.replace(url, keepModificationDate: true) { temp in
                try Data("半截".utf8).write(to: temp)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            } verify: { _ in }
        }
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["IMG_2034.jpg"])
    }

    @Test("错误映射")
    func mapping() {
        #expect(SafeReplace.map(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))) == .notWritable)
        #expect(SafeReplace.map(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(SafeReplace.map(CocoaError(.fileWriteVolumeReadOnly)) == .notWritable)
        #expect(SafeReplace.map(CocoaError(.fileNoSuchFile)) == .vanished)
    }

    @Test("只清理一览自己的、超过 10 分钟的临时文件")
    func cleanup() throws {
        let dir = try MetaFixtures.copy([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent(".yilan-\(UUID().uuidString).jpg")
        let fresh = dir.appendingPathComponent(".yilan-\(UUID().uuidString).jpg")
        let lookalike = dir.appendingPathComponent(".yilan-notes.txt")
        let user = dir.appendingPathComponent("yilan-\(UUID().uuidString).jpg")
        for u in [old, fresh, lookalike, user] { try Data("x".utf8).write(to: u) }
        let past = Date().addingTimeInterval(-3600)
        for u in [old, lookalike, user] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: u.path) }
        #expect(SafeReplace.cleanStaleTemps(in: dir) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        for u in [fresh, lookalike, user] { #expect(FileManager.default.fileExists(atPath: u.path)) }
    }
}

@Suite("写入队列和账本")
struct RatingWriterTests {
    actor Log {
        var events: [String] = []
        func add(_ s: String) { events.append(s) }
    }

    @Test("同一文件排队时只写最新值，中间值跳过")
    func coalesce() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let item = try MetaFixtures.item(url)
        let index = try MetaFixtures.index(dir)
        let writer = RatingWriter()
        await writer.setDelayForTesting(.milliseconds(100))
        let log = Log()
        for v in [1, 2, 3] {
            await writer.enqueue(.init(item: item, value: v, mode: .embedded, sidecars: index)) { outcome in
                switch outcome {
                case .written: await log.add("写 \(v)")
                case .superseded: await log.add("跳过 \(v)")
                case .failed(let e): await log.add("失败 \(v) \(e)")
                }
            }
        }
        await writer.waitUntilIdle()
        #expect(await log.events == ["跳过 2", "写 1", "写 3"])
        #expect(ImageIOMetadata.rating(at: url) == 3)
    }

    @Test("账本：认出自己写的状态，只认一次")
    func ledger() {
        var l = OwnWriteLedger()
        let d = Date()
        l.record([FileStamp(path: "/tmp/a.jpg", exists: true, size: 10, modificationDate: d)])
        let wrongSize = l.consume(path: "/tmp/a.jpg", size: 11, modificationDate: d)
        let first = l.consume(path: "/tmp/a.jpg", size: 10, modificationDate: d)
        let second = l.consume(path: "/tmp/a.jpg", size: 10, modificationDate: d)
        #expect(!wrongSize && first && !second)
        l.record([FileStamp(path: "/tmp/a.xmp", exists: false, size: 0, modificationDate: .distantPast)])
        let removed = l.consumeRemoval(path: "/tmp/a.xmp")
        #expect(removed)
    }
}

@Suite("读取星级")
struct RatingReadTests {
    @Test("样例都是未评星；RAW 的机内星级系统能读出（样张为 0 或没有）")
    func fixtures() throws {
        let dir = MetaFixtures.sample
        let index = try MetaFixtures.index(dir)
        for name in ["IMG_2052.jpg", "aurora.jpg", "IMG_2031.heic", "harbor_night.png", "scan_003.tif", "trail.mp4", "mountains.svg"] {
            #expect(RatingFileIO.read(try MetaFixtures.item(dir.appendingPathComponent(name)), sidecars: index).value == 0)
        }
        for name in MetaFixtures.rawSamples {
            let info = RatingFileIO.read(try MetaFixtures.item(MetaFixtures.raw.appendingPathComponent(name)), sidecars: .empty)
            #expect(info.value == 0)
        }
    }

    @Test("写入后读回；2000 个文件内的读取在 RatingFileIO 层不出错")
    func roundTrip() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2031.heic", "harbor_night.png", "scan_003.tif", "trail.mp4"])
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["IMG_2034.jpg", "IMG_2031.heic", "harbor_night.png", "scan_003.tif", "trail.mp4"].enumerated() {
            let item = try MetaFixtures.item(dir.appendingPathComponent(name))
            _ = try RatingFileIO.write(i + 1, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
            #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == i + 1, "\(name)")
        }
    }
}
