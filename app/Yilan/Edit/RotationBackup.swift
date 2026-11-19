import Darwin
import Foundation

/// 浏览时「保存旋转」改原图之前，原文件的一份副本（F2-03）：⌘Z 时把原来的字节原样放回去。
/// 只改方向标记再改回去，系统会重新排一遍文件里的附加信息，画面一样但文件和原来差几 KB；放回副本就逐字节相同
struct RotationBackup: Equatable, Sendable {
    /// 副本的位置
    let copy: URL
    /// 保存旋转写好之后文件的状态：撤销前核对，不一样说明这期间文件又被改过
    let written: DiskStamp
}

/// 文件某一刻的大小和修改时间（直接读 stat，不经过 URL 的属性缓存）
struct DiskStamp: Equatable, Sendable {
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init?(_ url: URL) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        size = Int64(st.st_size)
        seconds = st.st_mtimespec.tv_sec
        nanoseconds = st.st_mtimespec.tv_nsec
    }
}

/// 副本放在 ~/Library/Caches/com.yilan.viewer/rotation-undo/<进程号>/。
/// 同一个磁盘上是 APFS 克隆，几乎不占空间；照片在别的磁盘上时是完整复制，所以总量有上限。
/// 撤销用掉、撤销记录被清掉（换文件夹、超过 100 条）、退出时删除；上次没正常退出留下的，下次启动时删除
enum RotationBackupStore {
    /// 所有副本加起来最多这么大，超过时先删最早的（那一条撤销就退回只改方向标记的做法）
    static let limit: Int64 = 2 * 1024 * 1024 * 1024

    static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.yilan.viewer/rotation-undo", isDirectory: true)

    /// 这个进程自己的目录（同时开着几个一览时互不干扰）
    static let directory: URL = root.appendingPathComponent(String(getpid()), isDirectory: true)

    /// 给 url 做一份副本；文件太大或复制失败返回 nil（保存旋转照常进行，撤销退回只改方向标记）
    static func make(for url: URL, in dir: URL = directory, limit: Int64 = limit) -> URL? {
        let fm = FileManager.default
        guard let size = DiskStamp(url)?.size, size <= limit else { return nil }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            makeRoom(for: size, in: dir, limit: limit)
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            // copyItem 在同一个 APFS 磁盘上自动克隆；保留修改时间
            try fm.copyItem(at: url, to: dest)
            guard DiskStamp(dest)?.size == size else {
                try? fm.removeItem(at: dest)
                return nil
            }
            return dest
        } catch {
            Log.app.error("保存旋转前备份原文件失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 总量超过上限时从最早的副本开始删
    private static func makeRoom(for size: Int64, in dir: URL, limit: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.map { url -> (url: URL, size: Int64, date: Date) in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(v?.fileSize ?? 0), v?.creationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for e in entries where total + size > limit {
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }

    /// 撤销：把副本原样放回 url。
    /// 这期间文件被改过时：画面和方向都没变（只改了附加信息，比如写进文件的星级）就只把方向标记改回去，
    /// 保留那些改动；画面或方向变了就放弃撤销，不覆盖新内容
    static func restore(_ url: URL, from backup: RotationBackup, old: Int, new: Int) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            guard let now = DiskStamp(url) else { throw EditSaveError.vanished }
            guard fm.fileExists(atPath: backup.copy.path) else {
                // 副本没了（超过总量被删）：退回只改方向标记
                return try EditWriter.setOrientation(url, to: old)
            }
            if now != backup.written {
                guard EditWriter.sourceInfo(url).orientation == new, (try? EditWriter.samePixels(url, backup.copy)) == true else {
                    throw EditSaveError.other(String(localized: "文件已被其他程序改动。"))
                }
                return try EditWriter.setOrientation(url, to: old)
            }
            guard SafeReplace.isWritable(folder: dir) else { throw EditSaveError.notWritable(folder: dir.lastPathComponent) }
            let temp = SafeReplace.tempURL(for: url)
            defer { try? fm.removeItem(at: temp) }
            try fm.copyItem(at: backup.copy, to: temp)
            guard DiskStamp(temp)?.size == DiskStamp(backup.copy)?.size else {
                throw EditSaveError.other(String(localized: "检查没有通过，原图没有改动。"))
            }
            // 换上之前再看一眼：复制副本的这一会儿文件又被改了，就不覆盖
            guard DiskStamp(url) == backup.written else { throw EditSaveError.other(String(localized: "文件已被其他程序改动。")) }
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            throw EditSaveError.from(error, folder: dir)
        }
    }

    /// 不再需要的副本
    static func discard(_ backup: RotationBackup) {
        try? FileManager.default.removeItem(at: backup.copy)
    }

    /// 退出时：删掉这个进程的全部副本
    static func removeAll(in dir: URL = directory) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 启动时：删掉已经不在运行的一览留下的副本（崩溃、强制退出）
    static func removeStale(root: URL = root) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in dirs {
            guard let pid = Int32(name) else {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                continue
            }
            if pid != getpid(), kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }
}
