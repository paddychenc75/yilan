import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Yilan

// MARK: - 工具

private func freshDefaults() -> UserDefaults {
    let name = "yilan-load-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func pixel(_ width: Int = 1, _ height: Int = 1) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

private func fakeItem(_ name: String, folder: String = "/tmp/yilan-fake") -> MediaItem {
    let url = URL(fileURLWithPath: "\(folder)/\(name)")
    return MediaItem(url: url, format: SupportedFormats.format(forExtension: url.pathExtension)!,
                     fileSize: 100, modificationDate: Date(timeIntervalSince1970: 1_000))
}

/// 等到条件成立（最多 timeout）
@discardableResult
private func waitUntil(timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
                       _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// 可控的假解码：按 URL 挡住、统计调用和取消次数
private actor FakeDecoder {
    private(set) var calls: [URL: Int] = [:]
    /// 开始解码的先后（文件名、版本）
    private(set) var log: [(name: String, variant: ImageDecoder.Variant)] = []
    private(set) var cancellations = 0
    /// 这些 URL 的解码会一直等，直到 release
    private var blocked: Set<URL> = []
    var failure: DecodeFailure?
    var delay: Duration = .zero

    func block(_ url: URL) { blocked.insert(url) }
    func release(_ url: URL) { blocked.remove(url) }
    func setFailure(_ f: DecodeFailure?) { failure = f }
    func setDelay(_ d: Duration) { delay = d }
    func callCount(_ url: URL) -> Int { calls[url, default: 0] }

    func decode(_ item: MediaItem, _ variant: ImageDecoder.Variant) async throws -> DecodedImage {
        calls[item.url, default: 0] += 1
        log.append((item.url.lastPathComponent, variant))
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            while blocked.contains(item.url) { try await Task.sleep(for: .milliseconds(2)) }
        } catch {
            cancellations += 1
            throw error
        }
        if let failure { throw failure }
        return DecodedImage(image: pixel(), pixelSize: CGSize(width: 1, height: 1))
    }
}

private func pipeline(_ fake: FakeDecoder, queuedLimit: Int = ImagePipeline.queuedLimit) -> ImagePipeline {
    ImagePipeline(queuedLimit: queuedLimit) { item, variant in try await fake.decode(item, variant) }
}

// MARK: - 管线

@Suite("大图管线：合并请求、取消")
struct PipelineTests {
    let a = fakeItem("a.jpg")
    let variant = ImageDecoder.Variant.display(maxPixel: 1000)

    @Test("同一张图同时请求两次，只解码一次")
    func dedupe() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        await fake.block(a.url)
        async let first = p.image(a, variant)
        async let second = p.image(a, variant)
        await waitUntil { await fake.callCount(a.url) == 1 }
        try await Task.sleep(for: .milliseconds(20))
        await fake.release(a.url)
        let (x, y) = try await (first, second)
        #expect(x === y)
        #expect(await fake.callCount(a.url) == 1)
        // 之后命中缓存
        _ = try await p.image(a, variant)
        #expect(await fake.callCount(a.url) == 1)
    }

    @Test("缓存上限：普通屏幕 400 MB；5K、6K 屏放得下当前和前后各 2 张；最多 800 MB")
    func costLimitFollowsDisplay() {
        let mb = 1024 * 1024
        #expect(ImagePipeline.costLimit(displayMaxPixel: 3456) == 400 * mb)   // 16 寸 MacBook Pro
        for px in [5120, 6016] {                                             // 5K、6K
            let one = px * (px * 2 / 3) * 4
            #expect(ImagePipeline.costLimit(displayMaxPixel: px) >= one * 5)
        }
        #expect(ImagePipeline.costLimit(displayMaxPixel: 20_000) == 800 * mb)
    }

    @Test("cancelAll 取消预加载，预加载不会自己重试")
    func cancelPreload() async {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        await fake.block(a.url)
        await p.preload(a, variant)
        #expect(await waitUntil { await fake.callCount(a.url) == 1 })
        await p.cancelAll(except: [])
        #expect(await waitUntil { await fake.cancellations == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await fake.callCount(a.url) == 1)
        #expect(await !p.isInFlight(a, variant))
    }

    @Test("cancelAll 只保留 keep 里的")
    func cancelKeeps() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        let b = fakeItem("b.jpg")
        await fake.block(a.url)
        await fake.block(b.url)
        await p.preload(a, variant)
        await p.preload(b, variant)
        #expect(await waitUntil {
            let (x, y) = (await fake.callCount(a.url), await fake.callCount(b.url))
            return x == 1 && y == 1
        })
        await p.cancelAll(except: [b.url])
        #expect(await !p.isInFlight(a, variant))
        #expect(await p.isInFlight(b, variant))
        await fake.release(b.url)
        #expect(await waitUntil { await p.cached(b, variant) != nil })
    }

    @Test("正在等的解码被别人取消：调用方没被取消就重新解码")
    func foregroundRetries() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        await fake.block(a.url)
        let waiter = Task { try await p.image(a, variant) }
        #expect(await waitUntil { await fake.callCount(a.url) == 1 })
        await p.cancelAll(except: [])
        #expect(await waitUntil { await fake.callCount(a.url) == 2 })
        await fake.release(a.url)
        _ = try await waiter.value
        #expect(await p.cached(a, variant) != nil)
    }

    @Test("旧解码结束时，新解码仍在进行中记录里")
    func inFlightRaceKeepsNewEntry() async throws {
        // 第一次解码被取消后仍然跑完（系统解码函数中途停不下来），两次各挡一道门
        let gates = GatedDecoder()
        let p = ImagePipeline { item, _ in try await gates.decode(item) }
        let old = Task { try await p.image(a, variant) }
        #expect(await waitUntil { await gates.calls == 1 })
        await p.cancelAll(except: [])
        let new = Task { try await p.image(a, variant) }
        #expect(await waitUntil { await gates.calls == 2 })
        await gates.open(1)
        _ = try await old.value
        // 第一次的等待方结束了，第二次的记录必须还在：再来一个请求应当合并到它，而不是第三次解码
        #expect(await p.isInFlight(a, variant))
        await gates.open(2)
        _ = try await new.value
        #expect(await gates.calls == 2)
    }

    @Test("文件不见了不记住失败；损坏的记住；clearFailures 后重试")
    func failuresRemembered() async {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        await fake.setFailure(DecodeFailure(reason: "x", detail: "", kind: .missing))
        _ = try? await p.image(a, variant)
        #expect(await p.rememberedFailure(a, variant) == nil)
        _ = try? await p.image(a, variant)
        #expect(await fake.callCount(a.url) == 2)

        await fake.setFailure(DecodeFailure(reason: "y", detail: "", kind: .corrupt))
        _ = try? await p.image(a, variant)
        #expect(await p.rememberedFailure(a, variant)?.kind == .corrupt)
        _ = try? await p.image(a, variant)
        #expect(await fake.callCount(a.url) == 3)

        await p.clearFailures()
        await fake.setFailure(nil)
        #expect((try? await p.image(a, variant)) != nil)
        #expect(await fake.callCount(a.url) == 4)
    }
}

// MARK: - 排队解码

@Suite("排队解码：名额、先后、插队、取消")
struct DecodeQueueTests {
    let variant = ImageDecoder.Variant.display(maxPixel: 1000)

    @Test("排队口：名额用完后排队，按 order 大的先、一样大先来先走")
    func gateOrder() async throws {
        let gate = DecodeGate(limit: 1)
        gate.register(1, order: 0)
        gate.register(2, order: 5)
        gate.register(3, order: 9)
        gate.register(4, order: 5)
        #expect(gate.runningCount == 1)
        #expect(gate.waitingCount == 3)
        var admitted: [Int] = []
        var ticket = try await gate.enter(1)
        for _ in 0..<3 {
            gate.leave(ticket)
            let next = [2, 3, 4].first { !admitted.contains($0) && !gate.isWaiting($0) }!
            admitted.append(next)
            ticket = try await gate.enter(next)
        }
        gate.leave(ticket)
        #expect(admitted == [3, 2, 4])
        #expect(gate.runningCount == 0)
    }

    @Test("排队口：排队中被取消不占名额；插队的不占名额")
    func gateCancelAndPromote() async throws {
        let gate = DecodeGate(limit: 1)
        gate.register(1, order: 0)
        gate.register(2, order: 0)
        gate.register(3, order: 0)
        let first = try await gate.enter(1)
        // 2 在排队时被取消：enter 抛出，不再占位置
        let waiting = Task { try await gate.enter(2) }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // 3 插队：名额还被 1 占着也立即放行
        gate.promote(3)
        let promoted = try await gate.enter(3)
        #expect(!promoted.counted)
        #expect(gate.runningCount == 1)
        gate.leave(promoted)
        gate.leave(first)
        #expect(gate.runningCount == 0)
        #expect(gate.waitingCount == 0)
    }

    @Test("预加载同时只解 queuedLimit 个；排队时被取消的根本不解码")
    func preloadLimitAndCancel() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake, queuedLimit: 1)
        let (a, b, c) = (fakeItem("a.jpg"), fakeItem("b.jpg"), fakeItem("c.jpg"))
        await fake.block(a.url)
        await p.preload(a, variant)
        await p.preload(b, variant)
        await p.preload(c, variant)
        #expect(await waitUntil { await fake.callCount(a.url) == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fake.callCount(b.url) == 0)
        #expect(await p.isQueued(b, variant))
        // 切走了：b、c 不再需要
        await p.cancelAll(except: [a.url])
        await fake.release(a.url)
        #expect(await waitUntil { await p.cached(a, variant) != nil })
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fake.callCount(b.url) == 0)
        #expect(await fake.callCount(c.url) == 0)
        #expect(await !p.isInFlight(b, variant))
        #expect(p.gate.runningCount == 0)
    }

    @Test("排队中的预加载变成当前要看的：立即开始，不等前面的")
    func currentJumpsQueue() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake, queuedLimit: 1)
        let (a, b) = (fakeItem("a.jpg"), fakeItem("b.jpg"))
        await fake.block(a.url)
        await p.preload(a, variant)
        await p.preload(b, variant)
        #expect(await waitUntil { await fake.callCount(a.url) == 1 })
        #expect(await p.isQueued(b, variant))
        // a 还挡着，b 也能解出来
        let image = try await p.image(b, variant)
        #expect(image.pixelSize.width == 1)
        #expect(await fake.callCount(b.url) == 1)
        await fake.release(a.url)
        #expect(await waitUntil { await p.cached(a, variant) != nil })
        #expect(p.gate.runningCount == 0)
    }

    @Test("RAW 的高清版进了缓存，内嵌预览就从缓存里去掉（省内存）")
    func previewDroppedAfterFull() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake)
        let raw = fakeItem("a.arw")
        _ = try await p.image(raw, .rawPreview)
        #expect(await p.cached(raw, .rawPreview) != nil)
        _ = try await p.image(raw, variant)
        #expect(await p.cached(raw, variant) != nil)
        #expect(await p.cached(raw, .rawPreview) == nil)
    }

    @Test("排队的按 order 先后开始；后来的 order 更大可以排到前面")
    func preloadOrder() async throws {
        let fake = FakeDecoder()
        let p = pipeline(fake, queuedLimit: 1)
        let items = ["a", "b", "c", "d"].map { fakeItem("\($0).jpg") }
        await fake.block(items[0].url)
        await p.preload(items[0], variant, order: 0)
        await p.preload(items[1], variant, order: 1)
        await p.preload(items[2], variant, order: 5)
        await p.preload(items[3], variant, order: 3)
        // b 被再次要求，排到最前
        await p.preload(items[1], variant, order: 9)
        await fake.release(items[0].url)
        #expect(await waitUntil { await fake.log.count == 4 })
        #expect(await fake.log.map(\.name) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    @Test("预加载：预览前后各 2 张立即开始、近的在前；RAW 高清版只排翻页方向上的，新一轮排在旧一轮前面")
    func neighborJobs() throws {
        let n1 = fakeItem("n1.arw"), n2 = fakeItem("n2.jpg"), p1 = fakeItem("p1.arw"), p2 = fakeItem("p2.arw")
        let display = ImageDecoder.Variant.display(maxPixel: 3000)
        let jobs = PreloadOrder.jobs(ahead: [n1, n2], behind: [p1, p2], generation: 7, includeFull: true) { _ in display }
        #expect(jobs.map(\.item.url.lastPathComponent) == ["n1.arw", "p1.arw", "n2.jpg", "p2.arw", "n1.arw"])
        #expect(jobs.map(\.variant) == [.rawPreview, .rawPreview, display, .rawPreview, display])
        // 预览和普通图片不排队；只有 RAW 高清版排队，而且排在当前这张的高清版后面
        #expect(jobs.prefix(4).allSatisfy { $0.order == nil })
        let full = try #require(jobs.last?.order)
        #expect(full < PreloadOrder.currentFull(7))
        // 当前这张还在解高清：只预加载预览
        let previewsOnly = PreloadOrder.jobs(ahead: [n1], behind: [p1], generation: 7, includeFull: false) { _ in display }
        #expect(previewsOnly.allSatisfy { $0.variant == .rawPreview })
        // 往前翻（ahead 是前面的）：高清版跟着方向走
        let back = PreloadOrder.jobs(ahead: [p1, p2], behind: [n1], generation: 7, includeFull: true) { _ in display }
        #expect(back.filter { $0.order != nil }.map(\.item.url.lastPathComponent) == ["p1.arw", "p2.arw"])
        #expect(back.filter { $0.order != nil }.map { $0.order! } == [750, 749])
        // 新一轮的排在旧一轮的任何一项之前
        #expect(PreloadOrder.currentFull(6) < full)
    }
}

/// 每次调用各有一道门，按调用次序放行；不理会取消
private actor GatedDecoder {
    private(set) var calls = 0
    private var opened: Set<Int> = []

    func open(_ n: Int) { opened.insert(n) }

    func decode(_ item: MediaItem) async throws -> DecodedImage {
        calls += 1
        let n = calls
        while !opened.contains(n) { try? await Task.sleep(for: .milliseconds(2)) }
        return DecodedImage(image: pixel(), pixelSize: CGSize(width: 1, height: 1))
    }
}

// MARK: - 解码（样例文件）

/// 把 app/Fixtures/sample 复制到临时目录（测试会删改文件，不动仓库里的）
private func fixtureCopy() throws -> URL {
    let source = MetaFixtures.sample   // scripts/run-tests.sh 会指向 /tmp 里的镜像
    let dest = URL(fileURLWithPath: "/tmp/yilan-fixtures-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: dest)
    return dest
}

private func realItem(_ url: URL) throws -> MediaItem {
    let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return MediaItem(url: url, format: try #require(SupportedFormats.format(forExtension: url.pathExtension)),
                     fileSize: Int64(v.fileSize ?? 0), modificationDate: v.contentModificationDate ?? .distantPast)
}

private func decodeFailure(_ item: MediaItem, _ variant: ImageDecoder.Variant = .display(maxPixel: 2000)) async -> DecodeFailure? {
    do {
        _ = try await ImageDecoder.decode(item, variant: variant)
        return nil
    } catch {
        return error as? DecodeFailure
    }
}

@Suite("解码：样例文件")
struct DecoderFixtureTests {
    @Test("损坏的 JPEG：报“已损坏”")
    func broken() async throws {
        let dir = try fixtureCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failure = try #require(await decodeFailure(try realItem(dir.appendingPathComponent("broken.jpg"))))
        #expect(failure.kind == .corrupt)
        #expect(failure.reason == String(localized: "文件已损坏，或者不是有效的 \("JPEG") 图片。"))
    }

    @Test("文件被删掉：报“已被移走或删除”，不是“已损坏”")
    func missing() async throws {
        let dir = try fixtureCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aurora.jpg")
        let item = try realItem(url)
        try FileManager.default.removeItem(at: url)
        let failure = try #require(await decodeFailure(item))
        #expect(failure.kind == .missing)
        #expect(failure.reason == String(localized: "文件已被移走或删除。"))
        // 视频也一样
        let video = dir.appendingPathComponent("river.mp4")
        let videoItem = try realItem(video)
        try FileManager.default.removeItem(at: video)
        #expect(await decodeFailure(videoItem)?.kind == .missing)
    }

    @Test("文件被删掉又放回来：管线没有记住失败，可以重新打开")
    func missingThenRestored() async throws {
        let dir = try fixtureCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aurora.jpg")
        let backup = dir.appendingPathComponent("aurora.bak")
        let item = try realItem(url)
        try FileManager.default.moveItem(at: url, to: backup)
        let p = ImagePipeline()
        let variant = ImageDecoder.Variant.display(maxPixel: 800)
        await #expect(throws: DecodeFailure.self) { try await p.image(item, variant) }
        try FileManager.default.moveItem(at: backup, to: url)
        let image = try await p.image(item, variant)
        #expect(max(image.image.width, image.image.height) <= 800)
    }

    @Test("GIF：所有帧的内存不超过预算，整段时长不变")
    func gifBudget() throws {
        let dir = try fixtureCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try realItem(dir.appendingPathComponent("gears.gif"))
        let full = try ImageDecoder.decodeAnimated(item, maxPixel: nil)
        #expect(full.isAnimated)
        #expect(full.memoryCost <= ImageDecoder.animationMemoryBudget)
        // 预算只够几帧：缩小尺寸、隔帧取
        let budget = full.memoryCost / 8
        let small = try ImageDecoder.decodeAnimated(item, maxPixel: nil, memoryBudget: budget)
        #expect(small.memoryCost <= budget)
        #expect(small.frames.count <= full.frames.count)
        let total = { (d: DecodedImage) in d.frameDurations.reduce(0, +) }
        if small.isAnimated { #expect(abs(total(small) - total(full)) < 0.001) }
    }

    @Test("动图计划：超大动图按预算缩小、隔帧")
    func animationPlan() {
        let budget = ImageDecoder.animationMemoryBudget
        // 4000 × 3000、1000 帧：每帧 48 MB，远超预算
        let plan = ImageDecoder.animationPlan(frameCount: 1000, pixelSize: CGSize(width: 4000, height: 3000), target: 4000, budget: budget)
        #expect(plan.maxPixel >= ImageDecoder.minAnimationPixel)
        let scale = Double(plan.maxPixel) / 4000
        let frameBytes = Int(4000 * scale * 4) * Int(3000 * scale)
        let frames = (1000 + plan.step - 1) / plan.step
        #expect(frameBytes * frames <= budget)
        // 小动图不受影响
        let tiny = ImageDecoder.animationPlan(frameCount: 30, pixelSize: CGSize(width: 400, height: 300), target: 400, budget: budget)
        #expect(tiny == .init(maxPixel: 400, step: 1))
        // 帧数超过 600：隔帧取，不截掉后半段
        let long = ImageDecoder.animationPlan(frameCount: 1500, pixelSize: CGSize(width: 100, height: 100), target: 100, budget: budget)
        #expect(long.step == 3)
    }

    @Test("SVG：按要求的尺寸栅格化")
    func svg() async throws {
        let dir = try fixtureCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try realItem(dir.appendingPathComponent("mountains.svg"))
        let image = try await ImageDecoder.decode(item, variant: .display(maxPixel: 512))
        #expect(max(image.image.width, image.image.height) == 512)
    }

    @Test("超大图：原始分辨率也只解到 16384 像素")
    func hugeImageCap() async throws {
        let dir = URL(fileURLWithPath: "/tmp/yilan-huge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wide.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, pixel(20_000, 40), nil)
        #expect(CGImageDestinationFinalize(dest))
        let image = try await ImageDecoder.decode(try realItem(url), variant: .full)
        #expect(max(image.image.width, image.image.height) == ImageDecoder.maxDecodePixel)
        #expect(image.isDownsampled)
        #expect(image.pixelSize.width == 20_000)
    }
}

// MARK: - 快速切换

@Suite("快速切换")
@MainActor
struct FastSwitchTests {
    let folder = "/tmp/yilan-fake-\(UUID().uuidString)"

    private func makeModel(_ fake: FakeDecoder) -> (BrowserModel, [MediaItem], ImagePipeline) {
        let items = (0..<8).map { fakeItem(String(format: "%02d.jpg", $0), folder: folder) }
        let p = pipeline(fake)
        let model = BrowserModel(settings: AppSettings(defaults: freshDefaults()),
                                 recents: RecentFolders(defaults: freshDefaults()),
                                 pipeline: p)
        model.screenMaxPixel = 2000
        model.apply(FolderScanner.Result(folder: URL(fileURLWithPath: folder), items: items, initialIndex: 0))
        return (model, items, p)
    }

    private func isFullyShown(_ model: BrowserModel, _ item: MediaItem) -> Bool {
        model.current == item && model.displayedItem == item && model.displayed != nil
            && model.placeholder == nil && model.failure == nil
    }

    @Test("0 → 最后 → 0 快速切换：最后停在第一张的完整解码上")
    func zeroLastZero() async {
        let fake = FakeDecoder()
        await fake.setDelay(.milliseconds(30))
        let (model, items, _) = makeModel(fake)
        model.select(items.count - 1)
        model.select(0)
        #expect(await waitUntil { isFullyShown(model, items[0]) })
        // 来回再切几次
        for _ in 0..<5 {
            model.last()
            try? await Task.sleep(for: .milliseconds(5))
            model.first()
        }
        #expect(await waitUntil { isFullyShown(model, items[0]) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(isFullyShown(model, items[0]))
    }

    /// 用户反馈（v0.5.0）：左右切换时有时会闪出一帧别的图片。
    /// 原因：切走以后，上一张的加载任务晚到的那一步仍然把「正在显示的文件」改成了它自己
    @Test("快速切走以后，已经过期的加载不会把画面换成别的文件")
    func staleLoadNeverShowsAnotherItem() async {
        let fake = FakeDecoder()
        let (model, items, _) = makeModel(fake)
        #expect(await waitUntil { isFullyShown(model, items[0]) })
        // 其他几张都解不出来：切过去只能走「还没解码好」那条路
        for item in items.dropFirst() { await fake.block(item.url) }
        var wrong: [String] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let shown = model.displayedItem, let current = model.current, shown != current {
                    wrong.append("\(shown.name) 显示在 \(current.name) 上")
                }
                await Task.yield()
            }
        }
        for round in 0..<40 {
            model.select(4 + round % 3)   // 没解码好的一张
            model.select(0)               // 马上切回已经在缓存里的第一张
            for _ in 0..<20 { await Task.yield() }
        }
        #expect(await waitUntil { isFullyShown(model, items[0]) })
        watcher.cancel()
        #expect(wrong.isEmpty, "出现过别的文件的画面：\(wrong.prefix(3))")
        for item in items.dropFirst() { await fake.release(item.url) }
    }

    @Test("按旧位置算的取消误伤当前图片的解码：仍然会显示出来")
    func staleCancelDoesNotStick() async {
        let fake = FakeDecoder()
        let (model, items, p) = makeModel(fake)
        #expect(await waitUntil { isFullyShown(model, items[0]) })
        let target = items[items.count - 1]
        await fake.block(target.url)
        model.last()
        #expect(await waitUntil { await fake.callCount(target.url) == 1 })
        // 模拟停在第一张时发出、但晚到的 cancelAll
        await p.cancelAll(except: Set(items[0...2].map(\.url)))
        await fake.release(target.url)
        #expect(await waitUntil { isFullyShown(model, target) })
    }
}

// MARK: - 缩略图磁盘缓存清理

@Suite("缩略图磁盘缓存清理")
struct ThumbnailPruneTests {
    @Test("删掉 90 天前的；超过上限时从最旧的删")
    func prune() throws {
        let dir = URL(fileURLWithPath: "/tmp/yilan-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let ages: [(String, Double)] = [("old", 100), ("a", 3), ("b", 2), ("c", 1)]
        for (name, days) in ages {
            let url = dir.appendingPathComponent("\(name).jpg")
            try Data(repeating: 1, count: 100_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
        }
        let removed = ThumbnailGenerator.prune(directory: dir, limit: 250_000, now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(removed == 2)
        #expect(left == ["b.jpg", "c.jpg"])
    }

    @Test("用到的缓存会更新时间，不会被当成旧的删掉")
    func touch() throws {
        let dir = URL(fileURLWithPath: "/tmp/yilan-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.jpg")
        try Data([1]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86400)], ofItemAtPath: url.path)
        ThumbnailGenerator.touch(url)
        #expect(ThumbnailGenerator.prune(directory: dir) == 0)
    }
}
