import Foundation

/// 后台写星级的队列（技术方案 4.1）：按文件排队，同一个文件排队时只写最新的值（spec R1-11）
actor RatingWriter {
    struct Job: Sendable {
        let item: MediaItem
        let value: Int
        let mode: RatingStorageMode
        let sidecars: SidecarIndex
    }

    enum Outcome: Sendable {
        case written(RatingFileIO.WriteResult, [FileStamp])
        /// 排队时被同一文件更新的值取代，没有写
        case superseded
        case failed(RatingWriteError)
    }

    typealias Completion = @Sendable (Outcome) async -> Void

    private var running: Set<URL> = []
    private var waiting: [URL: (Job, Completion)] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// 测试用：写入前停一下，模拟慢盘
    var delayForTesting: Duration?

    var isIdle: Bool { running.isEmpty && waiting.isEmpty }

    func setDelayForTesting(_ d: Duration?) { delayForTesting = d }

    func enqueue(_ job: Job, completion: @escaping Completion) async {
        let url = job.item.url
        if running.contains(url) {
            if let (_, old) = waiting[url] { await old(.superseded) }
            waiting[url] = (job, completion)
            return
        }
        running.insert(url)
        Task { await self.run(job, completion) }
    }

    private func run(_ job: Job, _ completion: Completion) async {
        if let delayForTesting { try? await Task.sleep(for: delayForTesting) }
        let outcome: Outcome = await Task.detached(priority: .userInitiated) {
            do {
                let result = try RatingFileIO.write(job.value, for: job.item, mode: job.mode, sidecars: job.sidecars)
                return .written(result, result.stamps())
            } catch {
                return .failed(SafeReplace.map(error))
            }
        }.value
        await completion(outcome)
        let url = job.item.url
        if let (next, nextCompletion) = waiting.removeValue(forKey: url) {
            Task { await self.run(next, nextCompletion) }
        } else {
            running.remove(url)
            if isIdle {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// 等全部写完（退出前，spec S-20）
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
