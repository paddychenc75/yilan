import Darwin
import Foundation

/// 安全地替换用户文件：同目录隐藏临时文件 → 自检 → 原子替换 → 恢复原修改时间（spec S-07、S-09）
enum SafeReplace {
    static let tempPrefix = ".yilan-"

    /// 同目录下的临时文件名：.yilan-<UUID>.<原扩展名>
    static func tempURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let name = tempPrefix + UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// 是不是一览自己的临时文件（只认这个精确的命名）
    static func isOwnTemp(_ name: String) -> Bool {
        name.range(of: #"^\.yilan-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}(\.[A-Za-z0-9]{1,8})?$"#,
                   options: .regularExpression) != nil
    }

    /// 打开文件夹时：删掉一览留下的、超过 maxAge 的临时文件（spec S-08）。返回删了几个
    @discardableResult
    static func cleanStaleTemps(in folder: URL, maxAge: TimeInterval = 600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where isOwnTemp(name) {
            let url = folder.appendingPathComponent(name)
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(m) > maxAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// 这个文件夹能不能写（spec S-16）
    static func isWritable(folder: URL) -> Bool {
        if let v = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]), v.volumeIsReadOnly == true { return false }
        return access(folder.path, W_OK) == 0
    }

    /// 替换已有文件。produce 往临时文件里写新内容，verify 检查临时文件；都通过才替换。
    /// keepModificationDate：恢复原文件的修改时间（纳秒）
    static func replace(_ url: URL, keepModificationDate: Bool,
                        produce: (URL) throws -> Void, verify: (URL) throws -> Void) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw errno == ENOENT ? RatingWriteError.vanished : map(posix: errno) }
        let folder = url.deletingLastPathComponent()
        guard isWritable(folder: folder) else { throw RatingWriteError.notWritable }
        let temp = tempURL(for: url)
        do {
            try produce(temp)
            try verify(temp)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RatingWriteError.vanished }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw map(error)
        }
        if keepModificationDate {
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = utimensat(AT_FDCWD, url.path, &times, 0)
        }
    }

    /// 写一个文件（新建或覆盖），同样先写临时文件再换名
    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard isWritable(folder: folder) else { throw RatingWriteError.notWritable }
        let temp = tempURL(for: url)
        do {
            try data.write(to: temp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw map(error)
        }
    }

    /// 系统错误 → 界面能用的原因
    static func map(_ error: Error) -> RatingWriteError {
        if let e = error as? RatingWriteError { return e }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return map(posix: Int32(underlying.code))
        }
        if ns.domain == NSPOSIXErrorDomain { return map(posix: Int32(ns.code)) }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileWriteVolumeReadOnlyError, NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .notWritable
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .vanished
            default: break
            }
        }
        return .other(ns.localizedDescription)
    }

    static func map(posix code: Int32) -> RatingWriteError {
        switch code {
        case EROFS, EACCES, EPERM: return .notWritable
        case ENOSPC, EDQUOT: return .diskFull
        case ENOENT: return .vanished
        default: return .other(String(cString: strerror(code)))
        }
    }
}
