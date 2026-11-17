import Foundation

/// 格式分区里的一项（spec R5b-01、R5b-02）：所有 RAW 合成一项，heic/heif、jpg/jpeg、tif/tiff 合并
enum FormatGroup: String, CaseIterable, Sendable, Identifiable {
    case raw, heic, jpeg, png, webp, gif, tiff, bmp, svg
    case mp4, mov, m4v

    var id: String { rawValue }

    /// 胶囊上的名字（格式名不翻译）
    var title: String {
        switch self {
        case .raw: "RAW"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .webp: "WebP"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .svg: "SVG"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .m4v: "M4V"
        }
    }

    var kind: MediaKind {
        switch self {
        case .mp4, .mov, .m4v: .video
        default: .image
        }
    }

    static func of(_ item: MediaItem) -> FormatGroup? {
        if item.format == .raw { return .raw }
        switch item.url.pathExtension.lowercased() {
        case "heic", "heif": return .heic
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        case "svg": return .svg
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        default: return nil
        }
    }
}

/// 筛选时要看的一个文件的事实：文件本身 + 星级（以后加色标、日期也放这里）
struct ItemFacts {
    let item: MediaItem
    /// 星级；还没读出来时 nil（按未评星算）
    let rating: Int?
}

/// 一种筛选条件（技术方案 4.3）：以后加色标、日期，就再写一个实现这个协议的类型
protocol FilterCriterion: Equatable, Sendable {
    var isActive: Bool { get }
    func matches(_ facts: ItemFacts) -> Bool
}

/// 星级分区（spec R5a）：不限 / 不低于 N 星 / 未评星，单选
struct RatingCriterion: FilterCriterion {
    enum Mode: Equatable, Sendable {
        case any
        case atLeast(Int)
        case unrated
    }

    var mode: Mode = .any

    var isActive: Bool { mode != .any }

    func matches(_ facts: ItemFacts) -> Bool {
        // 视频没有星级：任何星级条件（包括“未评星”）都不包含视频
        if mode != .any, facts.item.kind == .video { return false }
        let r = facts.rating ?? 0
        switch mode {
        case .any: return true
        case .atLeast(let n): return r >= n
        case .unrated: return r == 0
        }
    }
}

/// 格式分区（spec R5b）：多选，同一分区里是“或”
struct FormatCriterion: FilterCriterion {
    var selected: Set<FormatGroup> = []

    var isActive: Bool { !selected.isEmpty }

    func matches(_ facts: ItemFacts) -> Bool {
        selected.isEmpty || FormatGroup.of(facts.item).map(selected.contains) == true
    }
}

/// 当前窗口的全部筛选条件；不同分区之间是“且”（spec R5-10）
struct BrowseFilter: Equatable, Sendable {
    var rating = RatingCriterion()
    var format = FormatCriterion()

    var isActive: Bool { rating.isActive || format.isActive }
    /// 生效的筛选种类数（按钮“筛选 · 2”的数字，不是格式个数）
    var activeKinds: Int { (rating.isActive ? 1 : 0) + (format.isActive ? 1 : 0) }

    func matches(_ facts: ItemFacts) -> Bool {
        rating.matches(facts) && format.matches(facts)
    }

    /// 摘要的各部分：“≥4 星”“未评星”“RAW”“2 种格式”（spec R5-03）
    var summaryParts: [String] {
        var parts: [String] = []
        switch rating.mode {
        case .atLeast(let n): parts.append(String(localized: "≥\(n) 星", comment: "筛选按钮摘要：星级不低于 N"))
        case .unrated: parts.append(String(localized: "未评星"))
        case .any: break
        }
        if format.selected.count == 1, let only = format.selected.first {
            parts.append(only.title)
        } else if format.selected.count > 1 {
            parts.append(String(localized: "\(format.selected.count) 种格式", comment: "筛选按钮摘要：选了几种格式"))
        }
        return parts
    }
}

/// 面板和类型切换上的数量（spec R6）：每个分区的数量 = 类型 + 其他分区条件下的数量
struct FilterFacets: Equatable {
    /// 文件夹里实际有的格式（按固定顺序）
    var presentFormats: [FormatGroup] = []
    /// 每种格式在“类型 + 星级条件”下的数量
    var formatCounts: [FormatGroup: Int] = [:]
    /// 在“类型 + 格式条件”下的未评星数量
    var unratedCount = 0
    /// 结果数（类型 + 全部条件）
    var resultCount = 0
    /// 文件夹里全部文件数
    var total = 0

    static func compute(items: [MediaItem], ratings: [URL: Int], type: MediaFilter, filter: BrowseFilter) -> FilterFacets {
        var facets = FilterFacets(total: items.count)
        var present = Set<FormatGroup>()
        var unratedOnly = filter
        unratedOnly.rating = RatingCriterion(mode: .unrated)
        var noFormat = filter
        noFormat.format = FormatCriterion()
        for item in items {
            let group = FormatGroup.of(item)
            if let group { present.insert(group) }
            guard type.includes(item) else { continue }
            let facts = ItemFacts(item: item, rating: ratings[item.url])
            if filter.matches(facts) { facets.resultCount += 1 }
            if unratedOnly.matches(facts) { facets.unratedCount += 1 }   // 只算图片（视频没有星级）
            if let group, noFormat.matches(facts) { facets.formatCounts[group, default: 0] += 1 }
        }
        facets.presentFormats = FormatGroup.allCases.filter(present.contains)
        return facets
    }

    /// 类型切换上的数字：各类型在当前筛选条件下的结果数（spec R6-03）
    static func typeCounts(items: [MediaItem], ratings: [URL: Int], filter: BrowseFilter) -> [MediaFilter: Int] {
        var counts: [MediaFilter: Int] = [.all: 0, .images: 0, .videos: 0]
        for item in items where filter.matches(ItemFacts(item: item, rating: ratings[item.url])) {
            counts[.all, default: 0] += 1
            counts[item.kind == .video ? .videos : .images, default: 0] += 1
        }
        return counts
    }
}

extension FilterSelection {
    /// 改了筛选条件后当前文件不在新结果里：显示排在它后面的第一个；后面没有就显示前面最近的一个（spec F-03、PD-12）
    static func indexAfterFilterChange(keeping current: MediaItem?, in all: [MediaItem], newList: [MediaItem]) -> Int? {
        guard !newList.isEmpty else { return nil }
        guard let current else { return 0 }
        if let same = newList.firstIndex(of: current) { return same }
        guard let anchor = all.firstIndex(of: current) else { return 0 }
        var position: [URL: Int] = [:]
        for (i, item) in all.enumerated() { position[item.url] = i }
        if let after = newList.firstIndex(where: { (position[$0.url] ?? -1) > anchor }) { return after }
        return newList.lastIndex { (position[$0.url] ?? Int.max) < anchor } ?? 0
    }
}
