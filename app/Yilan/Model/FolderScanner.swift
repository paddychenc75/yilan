import Foundation

/// 扫描文件夹：只读当前层（不含子文件夹），按文件名自然排序
enum FolderScanner {
    struct Result: Sendable {
        let folder: URL
        let items: [MediaItem]
        /// 打开的是某个文件时，它在 items 里的位置
        let initialIndex: Int?
        /// 没有权限列出文件夹（例如“桌面”“文稿”受系统隐私保护，用户拒绝了授权），只显示打开的这一个文件
        var folderUnreadable = false
        /// 文件夹里的 .xmp 小文件（评星用）
        var sidecars: SidecarIndex = .empty
    }

    /// 打开文件或文件夹。传入文件时扫描它所在的文件夹并选中它；传入文件夹时从第一个开始
    static func open(_ url: URL) throws -> Result {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let items = try scan(folder: url)
            SafeReplace.cleanStaleTemps(in: url)
            return Result(folder: url, items: items, initialIndex: items.isEmpty ? nil : 0,
                          sidecars: SidecarIndex.scan(folder: url, media: items))
        }
        let folder = url.deletingLastPathComponent()
        let items: [MediaItem]
        do {
            items = try scan(folder: folder)
        } catch {
            // 读不了文件夹，但打开的这个文件本身可以读：退化为只看这一个
            guard let format = SupportedFormats.format(forExtension: url.pathExtension) else { throw error }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let single = MediaItem(url: url, format: format, fileSize: Int64(v?.fileSize ?? 0),
                                   modificationDate: v?.contentModificationDate ?? .distantPast)
            return Result(folder: folder, items: [single], initialIndex: 0, folderUnreadable: true)
        }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let index = items.firstIndex { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == target }
        SafeReplace.cleanStaleTemps(in: folder)
        return Result(folder: folder, items: items, initialIndex: index ?? (items.isEmpty ? nil : 0),
                      sidecars: SidecarIndex.scan(folder: folder, media: items))
    }

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                                                  .contentModificationDateKey, .fileIdentifierKey]

    static func scan(folder: URL) throws -> [MediaItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )
        return naturalSorted(urls.compactMap(item(at:)))
    }

    /// 一个文件对应的 MediaItem；不支持的格式、文件夹返回 nil
    static func item(at url: URL) -> MediaItem? {
        guard let format = SupportedFormats.format(forExtension: url.pathExtension) else { return nil }
        // URL 会缓存读过的属性（扫描文件夹时预取的大小、修改时间）：文件在原地被改写后（保存旋转、替换原图、撤销）
        // 不清掉就会读回旧值，列表里还是旧条目，缩略图不更新（F2-02）
        var url = url
        url.removeAllCachedResourceValues()
        let v = try? url.resourceValues(forKeys: Set(keys))
        // 只要普通文件（符号链接会被解析为目标文件的属性）
        if v?.isDirectory == true { return nil }
        return MediaItem(
            url: url,
            format: format,
            fileSize: Int64(v?.fileSize ?? 0),
            modificationDate: v?.contentModificationDate ?? .distantPast,
            fileID: v?.fileIdentifier
        )
    }

    /// 自然排序：img2 在 img10 前面，大小写不敏感，与访达一致
    static func naturalSorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { naturalLess($0.name, $1.name) }
    }

    /// 先比去掉扩展名的名字：「IMG_1.jpg」排在「IMG_1 编辑.jpg」前面，编辑出的副本紧跟原图（技术方案 13.3）
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        let stem = (a as NSString).deletingPathExtension.localizedStandardCompare((b as NSString).deletingPathExtension)
        if stem != .orderedSame { return stem == .orderedAscending }
        let r = a.localizedStandardCompare(b)
        if r == .orderedSame { return a < b }   // 保证排序稳定
        return r == .orderedAscending
    }
}
