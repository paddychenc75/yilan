import Foundation

/// 大图加载：内存缓存 + 合并重复请求 + 取消过期的预加载
actor ImagePipeline {
    static let shared = ImagePipeline()

    /// 解码函数（测试里换成可控的假解码）
    typealias Decode = @Sendable (MediaItem, ImageDecoder.Variant) async throws -> DecodedImage

    struct Key: Hashable, Sendable {
        let url: URL
        let modificationDate: Date
        let variant: ImageDecoder.Variant
    }

    private final class KeyBox: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    private let cache = NSCache<KeyBox, DecodedImage>()
    /// 进行中的解码。queued：经过排队口（后台预加载、RAW 预览之后的高清解码），id 是它在排队口的编号
    private struct Flight {
        let task: Task<DecodedImage, Error>
        let id: Int
        let queued: Bool
    }
    private var inFlight: [Key: Flight] = [:]
    private var nextFlightID = 0
    /// 已知打不开的文件（只记文件本身损坏的；文件不见了、读不了不记，下次还会重试）
    private var failures: [Key: DecodeFailure] = [:]
    private let decode: Decode
    /// 排队解码的口子（见 DecodeGate）
    nonisolated let gate: DecodeGate

    /// 排队解码同时最多几个：当前这张的高清解码和前后几张的预加载共用。
    /// 当前这张的内嵌预览和非 RAW 图片不排队，随时可以开始
    static let queuedLimit = 2

    init(queuedLimit: Int = ImagePipeline.queuedLimit,
         decode: @escaping Decode = { try await ImageDecoder.decode($0, variant: $1) }) {
        self.decode = decode
        gate = DecodeGate(limit: queuedLimit)
        // 屏幕尺寸的图约 30–70 MB：前后各 2 张 + 当前 + 少量历史。F2-06：原来是 900 MB / 16 张
        cache.totalCostLimit = Self.baseCostLimit
        cache.countLimit = 8
    }

    static let baseCostLimit = 400 * 1024 * 1024

    /// 缓存的成本上限。至少要放得下当前这张和前后各 2 张（另留一张的余量），不然往回翻时
    /// 刚看过的那张已经被挤出去，又要重新解码、先闪一下模糊的缩略图。
    /// 普通屏幕（长边 4000 像素以内）还是 400 MB；5K、6K 屏上一张图就有 70 到 100 MB，按屏幕放宽，最多 800 MB
    static func costLimit(displayMaxPixel: Int) -> Int {
        // 3:2 的照片按屏幕长边解码后的大小（每像素 4 字节）
        let one = displayMaxPixel * (displayMaxPixel * 2 / 3) * 4
        return min(max(baseCostLimit, one * 6), 2 * baseCostLimit)
    }

    /// 窗口所在屏幕的解码尺寸变了：缓存上限跟着调
    func displayChanged(maxPixel: Int) {
        cache.totalCostLimit = Self.costLimit(displayMaxPixel: maxPixel)
    }

    static func key(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> Key {
        Key(url: item.url, modificationDate: item.modificationDate, variant: variant)
    }

    /// 只查缓存，不触发解码
    func cached(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> DecodedImage? {
        cache.object(forKey: KeyBox(Self.key(item, variant)))
    }

    /// 取图：命中缓存直接返回；已经在解码就等它；否则开始解码。
    /// order 为 nil：立即开始（排队中的同一张也立即放行）；有值：经过排队口，数字大的先开始。
    /// 共用的解码被别人取消了（例如切换太快时过期的 cancelAll），而调用方自己没被取消，就重新解码一次。
    /// 预加载不重试：它被取消正是 cancelAll 想要的
    func image(_ item: MediaItem, _ variant: ImageDecoder.Variant,
               priority: TaskPriority = .userInitiated, retryIfCancelled: Bool = true,
               order: Int? = nil) async throws -> DecodedImage {
        do {
            return try await load(item, variant, priority: priority, order: order)
        } catch is CancellationError where retryIfCancelled && !Task.isCancelled {
            return try await load(item, variant, priority: priority, order: order)
        }
    }

    private func load(_ item: MediaItem, _ variant: ImageDecoder.Variant, priority: TaskPriority,
                      order: Int?) async throws -> DecodedImage {
        let key = Self.key(item, variant)
        if let hit = cache.object(forKey: KeyBox(key)) { return hit }
        if let failure = failures[key] { throw failure }
        let task = flight(item, variant, key: key, priority: priority, order: order)
        return try await finish(key, task)
    }

    /// 等解码结果：成功放进缓存，文件损坏记住失败，最后清掉进行中的记录
    private func finish(_ key: Key, _ task: Task<DecodedImage, Error>) async throws -> DecodedImage {
        // 等待期间这一项可能已被 cancelAll 移走、又换成了新的解码：只清掉自己那一个
        defer { if inFlight[key]?.task == task { inFlight[key] = nil } }
        do {
            let result = try await task.value
            cache.setObject(result, forKey: KeyBox(key), cost: result.memoryCost)
            // RAW 的高清版到了，内嵌预览不再需要（预览可能是 2400 万像素、近 100 MB），腾出缓存给前后几张
            if case .display = key.variant, !result.isPreview {
                cache.removeObject(forKey: KeyBox(Key(url: key.url, modificationDate: key.modificationDate, variant: .rawPreview)))
            }
            return result
        } catch let failure as DecodeFailure {
            if failure.kind.isRemembered { failures[key] = failure }
            throw failure
        }
    }

    /// 找到或开始这一项的解码
    private func flight(_ item: MediaItem, _ variant: ImageDecoder.Variant, key: Key, priority: TaskPriority,
                        order: Int?) -> Task<DecodedImage, Error> {
        if let running = inFlight[key] {
            if running.queued {
                if let order { gate.raise(running.id, to: order) } else { gate.promote(running.id) }
            }
            return running.task
        }
        let decode = self.decode
        nextFlightID += 1
        let id = nextFlightID
        let task: Task<DecodedImage, Error>
        if let order {
            let gate = self.gate
            // 登记在这里同步完成：排队顺序按发起的先后和 order 决定，不受任务启动先后影响
            gate.register(id, order: order)
            task = Task.detached(priority: priority) {
                let ticket = try await gate.enter(id)
                defer { gate.leave(ticket) }
                // 排队时被取消（切走了）：不再解码
                try Task.checkCancellation()
                return try await decode(item, variant)
            }
        } else {
            task = Task.detached(priority: priority) { try await decode(item, variant) }
        }
        inFlight[key] = Flight(task: task, id: id, queued: order != nil)
        return task
    }

    /// 后台预加载（不等待结果）。order 为 nil 时立即开始；有值时经过排队口，大的先开始
    func preload(_ item: MediaItem, _ variant: ImageDecoder.Variant, order: Int? = 0) {
        let key = Self.key(item, variant)
        guard cache.object(forKey: KeyBox(key)) == nil, failures[key] == nil else { return }
        if let running = inFlight[key] {
            if running.queued, let order { gate.raise(running.id, to: order) }
            return
        }
        // 先同步登记（保证排队顺序），再在后台等结果、放进缓存。
        // 只等这一个解码：它被 cancelAll 取消了就算了，不会重新开始
        let task = flight(item, variant, key: key, priority: .utility, order: order)
        Task(priority: .utility) { _ = try? await self.finish(key, task) }
    }

    /// 取消不在 keep 里的进行中的解码（切换太快时，旧的预加载不再需要）。
    /// 还在排队的直接作废；已经开始的系统解码停不下来，会跑完，但结果不再有人等
    func cancelAll(except keep: Set<URL>) {
        for (key, flight) in inFlight where !keep.contains(key.url) {
            flight.task.cancel()
            inFlight[key] = nil
        }
    }

    /// 忘掉记住的失败（重新打开文件夹时调用：文件可能已经被修好或换掉）
    func clearFailures() {
        failures.removeAll()
    }

    /// 这些文件在磁盘上变了（文件夹同步）：忘掉记住的失败，下次重新解码。
    /// 缓存按修改时间区分版本，旧版本会自然被挤出去
    func forget(_ urls: Set<URL>) {
        failures = failures.filter { !urls.contains($0.key.url) }
    }

    /// 内存紧张：清空大图缓存（正在显示的那张由界面持有，不受影响）
    func trimMemory() {
        cache.removeAllObjects()
    }

    func removeAll() {
        cache.removeAllObjects()
        failures.removeAll()
    }

    // MARK: - 测试用

    func isInFlight(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> Bool {
        inFlight[Self.key(item, variant)] != nil
    }

    /// 这一项正在排队口排队（还没开始解码）
    func isQueued(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> Bool {
        guard let f = inFlight[Self.key(item, variant)], f.queued else { return false }
        return gate.isWaiting(f.id)
    }

    func rememberedFailure(_ item: MediaItem, _ variant: ImageDecoder.Variant) -> DecodeFailure? {
        failures[Self.key(item, variant)]
    }
}
