import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Yilan

// 拉直（spec E6）：几何（最大内接矩形、拖框、和 90° 旋转叠加）、写出（没有空白角、角度 0 时不变、原图不动）、
// 模型流程（Esc、只拉直就保存、编辑开关）。写文件的测试都在临时目录里做

// MARK: - 工具

private func defaults() -> UserDefaults {
    let name = "yilan-e6-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func makeModel(_ folder: URL, select name: String) throws -> BrowserModel {
    let model = BrowserModel(settings: AppSettings(defaults: defaults()), recents: RecentFolders(defaults: defaults()))
    let items = try FolderScanner.scan(folder: folder)
    let index = items.firstIndex { $0.name == name }
    model.apply(FolderScanner.Result(folder: folder, items: items, initialIndex: index,
                                     sidecars: SidecarIndex.scan(folder: folder, media: items)))
    return model
}

@MainActor
@discardableResult
private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func key(_ keyCode: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                  context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                  isARepeat: false, keyCode: keyCode))
}

private func names(_ folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
}

private func target(_ url: URL) throws -> EditTarget {
    let item = try MetaFixtures.item(url)
    let info = EditWriter.sourceInfo(url)
    return EditTarget.decide(for: item, sourceType: info.typeIdentifier, hasAlpha: info.hasAlpha)
}

/// 全图 plan（和 EditTests 里的写法相同）
private func plan(_ url: URL, turns: Int = 0, crop: PixelRect? = nil, scale: Double = 1) throws -> EditPlan {
    let size = try #require(EditWriter.orientedSize(url))
    let edited = turns % 2 == 1 ? size.swapped : size
    let c = crop ?? PixelRect(size: edited)
    return EditPlan(source: url, imageSize: size, quarterTurns: turns, crop: c, output: ResizeMath.output(crop: c.size, scale: scale))
}

private func sameMtime(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }

/// 不带透明通道的测试图（PNG）：split 为 true 时上半白、下半黑，否则整张红
private func testPNG(width: Int, height: Int, split: Bool = false) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yilan-e6-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("level.png")
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    if split {
        // CGContext 原点在左下：图的上半是 y ≥ height / 2
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    } else {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = try #require(ctx.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return url
}

/// 文件的像素（RGBA8，左上原点）
private struct Pixels {
    let width: Int, height: Int
    private let buf: [UInt8]

    init(_ url: URL) throws {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        width = image.width
        height = image.height
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        buf = b
    }

    /// (r, g, b, a)；y 从上往下数
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
    }
}

/// 点 (x, y) 在不在转过 angle 度的照片里（独立于 StraightenMath 的检查）
private func inPhoto(_ x: Double, _ y: Double, size: PixelSize, angle: Double, slack: Double = 0.5) -> Bool {
    let W = Double(size.width), H = Double(size.height)
    let t = angle * .pi / 180
    let dx = x - W / 2, dy = y - H / 2
    let qx = cos(t) * dx + sin(t) * dy, qy = -sin(t) * dx + cos(t) * dy
    return abs(qx) <= W / 2 + slack && abs(qy) <= H / 2 + slack
}

private func cornersInPhoto(_ r: PixelRect, size: PixelSize, angle: Double) -> Bool {
    [(r.x, r.y), (r.maxX, r.y), (r.x, r.maxY), (r.maxX, r.maxY)].allSatisfy {
        inPhoto(Double($0.0), Double($0.1), size: size, angle: angle)
    } && r.x >= 0 && r.y >= 0 && r.maxX <= size.width && r.maxY <= size.height
}

// MARK: - 几何

@Suite("编辑：拉直的几何")
struct StraightenGeometryTests {
    @Test("角度：±45 以内、0.1 度一档；文字「0.0°」「−3.2°」「+3.2°」")
    func angleText() {
        #expect(StraightenMath.clampAngle(50) == 45 && StraightenMath.clampAngle(-99) == -45)
        #expect(StraightenMath.clampAngle(-3.24) == -3.2 && StraightenMath.clampAngle(-0.04) == 0)
        #expect(StraightenMath.clampAngle(.nan) == 0)
        #expect(StraightenMath.label(0) == "0.0°" && StraightenMath.label(-0.01) == "0.0°")
        #expect(StraightenMath.label(-3.2) == "\u{2212}3.2°" && StraightenMath.label(3.2) == "+3.2°")
    }

    @Test("最大内接矩形：保持原图比例、居中、四个角都在转过的照片里，再大 1% 就露角；和公式一致",
          arguments: [0.5, 3.2, -3.2, 10, -27.3, 45])
    func largestInscribed(_ angle: Double) {
        for size in [PixelSize(width: 4032, height: 2688), PixelSize(width: 3000, height: 4000), PixelSize(width: 1000, height: 1000)] {
            let r = StraightenMath.largestInscribed(size: size, angle: angle)
            let ratio = Double(size.width) / Double(size.height)
            #expect(abs(Double(r.height) - Double(r.width) / ratio) <= 1.5, "\(size) \(angle) → \(r)")
            #expect(abs(Double(r.x) + Double(r.width) / 2 - Double(size.width) / 2) <= 1)
            #expect(abs(Double(r.y) + Double(r.height) / 2 - Double(size.height) / 2) <= 1)
            #expect(cornersInPhoto(r, size: size, angle: angle), "\(size) \(angle) → \(r)")
            #expect(StraightenMath.contains(r, angle: angle, size: size))
            // 公式：k = min(W / (W·cos + H·sin), H / (W·sin + H·cos))
            let t = abs(angle) * .pi / 180, W = Double(size.width), H = Double(size.height)
            let k = min(W / (W * cos(t) + H * sin(t)), H / (W * sin(t) + H * cos(t)))
            // 允许几个像素：取整前每边往里留了 1 像素余量
            #expect(abs(Double(r.width) - W * k) <= 2 + 2 * max(W / H, 1), "\(size) \(angle): \(r.width) vs \(W * k)")
            let dw = r.width / 200, dh = r.height / 200
            let bigger = PixelRect(x: r.x - dw, y: r.y - dh, width: r.width + 2 * dw, height: r.height + 2 * dh)
            #expect(!StraightenMath.contains(bigger, angle: angle, size: size))
            // 正负角度大小一样
            #expect(StraightenMath.largestInscribed(size: size, angle: -angle).size == r.size)
        }
    }

    @Test("角度为 0：整张图就是最大内接矩形，框不被改动")
    func zero() {
        let s = PixelSize(width: 4032, height: 2688)
        #expect(StraightenMath.largestInscribed(size: s, angle: 0) == PixelRect(size: s))
        let r = PixelRect(x: 10, y: 20, width: 300, height: 200)
        #expect(StraightenMath.fit(r, angle: 0, size: s) == r)
    }

    @Test("角度为 0：拖框和原来的规则逐个相同；拉直后怎么拖都不露角，在里面的拖动照常走")
    func drag() {
        let b = PixelSize(width: 4032, height: 3024)
        let handles: [CropHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left, .move]
        let moves: [(Double, Double)] = [(300, 120), (-900, 40), (5000, 5000), (-5000, -5000), (17, -333)]
        let start = PixelRect(x: 1000, y: 800, width: 1200, height: 900)
        for ratio in [nil, 1.0, 4.0 / 3.0, 2.0 / 3.0] as [Double?] {
            for h in handles {
                for (dx, dy) in moves {
                    #expect(StraightenMath.drag(h, start: start, dx: dx, dy: dy, bounds: b, ratio: ratio, minSide: 16, angle: 0)
                            == CropMath.drag(h, start: start, dx: dx, dy: dy, bounds: b, ratio: ratio, minSide: 16))
                }
            }
        }
        for angle in [8.0, -20.0] {
            let inside = StraightenMath.largestInscribed(size: b, angle: angle)
            let small = PixelRect(x: inside.x + 400, y: inside.y + 300, width: 1000, height: 750)
            for begin in [inside, small] {
                for ratio in [nil, 4.0 / 3.0] as [Double?] {
                    for h in handles {
                        for (dx, dy) in moves {
                            let r = StraightenMath.drag(h, start: begin, dx: dx, dy: dy, bounds: b, ratio: ratio,
                                                        minSide: 16, angle: angle)
                            #expect(cornersInPhoto(r, size: b, angle: angle), "\(h) \(angle) \(dx),\(dy) → \(r)")
                        }
                    }
                }
            }
            let moved = StraightenMath.drag(.move, start: small, dx: -50, dy: -40, bounds: b, ratio: nil, minSide: 16, angle: angle)
            #expect(moved == PixelRect(x: small.x - 50, y: small.y - 40, width: small.width, height: small.height))
        }
    }

    @Test("编辑状态：角度变大时框按比例缩小，变回去不放大；和 90° 旋转、比例、横竖互换叠加后仍不露角；复原全部归零")
    @MainActor
    func session() {
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/x.jpg"), format: .standard, fileSize: 1, modificationDate: .now)
        let s = EditSession(item: item, imageSize: PixelSize(width: 4000, height: 3000), turns: 0)
        s.setAngle(-3.2)
        #expect(s.angle == -3.2 && s.isDirty)
        #expect(s.crop == StraightenMath.largestInscribed(size: s.editedSize, angle: -3.2))
        // 工具条上的像素尺寸跟着变小（spec E6-04）
        #expect(s.outputSize == s.crop.size && s.outputSize.width < 4000)
        #expect(s.plan.angle == -3.2 && !s.plan.isRotationOnly)
        let shrunk = s.crop
        s.setAngle(-1)
        #expect(s.crop == shrunk)
        // 角度回到 0 也算改动（框已经缩小了）；复原全部回去
        s.setAngle(0)
        #expect(s.crop == shrunk && s.isDirty)
        s.reset()
        #expect(!s.isDirty && s.angle == 0 && s.crop == PixelRect(size: s.editedSize))
        // 只拉直、框正好是整张图时也算改动（spec E6-07）
        s.setAngle(0.1)
        #expect(s.isDirty)
        s.reset()
        // 先拉直再转 90°：框跟着转，仍在照片里（spec E6-08）
        s.setAngle(12)
        s.rotate(clockwise: true)
        #expect(s.editedSize == PixelSize(width: 3000, height: 4000) && s.angle == 12)
        #expect(cornersInPhoto(s.crop, size: s.editedSize, angle: 12))
        s.setAngle(30)
        #expect(cornersInPhoto(s.crop, size: s.editedSize, angle: 30))
        s.setRatio(.r16x9)
        #expect(cornersInPhoto(s.crop, size: s.editedSize, angle: 30))
        s.swapOrientation()
        #expect(cornersInPhoto(s.crop, size: s.editedSize, angle: 30))
        s.setAngle(99)
        #expect(s.angle == 45 && cornersInPhoto(s.crop, size: s.editedSize, angle: 45))
        // 偏在一角的小框转大角度：中心转出照片后移到画面中间，仍不露角
        s.reset()
        s.crop = PixelRect(x: 0, y: 0, width: 300, height: 200)
        s.setAngle(40)
        #expect(cornersInPhoto(s.crop, size: s.editedSize, angle: 40) && s.crop.width >= 16)
        // 刻度尺算弹出层：Esc 先收起它（spec E6-02）
        s.straightenOpen = true
        s.straightening = true
        #expect(s.anyPopupOpen)
        s.closePopups()
        #expect(!s.straightenOpen && !s.straightening)
    }
}

// MARK: - 写出

@Suite("编辑：拉直写出")
struct StraightenWriterTests {
    @Test("角度为 0：计划和以前相同，写出的文件和不带角度时逐像素相同（裁切缩小、只旋转、没改动）")
    func zeroAngleUnchanged() throws {
        let dir = try MetaFixtures.copy(["IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2052.jpg")
        for base in [try plan(url, crop: PixelRect(x: 300, y: 200, width: 3000, height: 2000), scale: 0.5),
                     try plan(url, turns: 1), try plan(url)] {
            let zero = EditPlan(source: base.source, imageSize: base.imageSize, quarterTurns: base.quarterTurns,
                                crop: base.crop, output: base.output, angle: 0)
            #expect(zero == base && zero.isRotationOnly == base.isRotationOnly && zero.isUnchanged == base.isUnchanged)
            let a = try EditWriter.saveCopy(base, target: try target(url))
            let b = try EditWriter.saveCopy(zero, target: try target(url))
            #expect(try EditWriter.pixelDigest(a) == EditWriter.pixelDigest(b))
        }
        // 没改动：仍是原样复制
        let same = try EditWriter.saveCopy(try plan(url), target: try target(url))
        #expect(try MetaFixtures.sha(same) == MetaFixtures.sha(url))
    }

    @Test("拉直后存出的副本没有空白的角（四条边上全是照片的颜色）；原图逐字节和修改时间不变，不留临时文件",
          arguments: [(0, 7.5), (0, -30.0), (1, 12.0), (3, -45.0), (2, 0.3)])
    func noBlankCorners(_ turns: Int, _ angle: Double) throws {
        let url = try testPNG(width: 400, height: 300)
        let dir = url.deletingLastPathComponent()
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let size = PixelSize(width: 400, height: 300)
        let edited = turns % 2 == 1 ? size.swapped : size
        let crop = StraightenMath.largestInscribed(size: edited, angle: angle)
        let p = EditPlan(source: url, imageSize: size, quarterTurns: turns, crop: crop, output: crop.size, angle: angle)
        #expect(!p.isRotationOnly)
        let out = try EditWriter.saveCopy(p, target: try target(url))
        #expect(EditWriter.orientedSize(out) == crop.size)
        let px = try Pixels(out)
        func isPhoto(_ x: Int, _ y: Int) -> Bool {
            let c = px.at(x, y)
            return c.r >= 240 && c.g <= 15 && c.b <= 15 && c.a >= 250
        }
        var bad = 0
        for x in 0..<px.width { for y in [0, px.height - 1] where !isPhoto(x, y) { bad += 1 } }
        for y in 0..<px.height { for x in [0, px.width - 1] where !isPhoto(x, y) { bad += 1 } }
        #expect(bad == 0, "转 \(turns) 次、拉直 \(angle)°：边上有 \(bad) 个不是照片颜色的像素")
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(sameMtime(MetaFixtures.mtime(url), mtime))
        #expect(!names(dir).contains { SafeReplace.isOwnTemp($0) })
    }

    @Test("方向：正角度是顺时针（和预览一致）。上白下黑的图顺时针转后，分界线右边低、左边高")
    func clockwise() throws {
        let url = try testPNG(width: 400, height: 300, split: true)
        let size = PixelSize(width: 400, height: 300)
        let angle = 10.0
        let crop = StraightenMath.largestInscribed(size: size, angle: angle)
        let p = EditPlan(source: url, imageSize: size, quarterTurns: 0, crop: crop, output: crop.size, angle: angle)
        let out = try EditWriter.saveCopy(p, target: try target(url))
        let px = try Pixels(out)
        let cy = px.height / 2
        let offset = Int(Double(px.width) * 0.4 * tan(angle * .pi / 180) / 2)
        #expect(px.at(px.width * 9 / 10, cy + offset).r > 200)   // 右边：中线下面一点仍是白
        #expect(px.at(px.width / 10, cy - offset).r < 50)          // 左边：中线上面一点已经是黑
    }

    @Test("JPEG 旋转 + 拉直 + 比例 + 缩小：尺寸和界面一致，方向归一，拍摄信息保留，原图不变")
    func jpeg() async throws {
        let dir = try MetaFixtures.copy(["IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2052.jpg")
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let size = try #require(EditWriter.orientedSize(url))
        let item = try MetaFixtures.item(url)
        let p = await MainActor.run { () -> EditPlan in
            let session = EditSession(item: item, imageSize: size, turns: 0)
            session.rotate(clockwise: true)
            session.setAngle(-3.2)
            session.setRatio(.r4x3)
            session.scale = 0.5
            return session.plan
        }
        #expect(p.angle == -3.2 && p.turns == 1)
        let out = try EditWriter.saveCopy(p, target: try target(url))
        #expect(EditWriter.orientedSize(out) == p.output)
        #expect(EditWriter.sourceInfo(out).orientation == 1)
        #expect(MetaFixtures.properties(out, kCGImagePropertyExifDictionary)?[kCGImagePropertyExifDateTimeOriginal] as? String
                == "2020:08:01 09:12:12")
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(sameMtime(MetaFixtures.mtime(url), mtime))
    }
}

// MARK: - 模型流程

@Suite("编辑：拉直的模型流程")
@MainActor
struct StraightenModelTests {
    private func ready(_ folder: URL, _ name: String) async throws -> BrowserModel {
        let m = try makeModel(folder, select: name)
        #expect(await waitFor { m.canEditCurrent })
        await waitFor { m.ratingsLoaded }
        return m
    }

    @Test("刻度尺开着时 Esc 只收起它、不退出编辑；再按 Esc 放弃编辑，不产生任何文件，原图不变")
    func escape() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let before = names(dir)
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let m = try await ready(dir, "IMG_2034.jpg")
        m.enterEdit()
        let s = try #require(m.edit)
        s.straightenOpen = true
        s.setAngle(-6.5)
        #expect(m.handleKey(try key(53, "\u{1B}")))
        #expect(m.edit === s && !s.straightenOpen && s.angle == -6.5)
        #expect(m.handleKey(try key(53, "\u{1B}")))
        #expect(m.edit == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(names(dir) == before)
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(sameMtime(MetaFixtures.mtime(url), mtime))
    }

    @Test("只拉直就保存：默认另存副本（名字和裁切相同），尺寸是不露角的大小；原图逐字节和修改时间不变")
    func saveCopy() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let m = try await ready(dir, "IMG_2034.jpg")
        m.enterEdit()
        let s = try #require(m.edit)
        s.setAngle(4)
        let expected = s.outputSize
        #expect(expected == StraightenMath.largestInscribed(size: s.editedSize, angle: 4).size)
        #expect(s.target.canReplaceOriginal)   // 和裁切一样可以选替换原图
        m.saveEdit()
        #expect(await waitFor { m.edit == nil })
        let copy = try #require(m.current)
        #expect(copy.name == EditNaming.baseName("IMG_2034", attempt: 1) + ".jpg")
        #expect(EditWriter.orientedSize(copy.url) == expected)
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(sameMtime(MetaFixtures.mtime(url), mtime))
    }

    @Test("编辑开关关掉：进不了编辑，也就没有拉直")
    func editOff() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let m = try await ready(dir, "IMG_2034.jpg")
        m.settings.featureEdit = false
        m.enterEdit()
        #expect(m.edit == nil)
    }
}
