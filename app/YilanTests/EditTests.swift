import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Yilan

// 编辑模式（spec 21、技术方案 13.7）：几何、命名、格式决定、真实写出、模型流程。
// 写文件的测试全部在临时目录的样例副本上做；废纸篓在测试里是 /tmp 下的假废纸篓

// MARK: - 工具

private func defaults() -> UserDefaults {
    let name = "yilan-edit-test-\(UUID().uuidString)"
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

private func orientation(_ url: URL) -> Int { EditWriter.sourceInfo(url).orientation }

private func exif(_ url: URL, _ key: CFString) -> Any? { MetaFixtures.properties(url, kCGImagePropertyExifDictionary)?[key] }

/// 全图 plan：转 turns，裁切 crop（为 nil 时不裁），缩小到 scale
private func plan(_ url: URL, turns: Int = 0, crop: PixelRect? = nil, scale: Double = 1) throws -> EditPlan {
    let size = try #require(EditWriter.orientedSize(url))
    let edited = turns % 2 == 1 ? size.swapped : size
    let c = crop ?? PixelRect(size: edited)
    return EditPlan(source: url, imageSize: size, quarterTurns: turns, crop: c, output: ResizeMath.output(crop: c.size, scale: scale))
}

private func target(_ url: URL, raw: RawExportFormat = .jpeg) throws -> EditTarget {
    let item = try MetaFixtures.item(url)
    let info = EditWriter.sourceInfo(url)
    return EditTarget.decide(for: item, sourceType: info.typeIdentifier, hasAlpha: info.hasAlpha, rawChoice: raw)
}

// MARK: - 几何

@Suite("编辑：几何")
struct EditGeometryTests {
    /// 3×2 每个像素颜色都不同的小图
    private func asymmetric() -> CIImage {
        let ctx = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<3 { for y in 0..<2 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / 2, green: CGFloat(y), blue: CGFloat(x * y) / 2, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func render(_ image: CIImage) -> Data {
        let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = Int(img.extent.width), h = Int(img.extent.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(img, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: nil)
        return Data(buf) + Data([UInt8(w), UInt8(h)])
    }

    @Test("方向组合：8 种原方向 × 4 种旋转，与 Core Image 逐像素一致")
    func orientationTable() {
        let base = asymmetric()
        for o in 1...8 {
            for q in 0..<4 {
                var expected = base.oriented(CGImagePropertyOrientation(rawValue: UInt32(o))!)
                for _ in 0..<q { expected = expected.oriented(.right) }
                let combined = ExifOrientation.rotating(o, quarterTurns: q)
                let actual = base.oriented(CGImagePropertyOrientation(rawValue: UInt32(combined))!)
                #expect(render(expected) == render(actual), "原方向 \(o) 转 \(q) 次")
            }
        }
        #expect(ExifOrientation.rotating(1, quarterTurns: 1) == 6)
        #expect(ExifOrientation.rotating(6, quarterTurns: -1) == 1)
        #expect(ExifOrientation.rotating(1, quarterTurns: 2) == 3)
    }

    @Test("裁切框跟着图转：转四次回到原样，顺转再逆转不变")
    func rotateRect() {
        let size = PixelSize(width: 4032, height: 3024)
        let r = PixelRect(x: 100, y: 200, width: 1000, height: 500)
        let cw = CropMath.rotate(r, clockwise: true, in: size)
        #expect(cw == PixelRect(x: 3024 - 200 - 500, y: 100, width: 500, height: 1000))
        #expect(CropMath.rotate(cw, clockwise: false, in: size.swapped) == r)
        var x = r
        var s = size
        for _ in 0..<4 { x = CropMath.rotate(x, clockwise: true, in: s); s = s.swapped }
        #expect(x == r)
    }

    @Test("自由比例拖动：不出图、不小于最小尺寸、框内拖动整体移动")
    func freeDrag() {
        let b = PixelSize(width: 1000, height: 800)
        let full = PixelRect(size: b)
        #expect(CropMath.drag(.right, start: full, dx: 300, dy: 0, bounds: b, ratio: nil, minSide: 16) == full)
        #expect(CropMath.drag(.right, start: full, dx: -2000, dy: 0, bounds: b, ratio: nil, minSide: 16).width == 16)
        let tl = CropMath.drag(.topLeft, start: full, dx: 100, dy: 50, bounds: b, ratio: nil, minSide: 16)
        #expect(tl == PixelRect(x: 100, y: 50, width: 900, height: 750))
        let small = PixelRect(x: 100, y: 100, width: 200, height: 200)
        #expect(CropMath.drag(.move, start: small, dx: 5000, dy: -5000, bounds: b, ratio: nil, minSide: 16)
                == PixelRect(x: 800, y: 0, width: 200, height: 200))
    }

    @Test("固定比例：各个把手怎么拖都保持比例（误差 ≤ 1 像素），而且不出图")
    func ratioDrag() {
        let b = PixelSize(width: 4032, height: 3024)
        let start = PixelRect(x: 1000, y: 800, width: 1200, height: 900)
        let handles: [CropHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for ratio in [1.0, 4.0 / 3.0, 3.0 / 4.0, 16.0 / 9.0, 2.0 / 3.0] {
            for h in handles {
                for (dx, dy) in [(300.0, 120.0), (-900.0, 40.0), (5000.0, 5000.0), (-5000.0, -5000.0), (17.0, -333.0)] {
                    let r = CropMath.drag(h, start: start, dx: dx, dy: dy, bounds: b, ratio: ratio, minSide: 16)
                    #expect(abs(Double(r.height) - Double(r.width) / ratio) <= 1, "\(h) \(ratio) \(dx),\(dy) → \(r)")
                    #expect(r.x >= 0 && r.y >= 0 && r.maxX <= b.width && r.maxY <= b.height)
                    #expect(min(r.width, r.height) >= 15)
                }
            }
        }
    }

    @Test("选比例：取当前框里最大的该比例框；横竖互换以中心为准、放不下时缩小")
    func fitAndSwap() {
        let b = PixelSize(width: 4032, height: 3024)
        #expect(CropMath.fit(PixelRect(size: b), ratio: 1, bounds: b) == PixelRect(x: 504, y: 0, width: 3024, height: 3024))
        #expect(CropMath.fit(PixelRect(size: b), ratio: 16.0 / 9.0, bounds: b).size == PixelSize(width: 4032, height: 2268))
        let swapped = CropMath.swap(PixelRect(size: b), ratio: 3.0 / 4.0, bounds: b)
        #expect(swapped.height == 3024 && swapped.width == 2268)
        #expect(swapped.x == (4032 - 2268) / 2)
    }

    @Test("比例：自由和 1:1 不能横竖互换，原始比例写成约分后的比例")
    func ratios() {
        let s = PixelSize(width: 4032, height: 3024)
        #expect(!CropRatio.free.canSwap(image: s))
        #expect(!CropRatio.square.canSwap(image: s))
        #expect(CropRatio.r16x9.canSwap(image: s))
        #expect(!CropRatio.original.canSwap(image: PixelSize(width: 500, height: 500)))
        #expect(CropRatio.label(for: s) == "4:3")
        #expect(CropRatio.label(for: PixelSize(width: 6000, height: 4000)) == "3:2")
        #expect(CropRatio.label(for: PixelSize(width: 1400, height: 854)) == "1.64:1")
        #expect(CropRatio.r4x3.widthOverHeight(image: s, portrait: true) == 0.75)
    }

    @Test("调整尺寸：只能缩小，像素和百分比换算，每边至少 1 像素")
    func resize() {
        let crop = PixelSize(width: 4032, height: 3024)
        #expect(ResizeMath.scale(forWidth: 5000, crop: crop) == nil)
        #expect(ResizeMath.scale(forWidth: 0, crop: crop) == nil)
        #expect(ResizeMath.scale(forWidth: 4032, crop: crop) == 1)
        let s = try! #require(ResizeMath.scale(forWidth: 1600, crop: crop))
        #expect(ResizeMath.output(crop: crop, scale: s) == PixelSize(width: 1600, height: 1200))
        #expect(ResizeMath.scale(forHeight: 3025, crop: crop) == nil)
        #expect(ResizeMath.scale(forPercent: 0) == nil && ResizeMath.scale(forPercent: 101) == nil)
        #expect(ResizeMath.output(crop: crop, scale: 0.4) == PixelSize(width: 1613, height: 1210))
        #expect(ResizeMath.percent(0.4) == 40)
        #expect(ResizeMath.output(crop: PixelSize(width: 3, height: 1), scale: 0.01) == PixelSize(width: 1, height: 1))
        #expect(ResizeMath.digits("12a3.4") == "1234")
    }

    @Test("编辑状态：旋转后框跟着转、固定比例横竖跟着换，复原回到进入时")
    @MainActor
    func session() throws {
        let item = MediaItem(url: URL(fileURLWithPath: "/tmp/x.jpg"), format: .standard, fileSize: 1, modificationDate: .now)
        let s = EditSession(item: item, imageSize: PixelSize(width: 4000, height: 3000), turns: 0, rawChoice: .jpeg)
        #expect(!s.isDirty && s.outputSize == PixelSize(width: 4000, height: 3000))
        s.setRatio(.r16x9)
        #expect(s.crop.size == PixelSize(width: 4000, height: 2250) && !s.portrait)
        s.rotate(clockwise: true)
        #expect(s.editedSize == PixelSize(width: 3000, height: 4000))
        #expect(s.crop.size == PixelSize(width: 2250, height: 4000) && s.portrait)
        s.swapOrientation()
        #expect(abs(Double(s.crop.width) / Double(s.crop.height) - 16.0 / 9.0) < 0.01)
        s.scale = 0.5
        #expect(s.isDirty)
        s.reset()
        #expect(!s.isDirty && s.crop == PixelRect(size: s.editedSize) && s.turns == 0)
        // 从浏览时的旋转开始（spec ED-03）
        let r = EditSession(item: item, imageSize: PixelSize(width: 4000, height: 3000), turns: 1, rawChoice: .jpeg)
        #expect(r.editedSize == PixelSize(width: 3000, height: 4000) && !r.isDirty)
    }
}

// MARK: - 命名、格式、排序

@Suite("编辑：命名和格式")
struct EditNamingTests {
    @Test("副本名：原名 + 后缀，扩展名大小写不变；重名依次加序号")
    func naming() {
        let original = URL(fileURLWithPath: "/tmp/a/IMG_2052.JPG")
        let first = EditNaming.baseName("IMG_2052", attempt: 1)
        let second = EditNaming.baseName("IMG_2052", attempt: 2)
        #expect(first.hasPrefix("IMG_2052 ") && first != second && second.hasSuffix(" 2"))
        #expect(EditNaming.copyURL(for: original, exists: { _ in false }).lastPathComponent == first + ".JPG")
        var taken: Set<String> = [first + ".JPG", second + ".JPG"]
        let third = EditNaming.copyURL(for: original, exists: { taken.contains($0.lastPathComponent) })
        #expect(third.lastPathComponent == EditNaming.baseName("IMG_2052", attempt: 3) + ".JPG")
        taken = []
        #expect(EditNaming.copyURL(for: original, ext: "jpg", exists: { _ in false }).pathExtension == "jpg")
    }

    @Test("输出格式：原格式、WebP 改 JPEG（带透明改 PNG）、RAW 存 JPEG 或 HEIF")
    func targets() {
        func item(_ name: String) -> MediaItem {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!, fileSize: 1, modificationDate: .now)
        }
        let writable: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.tiff", "com.microsoft.bmp"]
        let jpg = EditTarget.decide(for: item("a.JPG"), sourceType: "public.jpeg", hasAlpha: false, rawChoice: .jpeg, writable: writable)
        #expect(jpg == EditTarget(typeIdentifier: "public.jpeg", pathExtension: "JPG", reason: .same) && jpg.canReplaceOriginal)
        let webp = EditTarget.decide(for: item("a.webp"), sourceType: "org.webmproject.webp", hasAlpha: false, rawChoice: .jpeg, writable: writable)
        #expect(webp.isJPEG && webp.pathExtension == "jpg" && webp.reason == .unwritable("WebP") && !webp.canReplaceOriginal)
        let alpha = EditTarget.decide(for: item("a.webp"), sourceType: "org.webmproject.webp", hasAlpha: true, rawChoice: .jpeg, writable: writable)
        #expect(alpha.isPNG && alpha.pathExtension == "png")
        let raw = EditTarget.decide(for: item("a.ARW"), sourceType: "com.sony.arw-raw-image", hasAlpha: false, rawChoice: .jpeg, writable: writable)
        #expect(raw.isJPEG && raw.reason == .raw && !raw.canReplaceOriginal)
        let rawHeif = EditTarget.decide(for: item("a.NEF"), sourceType: nil, hasAlpha: false, rawChoice: .heif, writable: writable)
        #expect(rawHeif.isHEIF && rawHeif.pathExtension == "heic")
        let heif = EditTarget.decide(for: item("a.heif"), sourceType: "public.heif", hasAlpha: false, rawChoice: .jpeg, writable: writable)
        #expect(heif.isHEIF && heif.pathExtension == "heif" && heif.reason == .same)
        // 本机实测：WebP 系统写不出
        #expect(!EditTarget.writableTypes.contains("org.webmproject.webp"))
        #expect(EditTarget.supportsOrientationOnly("public.jpeg") && !EditTarget.supportsOrientationOnly("com.microsoft.bmp")
                && !EditTarget.supportsOrientationOnly("public.png"))
    }

    @Test("视频、GIF、SVG 不能编辑")
    func editable() {
        func item(_ name: String) -> MediaItem {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!, fileSize: 1, modificationDate: .now)
        }
        #expect(BrowserModel.isEditable(item("a.jpg")) && BrowserModel.isEditable(item("a.ARW")) && BrowserModel.isEditable(item("a.webp")))
        #expect(!BrowserModel.isEditable(item("a.gif")) && !BrowserModel.isEditable(item("a.svg")) && !BrowserModel.isEditable(item("a.mov")))
    }

    @Test("排序：副本紧跟在原图后面")
    func order() {
        let copy = EditNaming.baseName("IMG_2052", attempt: 1) + ".jpg"
        let copy2 = EditNaming.baseName("IMG_2052", attempt: 2) + ".jpg"
        let sorted = ["IMG_2053.jpg", copy2, copy, "IMG_2052.jpg", "IMG_2051.jpg"].sorted(by: FolderScanner.naturalLess)
        #expect(sorted == ["IMG_2051.jpg", "IMG_2052.jpg", copy, copy2, "IMG_2053.jpg"])
    }
}

// MARK: - 真实写出

@Suite("编辑：写出文件")
struct EditWriterTests {
    @Test("JPEG 裁切 + 缩小：尺寸和界面一致，拍摄信息保留，方向归一，原图逐字节和修改时间不变，不留临时文件")
    func jpeg() throws {
        let dir = try MetaFixtures.copy(["IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2052.jpg")
        let sha = try MetaFixtures.sha(url)
        let mtime = MetaFixtures.mtime(url)
        let p = try plan(url, crop: PixelRect(x: 300, y: 200, width: 3000, height: 2000), scale: 0.5)
        let out = try EditWriter.saveCopy(p, target: try target(url))
        #expect(out.deletingLastPathComponent().lastPathComponent == dir.lastPathComponent)
        #expect(out.lastPathComponent == EditNaming.baseName("IMG_2052", attempt: 1) + ".jpg")
        #expect(EditWriter.orientedSize(out) == PixelSize(width: 1500, height: 1000))
        #expect(orientation(out) == 1)
        #expect(exif(out, kCGImagePropertyExifDateTimeOriginal) as? String == "2020:08:01 09:12:12")
        #expect(exif(out, kCGImagePropertyExifPixelXDimension) as? Int == 1500)
        #expect(MetaFixtures.properties(out, kCGImagePropertyGPSDictionary)?[kCGImagePropertyGPSLatitude] != nil)
        #expect((MetaFixtures.properties(out, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFModel] as? String)?.contains("iPhone") == true)
        #expect(try MetaFixtures.sha(url) == sha)
        let after = MetaFixtures.mtime(url)
        #expect(after.tv_sec == mtime.tv_sec && after.tv_nsec == mtime.tv_nsec)
        #expect(!names(dir).contains { SafeReplace.isOwnTemp($0) })
        // 再存一次：重名加序号
        let again = try EditWriter.saveCopy(p, target: try target(url))
        #expect(again.lastPathComponent == EditNaming.baseName("IMG_2052", attempt: 2) + ".jpg")
    }

    @Test("HEIC、PNG、TIFF、BMP：裁切 + 旋转 + 缩小后的尺寸正确，沿用原格式", arguments: ["IMG_2031.heic", "harbor_night.png", "scan_003.tif", "old_scan.bmp"])
    func formats(_ name: String) throws {
        let dir = try MetaFixtures.copy([name])
        let url = dir.appendingPathComponent(name)
        let sha = try MetaFixtures.sha(url)
        let size = try #require(EditWriter.orientedSize(url))
        // 转 90° 后的图上裁一块，再缩到 50%
        let crop = PixelRect(x: 10, y: 20, width: size.height / 2, height: size.width / 2)
        let p = try plan(url, turns: 1, crop: crop, scale: 0.5)
        let t = try target(url)
        #expect(t.reason == .same)
        let out = try EditWriter.saveCopy(p, target: t)
        #expect(out.pathExtension == url.pathExtension)
        #expect(EditWriter.orientedSize(out) == p.output)
        #expect(EditWriter.sourceInfo(out).typeIdentifier == EditWriter.sourceInfo(url).typeIdentifier)
        #expect(try MetaFixtures.sha(url) == sha)
        if name.hasSuffix("heic") {
            #expect(MetaFixtures.properties(out, kCGImagePropertyGPSDictionary) != nil)
            #expect(exif(out, kCGImagePropertyExifDateTimeOriginal) != nil)
        }
    }

    @Test("只旋转的 JPEG、HEIC、TIFF：副本只改方向标记，画面数据与原图完全相同", arguments: ["IMG_2052.jpg", "IMG_2031.heic", "scan_003.tif"])
    func losslessCopy(_ name: String) throws {
        let dir = try MetaFixtures.copy([name])
        let url = dir.appendingPathComponent(name)
        let size = try #require(EditWriter.orientedSize(url))
        let p = try plan(url, turns: 1)
        #expect(p.isRotationOnly)
        let out = try EditWriter.saveCopy(p, target: try target(url))
        #expect(EditWriter.orientedSize(out) == size.swapped)
        #expect(orientation(out) == 6)
        #expect(try EditWriter.storedPixels(out) == EditWriter.storedPixels(url))
    }

    @Test("PNG 只旋转：按像素转正写出（无损编码），方向为 1")
    func pngRotation() throws {
        let dir = try MetaFixtures.copy(["harbor_night.png"])
        let url = dir.appendingPathComponent("harbor_night.png")
        let out = try EditWriter.saveCopy(try plan(url, turns: 3), target: try target(url))
        #expect(EditWriter.orientedSize(out) == PixelSize(width: 1200, height: 1600))
        #expect(orientation(out) == 1)
    }

    @Test("没有任何改动：副本和原图逐字节相同")
    func unchanged() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let out = try EditWriter.saveCopy(try plan(url), target: try target(url))
        #expect(try MetaFixtures.sha(out) == MetaFixtures.sha(url))
    }

    @Test("保存旋转改原图：画面数据不变、方向改对；改回去后方向复原", arguments: ["IMG_2052.jpg", "IMG_2031.heic", "scan_003.tif"])
    func rotateInPlace(_ name: String) throws {
        let dir = try MetaFixtures.copy([name])
        let url = dir.appendingPathComponent(name)
        let pixels = try EditWriter.storedPixels(url)
        let (old, new) = try EditWriter.rotateInPlace(url, quarterTurns: 1)
        #expect(old == 1 && new == 6 && orientation(url) == 6)
        #expect(try EditWriter.storedPixels(url) == pixels)
        try EditWriter.rotateInPlace(url, quarterTurns: 2)
        #expect(orientation(url) == 8)
        try EditWriter.setOrientation(url, to: old)
        #expect(orientation(url) == 1)
        #expect(try EditWriter.storedPixels(url) == pixels)
        #expect(!names(dir).contains { SafeReplace.isOwnTemp($0) })
    }

    @Test("BMP 不能只改方向：拒绝，原图不变")
    func bmpRotateRefused() throws {
        let dir = try MetaFixtures.copy(["old_scan.bmp"])
        let url = dir.appendingPathComponent("old_scan.bmp")
        let sha = try MetaFixtures.sha(url)
        #expect(throws: EditSaveError.self) { try EditWriter.rotateInPlace(url, quarterTurns: 1) }
        #expect(try MetaFixtures.sha(url) == sha)
    }

    @Test("替换原图：原图进废纸篓（逐字节不变），新图放在原位置；放回原图后逐字节恢复")
    func replace() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        let item = try MetaFixtures.item(url)
        let p = try plan(url, crop: PixelRect(x: 0, y: 0, width: 1200, height: 900))
        let entry = try EditWriter.replaceOriginal(p, target: try target(url), item: item)
        #expect(try MetaFixtures.sha(entry.trashedURL) == sha)
        #expect(EditWriter.orientedSize(url) == PixelSize(width: 1200, height: 900))
        #expect(names(dir) == ["IMG_2034.jpg"])
        // 撤销的做法：编辑后的进废纸篓，原图放回
        _ = try TrashService.trash(url)
        try TrashService.restore(entry)
        #expect(try MetaFixtures.sha(url) == sha)
    }

    @Test("文件夹不可写：保存失败，说是不可写，文件夹内容不变")
    func readOnlyFolder() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let before = names(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: EditSaveError.notWritable(folder: dir.lastPathComponent)) {
            try EditWriter.saveCopy(try plan(url, scale: 0.5), target: try target(url))
        }
        #expect(names(dir) == before)
    }

    @Test("原图不见了：保存失败，说是原图已被移走")
    func vanished() throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let p = try plan(url, scale: 0.5)
        let t = try target(url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: EditSaveError.vanished) { try EditWriter.saveCopy(p, target: t) }
    }

    @Test("RAW 编辑后存出 JPEG 或 HEIF，RAW 本身不变（本机有样张时）")
    func raw() throws {
        guard let name = MetaFixtures.rawSamples.first(where: { $0.uppercased().hasSuffix("ARW") || $0.uppercased().hasSuffix("DNG") }) else { return }
        let dir = try MetaFixtures.copy([name], from: MetaFixtures.raw)
        let url = dir.appendingPathComponent(name)
        let sha = try MetaFixtures.sha(url)
        let size = try #require(EditWriter.orientedSize(url))
        let crop = PixelRect(x: 100, y: 100, width: size.width / 2, height: size.height / 2)
        for (format, ext) in [(RawExportFormat.jpeg, "jpg"), (.heif, "heic")] {
            let t = try target(url, raw: format)
            let out = try EditWriter.saveCopy(try plan(url, crop: crop, scale: 0.5), target: t)
            #expect(out.pathExtension == ext)
            #expect(EditWriter.orientedSize(out) == ResizeMath.output(crop: crop.size, scale: 0.5))
            #expect(exif(out, kCGImagePropertyExifDateTimeOriginal) != nil)
        }
        #expect(try MetaFixtures.sha(url) == sha)
    }
}

// MARK: - 模型流程

@Suite("编辑：模型流程")
@MainActor
struct EditModelTests {
    private func ready(_ folder: URL, _ name: String) async throws -> BrowserModel {
        let m = try makeModel(folder, select: name)
        #expect(await waitFor { m.canEditCurrent })
        await waitFor { m.ratingsLoaded }
        return m
    }

    @Test("编辑中数字键不评星、方向键不切图；Esc 放弃，不产生文件")
    func keysAndCancel() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg"])
        let before = names(dir)
        let m = try await ready(dir, "IMG_2034.jpg")
        m.enterEdit()
        let s = try #require(m.edit)
        #expect(m.handleKey(try key(20, "3")))
        #expect((m.ratings[s.item.url] ?? 0) == 0 && m.undoHistory.entries.isEmpty)
        #expect(m.handleKey(try key(124, "\u{F703}")))
        #expect(m.current?.name == "IMG_2034.jpg")
        #expect(m.handleKey(try key(15, "r")))
        #expect(s.turns == 1)
        #expect(m.handleKey(try key(53, "\u{1B}")))
        #expect(m.edit == nil && m.rotation == 0)
        #expect(names(dir) == before)
    }

    @Test("不能编辑的文件上按 E 无反应")
    func notEditable() async throws {
        let dir = try MetaFixtures.copy(["gears.gif"])
        let m = try makeModel(dir, select: "gears.gif")
        await waitFor { m.displayed != nil }
        #expect(m.editUnsupported)
        #expect(m.handleKey(try key(14, "e")))
        #expect(m.edit == nil)
    }

    @Test("另存副本：跳到新文件（紧跟原图），星级带到新文件的 .xmp；撤销后副本进废纸篓、回到原图")
    func saveCopyAndUndo() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg", "IMG_2052.jpg"])
        let m = try await ready(dir, "IMG_2034.jpg")
        let original = try #require(m.current)
        m.setRating(4, for: original, old: 0, recordUndo: false)
        await m.ratingWriter.waitUntilIdle()
        await waitFor { m.pendingRatingWrites == 0 }
        m.enterEdit()
        let s = try #require(m.edit)
        s.crop = PixelRect(x: 0, y: 0, width: 1200, height: 900)
        s.scale = 0.5
        m.saveEdit()
        #expect(await waitFor { m.edit == nil })
        let copyName = EditNaming.baseName("IMG_2034", attempt: 1) + ".jpg"
        let copy = try #require(m.current)
        #expect(copy.name == copyName)
        #expect(EditWriter.orientedSize(copy.url) == PixelSize(width: 600, height: 450))
        #expect(m.items.map(\.name) == ["IMG_2034.jpg", copyName, "IMG_2052.jpg"])
        #expect(m.ratings[copy.url] == 4)
        let sidecar = dir.appendingPathComponent(EditNaming.baseName("IMG_2034", attempt: 1) + ".xmp")
        let packet = try XMPPacket(data: Data(contentsOf: sidecar))
        #expect(packet.rating == 4)
        #expect(m.toast?.action == .undoEdit)
        await m.undoLast()
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(m.current?.name == "IMG_2034.jpg")
        #expect(m.items.count == 2)
    }

    @Test("替换原图：确认后原图进废纸篓，撤销后原图逐字节回来")
    func replaceAndUndo() async throws {
        let dir = try MetaFixtures.copy(["IMG_2034.jpg"])
        let url = dir.appendingPathComponent("IMG_2034.jpg")
        let sha = try MetaFixtures.sha(url)
        let m = try await ready(dir, "IMG_2034.jpg")
        m.enterEdit()
        let s = try #require(m.edit)
        s.scale = 0.25
        #expect(m.handleKey(try key(36, "\r", .option)))
        #expect(s.confirmReplace)
        #expect(m.handleKey(try key(36, "\r")))
        #expect(await waitFor { m.edit == nil })
        #expect(EditWriter.orientedSize(url) == PixelSize(width: 600, height: 450))
        #expect(m.undoMenuTitle == String(localized: "撤销“替换原图”"))
        await m.undoLast()
        #expect(try MetaFixtures.sha(url) == sha)
        #expect(m.current?.name == "IMG_2034.jpg")
    }

    @Test("浏览时保存旋转（JPEG）：改原图方向、画面数据不变；⌘Z 改回")
    func saveRotation() async throws {
        let dir = try MetaFixtures.copy(["IMG_2052.jpg"])
        let url = dir.appendingPathComponent("IMG_2052.jpg")
        let pixels = try EditWriter.storedPixels(url)
        let m = try await ready(dir, "IMG_2052.jpg")
        m.rotate(1)
        #expect(m.showsSaveRotation && m.currentSupportsLosslessRotation)
        m.saveRotation()
        #expect(await waitFor { orientation(url) == 6 && m.rotation == 0 })
        #expect(try EditWriter.storedPixels(url) == pixels)
        #expect(names(dir) == ["IMG_2052.jpg"])
        await waitFor { !m.trashBusy }
        await m.undoLast()
        #expect(orientation(url) == 1)
    }

    @Test("浏览时保存旋转（PNG）：做不到只改方向，另存副本，原图不变")
    func saveRotationCopy() async throws {
        let dir = try MetaFixtures.copy(["harbor_night.png"])
        let url = dir.appendingPathComponent("harbor_night.png")
        let sha = try MetaFixtures.sha(url)
        let m = try await ready(dir, "harbor_night.png")
        m.rotate(1)
        #expect(!m.currentSupportsLosslessRotation)
        m.saveRotation()
        let copy = dir.appendingPathComponent(EditNaming.baseName("harbor_night", attempt: 1) + ".png")
        #expect(await waitFor { m.current?.name == copy.lastPathComponent })
        #expect(EditWriter.orientedSize(copy) == PixelSize(width: 1200, height: 1600))
        #expect(try MetaFixtures.sha(url) == sha)
    }
}
