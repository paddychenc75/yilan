import Foundation

/// 批量移到废纸篓、整批放回（spec X3）。会碰磁盘，在后台调用；不碰界面状态
enum BatchTrash {
    /// 要移走的一个文件，和要跟着走的 .xmp 小文件
    struct Job: Sendable {
        let item: MediaItem
        var sidecar: URL?
    }

    /// 移不走、放不回的一个文件和原因
    struct Failure: Equatable, Sendable {
        let item: MediaItem
        let reason: String
    }

    struct Result: Sendable {
        var moved: [TrashEntry] = []
        var failed: [Failure] = []
        /// 点了「停止」之后没有处理的
        var untouched: [MediaItem] = []
    }

    /// 「停止」的开关：界面那边置位，后台每处理完一个看一眼
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func stop() { lock.lock(); value = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 每个文件要带走哪个小文件（spec X3-06）：照片自己的小文件跟着走；
    /// 两个 RAW 共用一个小文件时，共用它的文件全部在这一批里才带走（挂在其中最后一个上）
    static func jobs(for items: [MediaItem], sidecars: SidecarIndex) -> [Job] {
        var jobs = items.map { Job(item: $0, sidecar: sidecars.sidecarToMoveWith($0)) }
        var rawsByBase: [String: [Int]] = [:]
        for (i, item) in items.enumerated() where item.kind == .image && item.format == .raw {
            rawsByBase[SidecarIndex.base(of: item.url), default: []].append(i)
        }
        for (base, indexes) in rawsByBase {
            let total = sidecars.rawPerBase[base, default: 0]
            guard total > 1, indexes.count == total, let last = indexes.last else { continue }
            jobs[last].sidecar = sidecars.readURL(for: items[last])
        }
        return jobs
    }

    /// 按顺序逐个移到废纸篓。一个失败不影响其余的；trash 可以在测试里换成会失败的版本
    static func run(_ jobs: [Job], stop: StopFlag, trash: @Sendable (URL) throws -> URL = TrashService.trash,
                    progress: @Sendable (Int) -> Void = { _ in }) -> Result {
        var result = Result()
        let fm = FileManager.default
        for (index, job) in jobs.enumerated() {
            if stop.isStopped {
                result.untouched = jobs[index...].map(\.item)
                break
            }
            do {
                guard fm.fileExists(atPath: job.item.url.path) else { throw Missing() }
                let trashed = try trash(job.item.url)
                var entry = TrashEntry(item: job.item, trashedURL: trashed)
                // 小文件失败不影响照片本身（spec S-23）
                if let side = job.sidecar, fm.fileExists(atPath: side.path), let t = try? trash(side) { entry.sidecar = (side, t) }
                result.moved.append(entry)
            } catch {
                result.failed.append(Failure(item: job.item, reason: reason(for: error, url: job.item.url)))
            }
            progress(index + 1)
        }
        return result
    }

    private struct Missing: Error {}

    /// 移不走的原因（spec X3-13）
    static func reason(for error: Error, url: URL) -> String {
        if error is Missing || !FileManager.default.fileExists(atPath: url.path) { return String(localized: "文件已经不在原处") }
        // 访达里「已锁定」的文件
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.immutable] as? Bool == true { return String(localized: "文件已锁定") }
        let ns = error as NSError
        // 复制 / 移动（spec R9）直接给的是系统错误码
        let posix = ns.domain == NSPOSIXErrorDomain ? ns.code : (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFeatureUnsupportedError: return String(localized: "这个位置没有废纸篓")
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return String(localized: "没有权限")
            case NSFileWriteVolumeReadOnlyError: return String(localized: "没有权限")
            default: break
            }
        }
        if posix == Int(EACCES) || posix == Int(EPERM) || posix == Int(EROFS) { return String(localized: "没有权限") }
        return ns.localizedDescription
    }

    struct RestoreResult: Sendable {
        var restored: [TrashEntry] = []
        var failed: [Failure] = []
    }

    /// 把一批文件从废纸篓放回原位（spec X3-16、X3-17）：放不回的跳过，其余照常
    static func restore(_ entries: [TrashEntry]) -> RestoreResult {
        var result = RestoreResult()
        for entry in entries {
            do {
                try TrashService.restore(entry)
                result.restored.append(entry)
            } catch TrashService.Failure.originalExists {
                result.failed.append(Failure(item: entry.item, reason: String(localized: "原位置已经有同名文件")))
            } catch TrashService.Failure.missingInTrash {
                result.failed.append(Failure(item: entry.item, reason: String(localized: "废纸篓里已经没有这个文件")))
            } catch {
                result.failed.append(Failure(item: entry.item, reason: error.localizedDescription))
            }
        }
        return result
    }
}

/// 批量操作报进度时的节流：最多每 0.1 秒往界面发一次，最后一个一定发。
/// 不节流的话，几万个文件会往主线程塞几万次更新，「停止」的点击要排很久才轮到（界面验证时点停止后又多移走了约 5000 个）
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let interval: TimeInterval
    private let total: Int

    init(total: Int, interval: TimeInterval = 0.1) {
        self.total = total
        self.interval = interval
    }

    /// 这一次要不要发
    func shouldReport(_ done: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard done >= total || now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
