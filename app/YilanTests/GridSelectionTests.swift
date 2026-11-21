import Foundation
import Testing
@testable import Yilan

// 图标视图的选择计算（spec 第 5 节）：纯函数

private func u(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/g/\(String(format: "%03d", n)).jpg") }
private func list(_ count: Int) -> [URL] { (0..<count).map(u) }
private func set(_ ns: Int...) -> Set<URL> { Set(ns.map(u)) }

@Suite("选择：鼠标")
struct GridSelectionMouseTests {
    let items = list(10)

    @Test("单击只选中它，它成为焦点和 ⇧ 的起点（spec X1-01）")
    func click() {
        let s = GridSelection.click(u(3))
        #expect(s.selection == set(3) && s.focus == u(3) && s.anchor == u(3) && s.lastClicked == u(3))
    }

    @Test("⌘ 点按：加入、取消（spec X1-02）")
    func command() {
        var s = GridSelection.click(u(3))
        s = GridSelection.commandClick(u(5), state: s)
        #expect(s.selection == set(3, 5) && s.anchor == u(5) && s.lastClicked == u(5))
        s = GridSelection.commandClick(u(3), state: s)
        #expect(s.selection == set(5))
        s = GridSelection.commandClick(u(5), state: s)
        #expect(s.selection.isEmpty)
    }

    @Test("⇧ 点按：从起点到被点的那张全选，替换原来的选择，起点不变；可以往回选（spec X1-03）")
    func shift() {
        var s = GridSelection.click(u(3))
        s = GridSelection.shiftClick(u(6), state: s, items: items)
        #expect(s.selection == set(3, 4, 5, 6) && s.anchor == u(3) && s.lastClicked == u(6))
        s = GridSelection.shiftClick(u(1), state: s, items: items)
        #expect(s.selection == set(1, 2, 3) && s.anchor == u(3))
    }

    @Test("没有起点时 ⇧ 点按等同于单击")
    func shiftWithoutAnchor() {
        #expect(GridSelection.shiftClick(u(4), state: .empty, items: items) == .single(u(4)))
    }

    @Test("⌘⇧ 点按：把那一段加进已有的选择（spec X1-04）")
    func commandShift() {
        var s = GridSelection.click(u(0))
        s = GridSelection.commandClick(u(5), state: s)
        s = GridSelection.shiftClick(u(7), state: s, items: items, union: true)
        #expect(s.selection == set(0, 5, 6, 7))
    }

    @Test("全选、取消全选；取消后焦点保留（spec X1-05、X1-06）")
    func selectAll() {
        var s = GridSelection.click(u(2))
        s = GridSelection.selectAll(items, state: s)
        #expect(s.selection.count == 10 && s.focus == u(2))
        s = GridSelection.deselectAll(s)
        #expect(s.selection.isEmpty && s.focus == u(2) && s.anchor == nil)
    }

    @Test("框选报上来的集合：焦点落在其中最靠后的一张")
    func band() {
        let s = GridSelection.replace(with: set(2, 3, 8), state: .single(u(0)), items: items)
        #expect(s.selection == set(2, 3, 8) && s.focus == u(8) && s.anchor == u(2))
        let none = GridSelection.replace(with: [], state: s, items: items)
        #expect(none.selection.isEmpty && none.focus == u(8))
    }

    @Test("多选时进大图显示最后点的那一张（spec SEL-04）")
    func representative() {
        var s = GridSelection.click(u(2))
        s = GridSelection.commandClick(u(7), state: s)
        s = GridSelection.commandClick(u(4), state: s)
        #expect(GridSelection.representative(s, items: items) == u(4))
        s.lastClicked = nil
        #expect(GridSelection.representative(s, items: items) == u(2))
        #expect(GridSelection.representative(GridSelectionState(focus: u(6)), items: items) == u(6))
        #expect(GridSelection.representative(.empty, items: items) == u(0))
        #expect(GridSelection.representative(.empty, items: []) == nil)
    }
}

@Suite("选择：键盘")
struct GridSelectionKeyboardTests {
    // 10 张、4 列：  0 1 2 3 / 4 5 6 7 / 8 9
    let items = list(10)

    @Test("上下左右移动；到边缘不动，不循环（spec V4-01）")
    func arrows() {
        func go(_ from: Int, _ d: GridSelection.Direction) -> Int {
            GridSelection.step(from: from, d, count: 10, columns: 4)
        }
        #expect(go(5, .left) == 4 && go(5, .right) == 6 && go(5, .up) == 1 && go(5, .down) == 9)
        #expect(go(0, .left) == 0 && go(0, .up) == 0)
        #expect(go(9, .right) == 9 && go(9, .down) == 9)
        #expect(go(3, .right) == 4)         // 行尾往右到下一行第一个
        #expect(go(4, .left) == 3)
        #expect(go(6, .down) == 9)          // 正下方没有格子：落到最后一张
        #expect(go(8, .down) == 8)
    }

    @Test("方向键的结果是只选中新位置那一张")
    func moveSelectsOne() {
        var s = GridSelection.click(u(1))
        s = GridSelection.commandClick(u(5), state: s)
        s = GridSelection.move(.right, state: s, items: items, columns: 4)
        #expect(s == .single(u(6)))
    }

    @Test("没有选中时第一次按方向键：选中焦点项；没有焦点就选第一张可见的（spec V4-01）")
    func moveFromNothing() {
        let withFocus = GridSelectionState(focus: u(6))
        #expect(GridSelection.move(.right, state: withFocus, items: items, columns: 4) == .single(u(6)))
        #expect(GridSelection.move(.down, state: .empty, items: items, columns: 4, firstVisible: 4) == .single(u(4)))
        #expect(GridSelection.move(.down, state: .empty, items: [], columns: 4) == .empty)
    }

    @Test("Home / End / PageUp / PageDown（spec V4-02）")
    func edgesAndPages() {
        #expect(GridSelection.moveToEdge(first: true, items: items) == .single(u(0)))
        #expect(GridSelection.moveToEdge(first: false, items: items) == .single(u(9)))
        let big = list(40)   // 4 列 10 行
        let s = GridSelection.click(u(5))
        #expect(GridSelection.movePage(down: true, state: s, items: big, columns: 4, rows: 3) == .single(u(17)))
        #expect(GridSelection.movePage(down: false, state: .single(u(17)), items: big, columns: 4, rows: 3) == .single(u(5)))
        #expect(GridSelection.movePage(down: false, state: s, items: big, columns: 4, rows: 3) == .single(u(1)))     // 到顶：同一列第一行
        #expect(GridSelection.movePage(down: true, state: .single(u(34)), items: big, columns: 4, rows: 3) == .single(u(38)))
    }

    @Test("⇧ + 方向键：起点不动，另一端移动（spec X6-01）")
    func extend() {
        var s = GridSelection.click(u(5))
        s = GridSelection.extend(.right, state: s, items: items, columns: 4)
        #expect(s.selection == set(5, 6) && s.anchor == u(5) && s.focus == u(6))
        s = GridSelection.extend(.down, state: s, items: items, columns: 4)
        #expect(s.selection == set(5, 6, 7, 8, 9))
        s = GridSelection.extend(.up, state: s, items: items, columns: 4)
        #expect(s.selection == set(5))
        s = GridSelection.extend(.left, state: s, items: items, columns: 4)
        #expect(s.selection == set(4, 5) && s.anchor == u(5))
    }
}

@Suite("选择：列表变了")
struct GridSelectionReconcileTests {
    @Test("不在新列表里的从选中里去掉；焦点移到原位置上现在的那一张（spec V8-02）")
    func removes() {
        let old = list(8)
        var s = GridSelection.click(u(2))
        s = GridSelection.commandClick(u(5), state: s)   // 焦点 5
        let new = old.filter { $0 != u(5) && $0 != u(6) }
        let r = GridSelection.reconcile(s, items: new, oldItems: old)
        #expect(r.selection == set(2))
        #expect(r.focus == u(7))            // 5 后面第一张还在的
        #expect(r.anchor == nil && r.lastClicked == nil)
    }

    @Test("焦点后面没有了：落到前面最近的一张；列表空了：没有焦点")
    func focusAtEnd() {
        let old = list(4)
        let r = GridSelection.reconcile(.single(u(3)), items: [u(0), u(1)], oldItems: old)
        #expect(r.focus == u(1) && r.selection.isEmpty)
        #expect(GridSelection.reconcile(.single(u(3)), items: [], oldItems: old).focus == nil)
    }

    @Test("改名的文件跟着改，仍然选中（spec V8-04）")
    func renamed() {
        let old = list(4)
        let renamedTo = URL(fileURLWithPath: "/tmp/g/renamed.jpg")
        let new = [u(0), u(1), u(3), renamedTo]
        let r = GridSelection.reconcile(.single(u(2)), items: new, oldItems: old, renamed: [u(2): renamedTo])
        #expect(r.selection == [renamedTo] && r.focus == renamedTo)
    }

    @Test("按列表顺序排好")
    func ordered() {
        #expect(GridSelection.ordered(set(7, 1, 4), in: list(10)) == [u(1), u(4), u(7)])
    }
}

@Suite("图标视图的排列")
struct GridMetricsTests {
    @Test("1280 宽、默认大小：6 列，左右边距 24，列间距平均分")
    func columns() {
        let m = GridMetrics(size: .m, width: 1280)
        #expect(m.cellWidth == 176)
        #expect(m.columns == 6)
        #expect(m.columnGap >= GridMetrics.minColumnGap)
        #expect(CGFloat(m.columns) * m.cellWidth + CGFloat(m.columns - 1) * m.columnGap <= 1280 - 48)
        #expect(GridMetrics(size: .m, width: 640).columns == 3)
        #expect(GridMetrics(size: .xs, width: 1280).columns == 9)
        #expect(GridMetrics(size: .xl, width: 1280).columns == 4)
        #expect(GridMetrics(size: .xl, width: 100).columns == 1)
    }

    @Test("窗口变窄列数变少")
    func narrower() {
        #expect(GridMetrics(size: .m, width: 964).columns == 5)
    }

    @Test("缩略图保持原比例：比 4:3 扁的顶满宽，其余顶满高（spec V1-02）")
    func thumbnailSize() {
        let m = GridMetrics(size: .m, width: 1280)
        #expect(m.thumbnailSize(aspect: 1.5) == CGSize(width: 160, height: 107))
        #expect(m.thumbnailSize(aspect: 4.0 / 3) == CGSize(width: 160, height: 120))
        #expect(m.thumbnailSize(aspect: 2.0 / 3) == CGSize(width: 80, height: 120))
        #expect(m.thumbnailSize(aspect: 0).height <= 120)
    }

    @Test("缩略图大小 5 档，滑块吸附到最近一档（spec V5-01）")
    func sizes() {
        #expect(GridSize.allCases.map(\.rawValue) == [104, 132, 160, 196, 232])
        #expect(GridSize.default == .m)
        #expect(GridSize.m.larger == .l && GridSize.xl.larger == .xl && GridSize.xs.smaller == .xs)
        #expect(GridSize.nearest(fraction: 0) == .xs && GridSize.nearest(fraction: 1) == .xl)
        #expect(GridSize.nearest(fraction: GridSize.m.fraction + 0.02) == .m)
        #expect(!GridSize.m.usesLargeThumbnails && GridSize.l.usesLargeThumbnails)
    }
}
