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
        // 实况照片：HEIC 不用 B.xmp（那可能是别的软件给 MOV 写的）；视频不评星，不读它的小文件
        #expect(index.writeURL(for: items[2]).lastPathComponent == "B.HEIC.xmp")
        let withVideoSidecar = SidecarIndex(folder: folder, sidecars: [.init(url: folder.appendingPathComponent("C.xmp"), modificationDate: .distantPast, size: 1)], media: items)
        #expect(withVideoSidecar.readURL(for: items[4]) == nil)
        #expect(withVideoSidecar.sidecarToMoveWith(items[4]) == nil)
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
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2031.heic", "harbor_night.png", "scan_003.tif", "gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["IMG_2034.jpg", "IMG_2031.heic", "harbor_night.png", "scan_003.tif", "gears.gif"].enumerated() {
            let item = try MetaFixtures.item(dir.appendingPathComponent(name))
            _ = try RatingFileIO.write(i + 1, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
            #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == i + 1, "\(name)")
        }
    }
}


@Suite("互通（调研报告的产品决定）")
struct InteropTests {
    @Test("一览新建的小文件带 photoshop:SidecarForExtension（大写扩展名）；别人的小文件不加")
    func sidecarForExtension() throws {
        let dir = try MetaFixtures.copy(["gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try MetaFixtures.item(dir.appendingPathComponent("gears.gif"))
        _ = try RatingFileIO.write(3, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        let side = dir.appendingPathComponent("gears.xmp")
        let text = try String(contentsOf: side, encoding: .utf8)
        #expect(text.contains("photoshop:SidecarForExtension=\"GIF\""))
        #expect(text.contains(XMPPacket.photoshopNS))
        // 清除后照样删掉（扩展名不算别的信息）
        let c = try RatingFileIO.write(0, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(c.removedSidecar != nil)
        // 别人的小文件：不加
        try Data(lightroomStyleXMP.utf8).write(to: side)
        _ = try RatingFileIO.write(4, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(!(try String(contentsOf: side, encoding: .utf8)).contains("SidecarForExtension"))
    }

    @Test("DNG：内嵌和小文件都有星级时取较新的，同一时间算小文件")
    func dngNewer() {
        let old = Date(timeIntervalSince1970: 1000), new = Date(timeIntervalSince1970: 2000)
        #expect(RatingFileIO.dngWinner(sidecar: 2, sidecarDate: new, embedded: 5, embeddedDate: old) == 2)
        #expect(RatingFileIO.dngWinner(sidecar: 2, sidecarDate: old, embedded: 5, embeddedDate: new) == 5)
        #expect(RatingFileIO.dngWinner(sidecar: 2, sidecarDate: old, embedded: 5, embeddedDate: old) == 2)
        #expect(RatingFileIO.dngWinner(sidecar: nil, sidecarDate: nil, embedded: 5, embeddedDate: old) == 5)
        #expect(RatingFileIO.dngWinner(sidecar: 1, sidecarDate: new, embedded: nil, embeddedDate: nil) == 1)
    }

    @Test("DNG 样张：写小文件，DNG 一个字节都不变，读回小文件的星级")
    func dngSample() throws {
        guard MetaFixtures.rawSamples.contains("IMG_1361.DNG") else { return }
        let dir = try MetaFixtures.copy(["IMG_1361.DNG"], from: MetaFixtures.raw)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_1361.DNG")
        let sha = try MetaFixtures.sha(url)
        let item = try MetaFixtures.item(url)
        _ = try RatingFileIO.write(4, for: item, mode: .embedded, sidecars: MetaFixtures.index(dir))
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 4)
        #expect((try String(contentsOf: dir.appendingPathComponent("IMG_1361.xmp"), encoding: .utf8)).contains("SidecarForExtension=\"DNG\""))
    }

    @Test("XMP 里已有 MicrosoftPhoto:Rating 时改成同一个值；没有时不加")
    func microsoftRating() throws {
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:MicrosoftPhoto="http://ns.microsoft.com/photo/1.0/" xmp:Rating="3" MicrosoftPhoto:Rating="50"/></rdf:RDF></x:xmpmeta>
        """
        let p = try XMPPacket(data: Data(text.utf8))
        p.setRating(4)
        #expect(p.flattened().contains("/\(XMPPacket.microsoftPhotoNS)|Rating=75"))
        p.setRating(nil)
        #expect(p.flattened().contains("/\(XMPPacket.microsoftPhotoNS)|Rating=0"))
        let q = XMPPacket.makeNew()
        q.setRating(5)
        #expect(!q.flattened().contains { $0.contains(XMPPacket.microsoftPhotoNS) })
        #expect([1, 2, 3, 4, 5].map(XMPPacket.percent(for:)) == [1, 25, 50, 75, 99])
    }

    /// 造一个带 Exif Rating / RatingPercent 的 JPEG：把样例原来的 Exif 段换成自己拼的（只用于测试）
    private func jpegWithExifRating(little: Bool, rating: Int, percent: Int) throws -> URL {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        var b = [UInt8](try Data(contentsOf: url))
        func u16(_ v: Int) -> [UInt8] { little ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { little ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] : [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var tiff: [UInt8] = little ? [0x49, 0x49] : [0x4D, 0x4D]
        tiff += u16(42) + u32(8) + u16(2)
        tiff += u16(0x4746) + u16(3) + u32(1) + u16(rating) + [0, 0]
        tiff += u16(0x4749) + u16(3) + u32(1) + u16(percent) + [0, 0]
        tiff += u32(0)
        let body: [UInt8] = Array("Exif\0\0".utf8) + tiff
        let seg: [UInt8] = [0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
        // 原来的第一个段就是 Exif APP1：整段换掉
        let oldLen = Int(b[4]) << 8 | Int(b[5])
        b.replaceSubrange(2..<(4 + oldLen), with: seg)
        try Data(b).write(to: url)
        return url
    }

    @Test("JPEG 里已有的 Exif Rating / RatingPercent 原地改成同一个值，其他字节不变（小端和大端）", arguments: [true, false])
    func exifRating(little: Bool) throws {
        let url = try jpegWithExifRating(little: little, rating: 2, percent: 25)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = [UInt8](try Data(contentsOf: url))
        let t = try #require(ExifRatingPatcher.tiffHeaders(in: before, kind: .jpeg).first)
        #expect(ExifRatingPatcher.values(in: before, tiffStart: t) == [0x4746: 2, 0x4749: 25])
        try RatingFileIO.writeEmbedded(4, to: url, kind: .jpeg)
        let after = [UInt8](try Data(contentsOf: url))
        let t2 = try #require(ExifRatingPatcher.tiffHeaders(in: after, kind: .jpeg).first)
        #expect(ExifRatingPatcher.values(in: after, tiffStart: t2) == [0x4746: 4, 0x4749: 75])
        #expect(RatingValue.display(ImageIOMetadata.rating(at: url)) == 4)
        // 去掉 XMP 段后，和原文件相比只有那 4 个值字节不同
        let a = [UInt8](try JPEGXMPWriter.bytesOutsideXMP(Data(before)))
        let b = [UInt8](try JPEGXMPWriter.bytesOutsideXMP(Data(after)))
        #expect(a.count == b.count)
        let diff = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(diff.count <= 4 && !diff.isEmpty)
        // 清除：两个值都变 0
        try RatingFileIO.writeEmbedded(0, to: url, kind: .jpeg)
        let cleared = [UInt8](try Data(contentsOf: url))
        let t3 = try #require(ExifRatingPatcher.tiffHeaders(in: cleared, kind: .jpeg).first)
        #expect(ExifRatingPatcher.values(in: cleared, tiffStart: t3) == [0x4746: 0, 0x4749: 0])
    }

    @Test("没有 Exif 星级标签的 JPEG：不新增（样例逐字节比较见 EmbeddedWriteTests）")
    func noExifRatingAdded() throws {
        let dir = try MetaFixtures.copy(["IMG_2052.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_2052.jpg")
        try RatingFileIO.writeEmbedded(3, to: url, kind: .jpeg)
        let b = [UInt8](try Data(contentsOf: url))
        let t = try #require(ExifRatingPatcher.tiffHeaders(in: b, kind: .jpeg).first)
        #expect(ExifRatingPatcher.values(in: b, tiffStart: t).isEmpty)
    }

    @Test("星级 -1（别的软件的“排除”）：显示未评星，筛选算未评星")
    func rejected() throws {
        let dir = try MetaFixtures.copy(["gears.gif"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = dir.appendingPathComponent("gears.xmp")
        try Data(lightroomStyleXMP.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"-1\"").utf8).write(to: side)
        let item = try MetaFixtures.item(dir.appendingPathComponent("gears.gif"))
        let info = RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir))
        #expect(info.value == 0 && info.sidecar == -1)
        #expect(RatingCriterion(mode: .unrated).matches(ItemFacts(item: item, rating: info.value)))
    }

    @Test("视频不评星：不读、不写它的小文件")
    func video() throws {
        let dir = try MetaFixtures.copy(["trail.mp4"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = dir.appendingPathComponent("trail.xmp")
        try Data(lightroomStyleXMP.utf8).write(to: side)
        let item = try MetaFixtures.item(dir.appendingPathComponent("trail.mp4"))
        #expect(RatingFileIO.read(item, sidecars: try MetaFixtures.index(dir)).value == 0)
        #expect(throws: RatingWriteError.self) {
            try RatingFileIO.write(3, for: item, mode: .embedded, sidecars: try MetaFixtures.index(dir))
        }
        #expect(try String(contentsOf: side, encoding: .utf8) == lightroomStyleXMP)
    }
}
