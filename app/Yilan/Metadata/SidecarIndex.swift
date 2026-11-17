import Foundation

/// 一个文件夹里的 .xmp 小文件索引和命名规则（spec S-04、技术方案 3.5）。
/// 扫描文件夹时一次列出，之后按名字查，不再逐个问磁盘
struct SidecarIndex: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let url: URL
        let modificationDate: Date
        let size: Int64
    }

    let folder: URL
    /// 小写文件名 → 小文件
    private(set) var entries: [String: Entry]
    /// 小写的“去掉扩展名的文件名” → 一览支持的文件有几个（视频也算：实况照片 IMG_1.HEIC 旁边的 IMG_1.xmp
    /// 可能是别的软件给 IMG_1.MOV 写的，图片这时改用 IMG_1.HEIC.xmp，不碰它）
    private(set) var mediaPerBase: [String: Int]
    /// 小写的“去掉扩展名的文件名” → 其中 RAW 有几个
    private(set) var rawPerBase: [String: Int]

    init(folder: URL, sidecars: [Entry], media: [MediaItem]) {
        self.folder = folder
        entries = Dictionary(sidecars.map { ($0.url.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var perBase: [String: Int] = [:]
        var raws: [String: Int] = [:]
        for item in media {
            let base = Self.base(of: item.url)
            perBase[base, default: 0] += 1
            if item.format == .raw { raws[base, default: 0] += 1 }
        }
        mediaPerBase = perBase
        rawPerBase = raws
    }

    static let empty = SidecarIndex(folder: URL(fileURLWithPath: "/"), sidecars: [], media: [])

    /// 列出文件夹里的 .xmp（扫描文件夹时调用，后台线程）
    static func scan(folder: URL, media: [MediaItem]) -> SidecarIndex {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let sidecars: [Entry] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "xmp",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            // 用传入的文件夹拼路径（目录列出的可能是 /private/var… 这样解析过的路径），和照片的路径保持一致
            return Entry(url: folder.appendingPathComponent(url.lastPathComponent), modificationDate: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0))
        }
        return SidecarIndex(folder: folder, sidecars: sidecars, media: media)
    }

    static func base(of url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }

    private func existing(_ name: String) -> URL? { entries[name.lowercased()]?.url }

    /// 读星级时用哪个小文件（不存在时 nil）
    func readURL(for item: MediaItem) -> URL? {
        // 视频不评星：它旁边的小文件不读、不改、不跟着进废纸篓
        guard item.kind == .image else { return nil }
        let base = Self.base(of: item.url)
        if item.format == .raw { return existing(base + ".xmp") }
        if let full = existing(item.name + ".xmp") { return full }
        // 同名 .xmp 只在没有别的同名文件时才算它的
        if mediaPerBase[base, default: 0] <= 1 { return existing(base + ".xmp") }
        return nil
    }

    /// 写星级时用哪个小文件（可能还不存在）
    func writeURL(for item: MediaItem) -> URL {
        if let url = readURL(for: item) { return url }
        let base = item.url.deletingPathExtension().lastPathComponent
        let dir = item.url.deletingLastPathComponent()
        if item.format == .raw || mediaPerBase[Self.base(of: item.url), default: 0] <= 1 {
            return dir.appendingPathComponent(base + ".xmp")
        }
        return dir.appendingPathComponent(item.name + ".xmp")
    }

    /// 删除这个文件时要一起进废纸篓的小文件（spec S-23）：两个 RAW 共用同名小文件时不动
    func sidecarToMoveWith(_ item: MediaItem) -> URL? {
        guard item.kind == .image else { return nil }
        guard let url = readURL(for: item) else { return nil }
        if item.format == .raw, rawPerBase[Self.base(of: item.url), default: 0] > 1 { return nil }
        return url
    }

    // MARK: 一览自己改了小文件后更新索引

    mutating func noteWritten(_ url: URL) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        entries[url.lastPathComponent.lowercased()] = Entry(url: url, modificationDate: v?.contentModificationDate ?? Date(),
                                                            size: Int64(v?.fileSize ?? 0))
    }

    mutating func noteRemoved(_ url: URL) {
        entries[url.lastPathComponent.lowercased()] = nil
    }

    /// 两次扫描之间变了的小文件（新增、删除、修改）
    func changedNames(comparedTo old: SidecarIndex) -> Set<String> {
        var changed = Set<String>()
        for (name, e) in entries where old.entries[name] != e { changed.insert(name) }
        for name in old.entries.keys where entries[name] == nil { changed.insert(name) }
        return changed
    }

    /// 某个小文件名（小写）属于哪些文件
    func owners(ofSidecarNamed name: String, in items: [MediaItem]) -> [MediaItem] {
        items.filter { item in
            readURL(for: item)?.lastPathComponent.lowercased() == name
                || writeURL(for: item).lastPathComponent.lowercased() == name
        }
    }
}
