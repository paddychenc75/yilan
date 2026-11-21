import SwiftUI

/// 顶部栏各控件的实际宽度（由隐藏的测量视图报上来，中英文各不相同）
struct TopBarWidths: Equatable {
    var segFull: CGFloat = 263
    var segSlim: CGFloat = 152
    /// 筛选按钮三种样子；没有筛选按钮时都是 0
    var filterFull: CGFloat = 0
    var filterCount: CGFloat = 0
    var filterIcon: CGFloat = 0
    var zoomFull: CGFloat = 132
    var zoomPercent: CGFloat = 68
    var counter: CGFloat = 0
    var tools: CGFloat = 102
    /// 红绿灯右边的视图切换；没有时是 0（spec TB-03）
    var viewSwitch: CGFloat = 0
    /// 计数只显示数量部分时的宽度（spec TB-04）；0 = 没有这一档
    var counterShort: CGFloat = 0
}

/// 筛选按钮的样子：完整摘要 / “筛选 · 2” / 漏斗 + 徽标
enum FilterButtonMode: Equatable { case full, count, icon }
/// 缩放控件：完整 / 只留百分比 / 收进 ⋯ 菜单
enum ZoomControlMode: Equatable { case full, percent, menu }

/// 顶部栏收缩到哪一档（spec E1-10）：按设计稿的顺序一步步收，找第一档放得下的
struct TopBarTier: Equatable {
    var filter: FilterButtonMode
    var zoom: ZoomControlMode
    var segSlim: Bool
    var leftAligned: Bool
    /// 计数只显示数量部分（spec TB-04）：最后一档
    var counterShort = false

    /// 筛选按钮只写条件个数（“筛选 · 2”），不写完整条件：条件一变按钮宽度就变，顶部栏会抖，也放不下。
    /// 收缩顺序：① 缩放只留百分比 ② 类型只留图标 ③ 筛选缩成漏斗 ④ 缩放进 ⋯ 菜单 ⑤ 筛选组靠左
    static let steps: [TopBarTier] = [
        .init(filter: .count, zoom: .full, segSlim: false, leftAligned: false),
        .init(filter: .count, zoom: .percent, segSlim: false, leftAligned: false),
        .init(filter: .count, zoom: .percent, segSlim: true, leftAligned: false),
        .init(filter: .icon, zoom: .percent, segSlim: true, leftAligned: false),
        .init(filter: .icon, zoom: .menu, segSlim: true, leftAligned: false),
        .init(filter: .icon, zoom: .menu, segSlim: true, leftAligned: true),
        .init(filter: .icon, zoom: .menu, segSlim: true, leftAligned: true, counterShort: true),
    ]

    /// 红绿灯区域的右边（设计稿：靠左时筛选组距左 84）
    static let leftEdge: CGFloat = 84
    /// 视图切换和中间一组靠左时的间距
    static let switchGap: CGFloat = 12

    /// 中间一组靠左时的左缘：有视图切换时紧跟在它右边（spec TB-03）
    static func leftEdge(_ w: TopBarWidths) -> CGFloat {
        w.viewSwitch > 0 ? leftEdge + 2 + w.viewSwitch + switchGap : leftEdge
    }
    /// 控件之间至少留的距离
    static let gap: CGFloat = 14
    /// 筛选组里类型切换和筛选按钮的间距
    static let groupSpacing: CGFloat = 10
    /// 右组离窗口右边
    static let trailing: CGFloat = 16

    /// 中间一组（类型切换 + 筛选按钮）的宽度
    func centerWidth(_ w: TopBarWidths) -> CGFloat {
        let seg = segSlim ? w.segSlim : w.segFull
        let filterWidth: CGFloat = switch filter {
        case .full: w.filterFull
        case .count: w.filterCount
        case .icon: w.filterIcon
        }
        return filterWidth > 0 ? seg + Self.groupSpacing + filterWidth : seg
    }

    /// 右边一组（缩放、序号、工具组）加右边距
    func rightWidth(_ w: TopBarWidths, hasZoom: Bool) -> CGFloat {
        var total = w.tools + Self.trailing
        if w.counter > 0 { total += (counterShort && w.counterShort > 0 ? w.counterShort : w.counter) + Self.gap }
        if hasZoom {
            switch zoom {
            case .full: total += w.zoomFull + Self.gap
            case .percent: total += w.zoomPercent + Self.gap
            case .menu: break
            }
        }
        return total
    }

    func fits(width: CGFloat, widths: TopBarWidths, hasZoom: Bool) -> Bool {
        let c = centerWidth(widths)
        let rightStart = width - rightWidth(widths, hasZoom: hasZoom)
        let left = Self.leftEdge(widths)
        if leftAligned { return left + c + Self.gap <= rightStart }
        return width / 2 + c / 2 + Self.gap <= rightStart && width / 2 - c / 2 >= left
    }

    /// 这个窗口宽度用哪一档；都放不下时用最后一档
    static func choose(width: CGFloat, widths: TopBarWidths, hasZoom: Bool) -> TopBarTier {
        steps.first { $0.fits(width: width, widths: widths, hasZoom: hasZoom) } ?? steps[steps.count - 1]
    }
}
