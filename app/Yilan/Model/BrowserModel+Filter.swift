import SwiftUI

/// 筛选：结果列表、面板、改条件后的选中、暂留（spec 第 6 节）
extension BrowserModel {
    /// 这个文件符合星级、格式条件（不看类型）
    func matchesBrowseFilter(_ item: MediaItem) -> Bool {
        browseFilter.matches(ItemFacts(item: item, rating: ratings[item.url]))
    }

    /// 结果列表 = 类型 ∧ 筛选，再把暂留的文件按原来的位置放回去
    func resultList() -> [MediaItem] {
        let active = browseFilter.isActive
        return allItems.filter { item in
            guard filter.includes(item) else { return false }
            if !active || item.url == stickyURL { return true }
            return matchesBrowseFilter(item)
        }
    }

    /// 类型切换上的数字：没有筛选时就是文件夹里的数量，有筛选时是结果里的数量（spec R6-03）
    var filteredCounts: [MediaFilter: Int] {
        browseFilter.isActive ? FilterFacets.typeCounts(items: allItems, ratings: ratings, filter: browseFilter) : counts
    }

    /// 面板里的各项数量
    var filterFacets: FilterFacets {
        FilterFacets.compute(items: allItems, ratings: ratings, type: filter, filter: browseFilter)
    }

    /// 结果为空：显示“没有符合条件的文件”卡片（spec F-05）
    var showsEmptyFilterResult: Bool {
        hasOpenedFolder && !allItems.isEmpty && items.isEmpty && browseFilter.isActive
    }

    // MARK: - 改条件

    /// 改筛选条件：立即生效（spec R5-08）。当前文件还在就不动，不在就按 F-03 选
    func setBrowseFilter(_ newFilter: BrowseFilter) {
        guard newFilter != browseFilter else { return }
        let previous = current
        browseFilter = newFilter
        stickyURL = nil
        items = resultList()
        let index = FilterSelection.indexAfterFilterChange(keeping: previous, in: allItems, newList: items)
        if let index, items[index] == previous {
            currentIndex = index
        } else {
            select(index)
        }
    }

    func setRatingCriterion(_ mode: RatingCriterion.Mode) {
        // 类型是「视频」时不能有星级条件（视频暂不支持评星）：面板置灰，数字键也不起作用
        guard filter != .videos || mode == .any else { return }
        var f = browseFilter
        f.rating.mode = mode
        setBrowseFilter(f)
    }

    /// 筛选面板开着时的数字键：1–5 选星级，再按同一个数字在「及以上」和「仅」之间切换，0 = 不限
    func filterDigit(_ value: Int) {
        guard value > 0 else { setRatingCriterion(.any); return }
        if browseFilter.rating.mode == .stars(value) {
            guard value < 5 else { return }
            setRatingComparison(browseFilter.rating.comparison == .atLeast ? .exactly : .atLeast)
        } else {
            setRatingCriterion(.stars(value))
        }
    }

    /// 「及以上」/「仅」：保留选中的 N，立即生效
    func setRatingComparison(_ comparison: RatingCriterion.Comparison) {
        var f = browseFilter
        f.rating.comparison = comparison
        setBrowseFilter(f)
    }

    func toggleFormat(_ group: FormatGroup) {
        var f = browseFilter
        if f.format.selected.contains(group) { f.format.selected.remove(group) } else { f.format.selected.insert(group) }
        setBrowseFilter(f)
    }

    /// 清除筛选：星级和格式一起清掉，类型切换不动（spec R5-11）
    func clearBrowseFilter() {
        setBrowseFilter(BrowseFilter())
    }

    /// 换文件夹：筛选清空、面板关闭
    func resetBrowseFilter() {
        browseFilter = BrowseFilter()
        stickyURL = nil
        filterPanelOpen = false
    }

    // MARK: - 面板

    func toggleFilterPanel() {
        guard hasOpenedFolder, !allItems.isEmpty || filterPanelOpen else { return }
        withAnimation(.easeOut(duration: 0.15)) { filterPanelOpen.toggle() }
    }

    func closeFilterPanel() {
        guard filterPanelOpen else { return }
        withAnimation(.easeOut(duration: 0.12)) { filterPanelOpen = false }
    }

    // MARK: - 星级变了

    /// 星级变化后更新结果：当前文件不再符合就暂留（spec F-01），其他文件按新星级进出结果
    func ratingsDidChange() {
        guard browseFilter.rating.isActive else { return }
        let cur = current
        if let cur, !matchesBrowseFilter(cur) { stickyURL = cur.url }
        let newItems = resultList()
        guard newItems != items else { return }
        items = newItems
        if let cur, let i = items.firstIndex(of: cur) {
            currentIndex = i
        } else if cur == nil {
            select(items.isEmpty ? nil : 0)
        }
    }
}
