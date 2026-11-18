import Foundation

/// 一次评星：撤销时把这个文件恢复成 old（spec R7-03）
struct RatingChange: Equatable, Sendable {
    let item: MediaItem
    let old: Int
    let new: Int
}

/// 一次编辑保存（spec ED-39、ED-42）：撤销时怎么恢复
enum EditUndo: Equatable, Sendable {
    /// 另存的副本：撤销 = 副本（和为它新建的 .xmp）进废纸篓
    case copy(original: MediaItem, created: URL, sidecar: URL?)
    /// 替换原图：撤销 = 编辑后的文件进废纸篓，原图从废纸篓放回
    case replace(TrashEntry)
    /// 保存旋转改了原图的方向标记：撤销 = 改回 old
    case rotation(url: URL, old: Int, new: Int)
}

/// 删除、评星和编辑共用的撤销记录（spec R7-01）：按时间先后，⌘Z 撤销最近的一条，最多 100 条
struct UndoHistory: Equatable {
    enum Entry: Equatable {
        case trash(TrashEntry)
        case rating(RatingChange)
        case edit(EditUndo)
    }

    private(set) var entries: [Entry] = []
    static let limit = 100

    var canUndo: Bool { !entries.isEmpty }
    var last: Entry? { entries.last }

    mutating func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    @discardableResult
    mutating func pop() -> Entry? { entries.popLast() }

    mutating func removeAll() { entries.removeAll() }

    /// 写盘失败时：去掉这个文件最近一条评星记录（spec S-14：失败的操作不进撤销记录）
    mutating func removeLastRating(for url: URL) {
        guard let i = entries.lastIndex(where: { if case .rating(let c) = $0 { c.item.url == url } else { false } }) else { return }
        entries.remove(at: i)
    }
}
