import Foundation

/// 后台解码的排队口：同时最多放行 limit 个，其余按 order 从大到小排队（一样大时先来先走）。
///
/// 为什么要它：RAW 的完整解码一次就要几百毫秒到一秒多、上百 MB 内存，而且系统解码函数开始后停不下来。
/// 以前预加载前后各 2 张时每张都直接开解，快速切换时会同时跑十几个（很多已经过时），
/// 把 CPU 和 Swift 并发线程池占满，当前这张的内嵌预览反而要等将近一秒。
///
/// 用法：`register` 在发起方同步登记（有空位立即放行，没有就排队，顺序由登记时决定），
/// 解码任务里 `enter` 等到轮到自己，做完 `leave` 让出位置。
/// 排队中的可以 `promote`（当前要看的这张：不占名额，立即开始）、`raise`（调到更前面）、被取消（不再解码）。
/// 线程安全，所有方法都可以在任意线程调用
final class DecodeGate: @unchecked Sendable {
    struct Ticket: Sendable {
        let id: Int
        /// 占了一个名额（promote 放行的不占）
        let counted: Bool
    }

    private enum State {
        case waiting(order: Int, seq: Int, continuation: CheckedContinuation<Ticket, Error>?)
        case admitted(counted: Bool)
        /// 还没开始等就被取消了
        case cancelled
    }

    let limit: Int
    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private var running = 0
    private var seq = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// 登记一个解码：有空位立即放行，否则排队
    func register(_ id: Int, order: Int) {
        lock.lock()
        defer { lock.unlock() }
        if running < limit {
            running += 1
            states[id] = .admitted(counted: true)
        } else {
            seq += 1
            states[id] = .waiting(order: order, seq: seq, continuation: nil)
        }
    }

    /// 等到轮到自己。等的时候被取消：抛 CancellationError，不占名额
    func enter(_ id: Int) async throws -> Ticket {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Ticket, Error>) in
                lock.lock()
                defer { lock.unlock() }
                switch states[id] {
                case .admitted(let counted)?:
                    continuation.resume(returning: Ticket(id: id, counted: counted))
                case .waiting(let order, let seq, _)? where !Task.isCancelled:
                    states[id] = .waiting(order: order, seq: seq, continuation: continuation)
                default:
                    states[id] = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// 做完了（包括出错、被取消）：让出名额给排在最前面的
    func leave(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        states[ticket.id] = nil
        guard ticket.counted else { return }
        let next = states.compactMap { id, state -> (id: Int, order: Int, seq: Int, c: CheckedContinuation<Ticket, Error>?)? in
            guard case .waiting(let order, let seq, let c) = state else { return nil }
            return (id, order, seq, c)
        }.min { ($0.order, -$0.seq) > ($1.order, -$1.seq) }
        if let next {
            states[next.id] = .admitted(counted: true)
            next.c?.resume(returning: Ticket(id: next.id, counted: true))
        } else {
            running -= 1
        }
    }

    /// 排队中的立即开始，不占名额（当前要看的这张不能排在预加载后面）
    func promote(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard case .waiting(_, _, let c)? = states[id] else { return }
        states[id] = .admitted(counted: false)
        c?.resume(returning: Ticket(id: id, counted: false))
    }

    /// 排队中的调到 order（只往前调）
    func raise(_ id: Int, to order: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard case .waiting(let old, let seq, let c)? = states[id], order > old else { return }
        states[id] = .waiting(order: order, seq: seq, continuation: c)
    }

    /// 取消排队中的（已经开始的不受影响，由解码自己检查取消）
    func cancel(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard case .waiting(_, _, let c)? = states[id] else { return }
        if let c {
            states[id] = nil
            c.resume(throwing: CancellationError())
        } else {
            states[id] = .cancelled
        }
    }

    // MARK: - 测试用

    /// 占着名额的数量
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// 这一个还在排队
    func isWaiting(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .waiting? = states[id] { return true }
        return false
    }

    /// 在排队的数量
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return states.values.filter { if case .waiting = $0 { true } else { false } }.count
    }
}
