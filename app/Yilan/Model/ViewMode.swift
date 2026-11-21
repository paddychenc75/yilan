import Foundation

/// 两种视图（spec 第 3 节）
enum ViewMode: String, Sendable, CaseIterable {
    /// 一张大图加底部缩略图栏
    case gallery
    /// 缩略图铺满窗口
    case grid
}

/// 「打开文件夹时用」的选项（spec V6-02）
enum OpenFolderView: String, Sendable, CaseIterable, Identifiable {
    case last, gallery, grid
    var id: String { rawValue }
}

/// 图标视图的缩略图大小：缩略图区的宽度，5 档（spec V5-01）
enum GridSize: Int, Sendable, CaseIterable, Comparable {
    case xs = 104, s = 132, m = 160, l = 196, xl = 232

    static let `default` = GridSize.m

    static func < (a: GridSize, b: GridSize) -> Bool { a.rawValue < b.rawValue }

    /// 缩略图区宽、高（4:3）
    var box: CGFloat { CGFloat(rawValue) }
    var boxHeight: CGFloat { (box * 0.75).rounded() }

    var larger: GridSize { Self.allCases.first { $0 > self } ?? self }
    var smaller: GridSize { Self.allCases.last { $0 < self } ?? self }

    /// 滑块位置（0–1）最近的一档
    static func nearest(fraction: Double) -> GridSize {
        let all = allCases
        let lo = Double(all.first!.rawValue), hi = Double(all.last!.rawValue)
        let value = lo + min(max(fraction, 0), 1) * (hi - lo)
        return all.min { abs(Double($0.rawValue) - value) < abs(Double($1.rawValue) - value) }!
    }

    var fraction: Double {
        let lo = Double(Self.allCases.first!.rawValue), hi = Double(Self.allCases.last!.rawValue)
        return (Double(rawValue) - lo) / (hi - lo)
    }

    /// 这一档要用大缩略图（长边 640），不然在高分屏上发糊（spec V5-04）
    var usesLargeThumbnails: Bool { self >= .l }
}

/// 图标视图的选择状态（spec 第 5 节）
struct GridSelectionState: Equatable, Sendable {
    /// 选中的文件
    var selection: Set<URL> = []
    /// 焦点项：键盘操作的起点。选中一张时就是它；没有选中时是上次操作留下的位置
    var focus: URL?
    /// ⇧ 的起点
    var anchor: URL?
    /// 最后点的那一张（多选时进大图显示它）
    var lastClicked: URL?

    static let empty = GridSelectionState()

    static func single(_ url: URL?) -> GridSelectionState {
        guard let url else { return .empty }
        return GridSelectionState(selection: [url], focus: url, anchor: url, lastClicked: url)
    }

    var isMultiple: Bool { selection.count > 1 }
    /// 恰好选中一张时是它
    var only: URL? { selection.count == 1 ? selection.first : nil }
}

/// 选择的计算：都是纯函数，输入列表和当前状态，输出新状态（技术方案 3.1）
enum GridSelection {
    enum Direction: Sendable { case left, right, up, down }

    // MARK: 鼠标

    /// 单击：只选中它（spec X1-01）
    static func click(_ url: URL) -> GridSelectionState { .single(url) }

    /// ⌘ + 点按：加入或取消（spec X1-02）
    static func commandClick(_ url: URL, state: GridSelectionState) -> GridSelectionState {
        var s = state
        if s.selection.contains(url) { s.selection.remove(url) } else { s.selection.insert(url) }
        s.anchor = url
        s.lastClicked = url
        s.focus = url
        return s
    }

    /// ⇧ + 点按：从起点到这一张按列表顺序全部选中；union 为 true（同时按着 ⌘）时加进已有的选择（spec X1-03、X1-04）
    static func shiftClick(_ url: URL, state: GridSelectionState, items: [URL], union: Bool = false) -> GridSelectionState {
        guard let anchor = state.anchor, let a = items.firstIndex(of: anchor), let b = items.firstIndex(of: url) else {
            return click(url)
        }
        var s = state
        let range = Set(items[min(a, b)...max(a, b)])
        s.selection = union ? s.selection.union(range) : range
        s.focus = url
        s.lastClicked = url
        return s
    }

    /// ⌘A（spec X1-05）
    static func selectAll(_ items: [URL], state: GridSelectionState) -> GridSelectionState {
        var s = state
        s.selection = Set(items)
        if s.focus == nil { s.focus = items.first }
        if s.anchor == nil { s.anchor = items.first }
        return s
    }

    /// 取消全部选中；焦点保留（spec X1-06）
    static func deselectAll(_ state: GridSelectionState) -> GridSelectionState {
        var s = state
        s.selection = []
        s.anchor = nil
        s.lastClicked = nil
        return s
    }

    /// 框选等由视图报上来的一组选中：焦点落在其中列表里最靠后的一张
    static func replace(with urls: Set<URL>, state: GridSelectionState, items: [URL]) -> GridSelectionState {
        var s = state
        s.selection = urls
        if let last = items.last(where: { urls.contains($0) }) {
            s.focus = last
            s.lastClicked = last
            if s.anchor == nil || !urls.contains(s.anchor!) { s.anchor = items.first { urls.contains($0) } }
        } else {
            s.anchor = nil
            s.lastClicked = nil
        }
        return s
    }

    // MARK: 键盘

    /// 从 index 往某个方向走一格后的位置；到边缘不动（spec V4-01）
    static func step(from index: Int, _ direction: Direction, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let cols = max(columns, 1)
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, count - 1)
        case .up: return index - cols >= 0 ? index - cols : index
        case .down:
            if index + cols < count { return index + cols }
            // 正下方没有格子，但下面还有一行：落到最后一张
            let lastRow = (count - 1) / cols
            return index / cols < lastRow ? count - 1 : index
        }
    }

    /// 键盘移动的起点：焦点项；没有就用给的第一张可见的
    private static func origin(_ state: GridSelectionState, items: [URL], firstVisible: Int) -> Int? {
        if let f = state.focus, let i = items.firstIndex(of: f) { return i }
        guard !items.isEmpty else { return nil }
        return min(max(firstVisible, 0), items.count - 1)
    }

    /// 方向键：结果是只选中新位置的那一张。没有选中时第一次按，选中焦点项本身（spec V4-01）
    static func move(_ direction: Direction, state: GridSelectionState, items: [URL], columns: Int, firstVisible: Int = 0) -> GridSelectionState {
        guard let from = origin(state, items: items, firstVisible: firstVisible) else { return state }
        if state.selection.isEmpty { return .single(items[from]) }
        return .single(items[step(from: from, direction, count: items.count, columns: columns)])
    }

    /// Home / End
    static func moveToEdge(first: Bool, items: [URL]) -> GridSelectionState {
        .single(first ? items.first : items.last)
    }

    /// PageUp / PageDown：移动一屏的行数（spec V4-02）
    static func movePage(down: Bool, state: GridSelectionState, items: [URL], columns: Int, rows: Int, firstVisible: Int = 0) -> GridSelectionState {
        guard let from = origin(state, items: items, firstVisible: firstVisible) else { return state }
        let cols = max(columns, 1), jump = max(rows, 1) * cols
        var target = down ? from + jump : from - jump
        if target < 0 { target = from % cols }
        if target > items.count - 1 {
            // 落到最后一行里同一列，没有就最后一张
            let lastRowStart = (items.count - 1) / cols * cols
            target = min(lastRowStart + from % cols, items.count - 1)
        }
        return .single(items[target])
    }

    /// ⇧ + 方向键：起点不动，另一端移动一格，两端之间全部选中（spec X6-01）
    static func extend(_ direction: Direction, state: GridSelectionState, items: [URL], columns: Int, firstVisible: Int = 0) -> GridSelectionState {
        guard let from = origin(state, items: items, firstVisible: firstVisible) else { return state }
        guard !state.selection.isEmpty, let anchor = state.anchor, let a = items.firstIndex(of: anchor) else {
            return .single(items[from])
        }
        let to = step(from: from, direction, count: items.count, columns: columns)
        var s = state
        s.selection = Set(items[min(a, to)...max(a, to)])
        s.focus = items[to]
        s.lastClicked = items[to]
        return s
    }

    // MARK: 列表变了

    /// 列表变化后收拾（spec V8-02、V8-04）：不在列表里的从选中里去掉；焦点不在了就移到原来位置上现在的那一张。
    /// renamed：改名的文件（旧地址 → 新地址）跟着改
    static func reconcile(_ state: GridSelectionState, items: [URL], oldItems: [URL], renamed: [URL: URL] = [:]) -> GridSelectionState {
        var s = state
        func map(_ url: URL) -> URL { renamed[url] ?? url }
        let present = Set(items)
        s.selection = Set(state.selection.map(map).filter(present.contains))
        s.anchor = state.anchor.map(map).flatMap { present.contains($0) ? $0 : nil }
        s.lastClicked = state.lastClicked.map(map).flatMap { present.contains($0) ? $0 : nil }
        if let focus = state.focus.map(map) {
            if present.contains(focus) {
                s.focus = focus
            } else if let old = oldItems.firstIndex(of: state.focus!) {
                s.focus = nearestSurvivor(after: old, oldItems: oldItems, present: present) ?? items.last
            } else {
                s.focus = items.first
            }
        }
        if items.isEmpty { s.focus = nil }
        return s
    }

    /// 旧列表里 index 之后第一张还在的；没有就往前找
    static func nearestSurvivor(after index: Int, oldItems: [URL], present: Set<URL>) -> URL? {
        if index < oldItems.count, let next = oldItems[index...].first(where: present.contains) { return next }
        return oldItems[..<min(index, oldItems.count)].last(where: present.contains)
    }

    /// 选中的文件按列表顺序排好
    static func ordered(_ selection: Set<URL>, in items: [URL]) -> [URL] {
        items.filter(selection.contains)
    }

    /// 多选时进大图显示哪一张（spec SEL-04）：最后点的那一张；它不在选中里时用选中里排最前的
    static func representative(_ state: GridSelectionState, items: [URL]) -> URL? {
        if let last = state.lastClicked, state.selection.contains(last) { return last }
        if let first = items.first(where: state.selection.contains) { return first }
        if let focus = state.focus, items.contains(focus) { return focus }
        return items.first
    }
}

/// 图标视图的排列（spec V1-08）：一行放几列、每格多大。纯计算，视图和键盘共用
struct GridMetrics: Equatable, Sendable {
    let size: GridSize
    /// 可用宽度（窗口宽，信息面板打开时减去面板）
    let width: CGFloat

    static let sideMargin: CGFloat = 24
    static let minColumnGap: CGFloat = 8
    static let rowGap: CGFloat = 10
    /// 缩略图区四周各留 8
    static let boxInset: CGFloat = 8
    static let nameGap: CGFloat = 6
    static let nameHeight: CGFloat = 20
    /// 网格内容上下留的空（让第一行、最后一行露在顶部栏和信息条外面）
    static let topInset: CGFloat = 72
    static let bottomInset: CGFloat = 72

    var cellWidth: CGFloat { size.box + Self.boxInset * 2 }
    var cellHeight: CGFloat { size.boxHeight + Self.boxInset * 2 + Self.nameGap + Self.nameHeight }

    var columns: Int {
        let usable = width - Self.sideMargin * 2
        return max(1, Int((usable + Self.minColumnGap) / (cellWidth + Self.minColumnGap)))
    }

    /// 列间距平均分
    var columnGap: CGFloat {
        let n = columns
        guard n > 1 else { return 0 }
        return max(Self.minColumnGap, ((width - Self.sideMargin * 2 - CGFloat(n) * cellWidth) / CGFloat(n - 1)).rounded(.down))
    }

    var rowStride: CGFloat { cellHeight + Self.rowGap }

    /// 一屏能放下几行（PageUp / PageDown 用）
    func visibleRows(height: CGFloat) -> Int {
        max(1, Int((height - Self.topInset - Self.bottomInset + Self.rowGap) / rowStride))
    }

    /// 缩略图在缩略图区里的大小：比 4:3 更扁的顶满宽，其余顶满高（spec V1-02）
    func thumbnailSize(aspect: CGFloat) -> CGSize {
        let a = aspect > 0 ? aspect : 1.5
        if a >= size.box / size.boxHeight { return CGSize(width: size.box, height: (size.box / a).rounded()) }
        return CGSize(width: (size.boxHeight * a).rounded(), height: size.boxHeight)
    }
}
