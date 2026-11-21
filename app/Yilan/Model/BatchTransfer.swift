import Darwin
import Foundation

/// 复制到 / 移动到文件夹（spec R9）。会碰磁盘，在后台调用；不碰界面状态。
/// 原则：绝不覆盖目标里已有的文件；任何一步失败都不能丢文件（失败的那一项两边恢复原样）
enum BatchTransfer {
    enum Mode: Sendable, Equatable { case copy, move }

    /// 一起放过去的 .xmp 小文件：原来的位置、新的位置
    struct SidecarPlaced: Equatable, Sendable {
        let source: URL
        let destination: URL
    }

    /// 一个文件放到了哪里（撤销移动时按它移回去）
    struct Placed: Equatable, Sendable {
        /// 原来的文件（item.url 是原位置）
        let item: MediaItem
        let destination: URL
        var sidecar: SidecarPlaced?

        /// 目标里有同名文件，加了序号（spec R9-05）
        var renamed: Bool { item.url.lastPathComponent != destination.lastPathComponent }
    }

    struct Result: Sendable {
        var placed: [Placed] = []
        var failed: [BatchTrash.Failure] = []
        /// 点了「停止」之后没有处理的
        var untouched: [MediaItem] = []
    }

    /// 磁盘操作：测试里可以换成会在某一步失败的版本（模拟跨磁盘、磁盘满）
    struct Disk: Sendable {
        /// 文件和目标文件夹在同一个磁盘上：移动时直接改名
        var sameVolume: @Sendable (URL, URL) -> Bool = BatchTransfer.sameVolume
        /// 把文件复制到一个还不存在的位置（保留修改时间等属性）
        var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }

        static let live = Disk()
    }

    struct SizeMismatch: Error {}
    private struct Missing: Error {}

    // MARK: - 整批

    /// 按顺序逐个复制或移动到 folder。一个失败不影响其余的（spec R9-10）；jobs 用 BatchTrash.jobs 算（小文件规则同 X3-06）
    static func run(_ jobs: [BatchTrash.Job], to folder: URL, mode: Mode, stop: BatchTrash.StopFlag, disk: Disk = .live,
                    progress: @Sendable (Int) -> Void = { _ in }) -> Result {
        var result = Result()
        for (index, job) in jobs.enumerated() {
            if stop.isStopped {
                result.untouched = jobs[index...].map(\.item)
                break
            }
            do {
                result.placed.append(try transfer(job, to: folder, mode: mode, disk: disk))
            } catch {
                result.failed.append(BatchTrash.Failure(item: job.item, reason: BatchTrash.reason(for: error, url: job.item.url)))
            }
            progress(index + 1)
        }
        return result
    }

    /// 复制或移动一个文件和它的小文件。目标里已有同名文件时在文件名后加空格和序号（「IMG_2035 2.HEIC」），
    /// 小文件用同样的新名字（spec R9-05）
    static func transfer(_ job: BatchTrash.Job, to folder: URL, mode: Mode, disk: Disk = .live) throws -> Placed {
        let fm = FileManager.default
        let source = job.item.url
        guard fm.fileExists(atPath: source.path) else { throw Missing() }
        let sidecar = job.sidecar.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        var n = 1
        while n < 10_000 {
            let name = numbered(source.lastPathComponent, n)
            let dest = folder.appendingPathComponent(name)
            let sideDest = sidecar.map { folder.appendingPathComponent(sidecarName($0, photo: source, newName: name, numbered: n > 1)) }
            n += 1
            // 照片和小文件的新名字都要空着
            if fm.fileExists(atPath: dest.path) || (sideDest.map { fm.fileExists(atPath: $0.path) } ?? false) { continue }
            do {
                try place(source, at: dest, mode: mode, disk: disk)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                continue   // 检查之后刚好有人放了同名文件：换下一个序号
            }
            var placed = Placed(item: job.item, destination: dest)
            if let sidecar, let sideDest {
                do {
                    try place(sidecar, at: sideDest, mode: mode, disk: disk)
                    placed.sidecar = SidecarPlaced(source: sidecar, destination: sideDest)
                } catch {
                    // 小文件没放成：照片也退回去，这一项算失败（不能让星级丢掉）
                    switch mode {
                    case .copy: try? fm.removeItem(at: dest)
                    case .move: try? place(dest, at: source, mode: .move, disk: disk)
                    }
                    throw error
                }
            }
            return placed
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: source.path])
    }

    /// 把一个文件放到 dest（dest 必须还不存在，绝不覆盖）。
    /// 同盘移动：原子改名。复制、跨盘移动：先复制成目标文件夹里的临时文件，核对大小一致后改成正式名字，
    /// 移动时最后才删原件；中途失败时原件不动，目标里的半成品删掉（spec R9-09）
    static func place(_ source: URL, at dest: URL, mode: Mode, disk: Disk = .live) throws {
        let fm = FileManager.default
        let folder = dest.deletingLastPathComponent()
        if mode == .move, disk.sameVolume(source, folder) {
            try renameExclusive(source, to: dest)
            return
        }
        let temp = folder.appendingPathComponent(".yilan-\(UUID().uuidString).tmp")
        do {
            try disk.copy(source, temp)
            guard try size(of: source) == size(of: temp) else { throw SizeMismatch() }
            try renameExclusive(temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard mode == .move else { return }
        do {
            try fm.removeItem(at: source)
        } catch {
            // 原件删不掉：目标里刚放的副本也删掉，两边恢复原样
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// 改名，目标已存在时失败（不覆盖）。不支持「不覆盖改名」的磁盘（部分 FAT、网络盘）退回先检查再改名
    static func renameExclusive(_ source: URL, to dest: URL) throws {
        if renamex_np(source.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == ENOTSUP || code == EINVAL {
            guard !FileManager.default.fileExists(atPath: dest.path) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)) }
            try FileManager.default.moveItem(at: source, to: dest)
            return
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: source.path])
    }

    static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    static func sameVolume(_ a: URL, _ folder: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: key).volumeIdentifier as? NSObject,
              let vb = try? folder.resourceValues(forKeys: key).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    // MARK: - 名字

    /// 第 n 个候选名字：1 是原名，之后是「IMG_2035 2.HEIC」「IMG_2035 3.HEIC」……（和访达一样）
    static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
    }

    /// 小文件的新名字：照片加了序号时小文件跟着改（「IMG_2035 2.xmp」或「IMG_2035 2.HEIC.xmp」）
    static func sidecarName(_ sidecar: URL, photo: URL, newName: String, numbered: Bool) -> String {
        let old = sidecar.lastPathComponent
        guard numbered else { return old }
        let ext = sidecar.pathExtension
        // 「照片全名.xmp」的写法
        if old.lowercased() == (photo.lastPathComponent + ".xmp").lowercased() { return newName + "." + ext }
        return (newName as NSString).deletingPathExtension + "." + ext
    }

    // MARK: - 撤销移动

    struct RestoreResult: Sendable {
        var restored: [Placed] = []
        var failed: [BatchTrash.Failure] = []
    }

    /// ⌘Z：把移走的文件全部移回原位（spec R9-08）。原位置已有同名文件、文件已经不在目标里的跳过，其余照常
    static func moveBack(_ placed: [Placed], disk: Disk = .live) -> RestoreResult {
        let fm = FileManager.default
        var result = RestoreResult()
        for entry in placed {
            guard fm.fileExists(atPath: entry.destination.path) else {
                result.failed.append(.init(item: entry.item, reason: String(localized: "文件已经不在原处")))
                continue
            }
            guard !fm.fileExists(atPath: entry.item.url.path) else {
                result.failed.append(.init(item: entry.item, reason: String(localized: "原位置已经有同名文件")))
                continue
            }
            do {
                try place(entry.destination, at: entry.item.url, mode: .move, disk: disk)
            } catch {
                result.failed.append(.init(item: entry.item, reason: BatchTrash.reason(for: error, url: entry.destination)))
                continue
            }
            // 小文件移不回去（原位置又有了同名小文件）不影响照片本身
            if let side = entry.sidecar, fm.fileExists(atPath: side.destination.path), !fm.fileExists(atPath: side.source.path) {
                try? place(side.destination, at: side.source, mode: .move, disk: disk)
            }
            result.restored.append(entry)
        }
        return result
    }
}
