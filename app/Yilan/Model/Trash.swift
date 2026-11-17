import Foundation

/// 一次“移到废纸篓”：原来的文件和它在废纸篓里的位置（撤销时放回去）
struct TrashEntry: Equatable, Sendable {
    let item: MediaItem
    let trashedURL: URL
    /// 一起进废纸篓的 .xmp 小文件：原位置、废纸篓里的位置（spec S-23）
    var sidecar: (original: URL, trashed: URL)? = nil

    static func == (a: TrashEntry, b: TrashEntry) -> Bool {
        a.item == b.item && a.trashedURL == b.trashedURL
            && a.sidecar?.original == b.sidecar?.original && a.sidecar?.trashed == b.sidecar?.trashed
    }
}

/// 移到废纸篓和放回原处（会碰磁盘，在后台线程调用）
enum TrashService {
    enum Failure: LocalizedError {
        case originalExists(String)
        case missingInTrash(String)

        var errorDescription: String? {
            switch self {
            case .originalExists(let name): String(localized: "原位置已经有“\(name)”", comment: "撤销删除失败的原因；%@ 是文件名")
            case .missingInTrash(let name): String(localized: "废纸篓里已经没有“\(name)”", comment: "撤销删除失败的原因；%@ 是文件名")
            }
        }
    }

    /// 假废纸篓：跑测试、截图（--shot-delete）时不能把文件放进用户真正的废纸篓。
    /// 测试进程（xcodebuild test 启动的宿主 App）和截图参数下自动启用，正常使用时是 nil
    static let fakeTrashDirectory: URL? = {
        let env = ProcessInfo.processInfo.environment
        let underTest = env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
        guard underTest || ShotHooks.deleteState != nil else { return nil }
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("yilan-fake-trash-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    /// 移到废纸篓，返回它在废纸篓里的位置
    static func trash(_ url: URL) throws -> URL {
        if let dir = fakeTrashDirectory { return try moveToFakeTrash(url, directory: dir) }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let trashed = resulting as URL? else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return trashed
    }

    /// 假废纸篓：同名时像系统一样加后缀，返回移过去后的位置
    static func moveToFakeTrash(_ url: URL, directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            target = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// 从废纸篓放回原来的位置
    static func restore(_ entry: TrashEntry) throws {
        let fm = FileManager.default
        let name = entry.item.name
        guard fm.fileExists(atPath: entry.trashedURL.path) else { throw Failure.missingInTrash(name) }
        guard !fm.fileExists(atPath: entry.item.url.path) else { throw Failure.originalExists(name) }
        try fm.moveItem(at: entry.trashedURL, to: entry.item.url)
        // 小文件放不回去（原位置又有了同名小文件、废纸篓里没了）不影响照片本身
        if let side = entry.sidecar, fm.fileExists(atPath: side.trashed.path), !fm.fileExists(atPath: side.original.path) {
            try? fm.moveItem(at: side.trashed, to: side.original)
        }
    }
}

/// 删除后显示哪一个
enum DeleteSelection {
    /// 删掉列表里 index 位置的一项后，新列表里要显示的位置：
    /// 显示下一个（新列表里同一位置）；删的是最后一个时显示上一个；删空了返回 nil
    static func index(afterRemoving index: Int, newCount: Int) -> Int? {
        guard newCount > 0 else { return nil }
        return min(max(index, 0), newCount - 1)
    }
}
