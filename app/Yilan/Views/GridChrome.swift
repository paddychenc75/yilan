import SwiftUI

/// 顶部栏红绿灯右边的视图切换（设计稿 19、21，spec V2-01、V2-02）：高 36，每段 32 × 28
struct ViewSwitch: View {
    let mode: ViewMode
    /// 窗口宽度小于 760：缩成一个按钮，图标是另一种视图
    var single = false
    let onSelect: (ViewMode) -> Void

    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 两段时的宽度：3 + 32 + 2 + 32 + 3；一个按钮时是 40
    nonisolated static func width(single: Bool) -> CGFloat { single ? 40 : 72 }
    nonisolated static let narrowBelow: CGFloat = 760

    var body: some View {
        Group {
            if single {
                let other: ViewMode = mode == .gallery ? .grid : .gallery
                Button { onSelect(other) } label: {
                    Image(systemName: Self.symbol(other))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(other == .grid ? Text("切换到图标视图（G）") : Text("切换到画廊视图（G）"))
                .accessibilityLabel(other == .grid ? Text("切换到图标视图") : Text("切换到画廊视图"))
            } else {
                HStack(spacing: 2) {
                    segment(.gallery)
                    segment(.grid)
                }
                .padding(3)
            }
        }
        .frame(height: 36)
        .regularGlass(Capsule(), interactive: single)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.8), value: mode)
    }

    nonisolated static func symbol(_ mode: ViewMode) -> String {
        mode == .gallery ? "dock.rectangle" : "square.grid.3x3.fill"
    }

    private func segment(_ target: ViewMode) -> some View {
        let selected = target == mode
        return SwitchSegment(symbol: Self.symbol(target), selected: selected, highlight: highlight) {
            onSelect(target)
        }
        .help(target == .gallery ? Text("画廊视图（G）") : Text("图标视图（G）"))
        .accessibilityLabel(target == .gallery ? Text("画廊视图") : Text("图标视图"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SwitchSegment: View {
    let symbol: String
    let selected: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.82))
                .frame(width: 32, height: 28)
                .background {
                    if selected {
                        Capsule().fill(Theme.selectedFill)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "view", in: highlight)
                    } else if hovering {
                        Capsule().fill(Color.white.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 图标视图右上角的计数（spec V1-14）：选中一张「10 / 46」；没有选中「46 项」；多选是强调色底的「已选 5 项」
struct GridCounterPill: View {
    enum Content: Equatable {
        case position(index: Int, total: Int)
        case total(Int)
        case selected(Int)
    }

    let content: Content
    /// 放不下时只显示数量部分（spec TB-04）
    var short = false

    var body: some View {
        Text(verbatim: short ? shortText : text)
            .font(isSelection ? .system(size: 12, weight: .semibold) : Theme.mono(12))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background { if isSelection { Capsule().fill(Theme.accent) } }
            .modifier(GlassUnless(plain: isSelection))
            .help(short ? text : "")
            .accessibilityLabel(Text(verbatim: text))
    }

    private var isSelection: Bool {
        if case .selected = content { return true }
        return false
    }

    var text: String {
        switch content {
        case .position(let index, let total): "\(Formatting.count(index + 1)) / \(Formatting.count(total))"
        case .total(let n): String(localized: "\(n) 项", comment: "图标视图没有选中时右上角的计数；%lld 是数量")
        case .selected(let n): String(localized: "已选 \(n) 项", comment: "多选时的计数；%lld 是数量")
        }
    }

    private var shortText: String {
        switch content {
        case .position(let index, _): Formatting.count(index + 1)
        case .total(let n), .selected(let n): Formatting.count(n)
        }
    }
}

private struct GlassUnless: ViewModifier {
    let plain: Bool
    func body(content: Content) -> some View {
        if plain { content.clipShape(Capsule()) } else { content.regularGlass(Capsule()) }
    }
}

/// 图标视图底部的信息条（设计稿 .gbar，spec V1-10 至 V1-13）：高 40，代替缩略图栏
struct GridInfoBar: View {
    enum Left: Equatable {
        /// 选中一张：文件名、相机预览图标签
        case file(name: String, tag: String?)
        /// 多选、没有选中：粗体的一段加后面的说明
        case summary(title: String, detail: String)
    }

    let left: Left
    /// 中间的五颗星：nil 不显示（视频、多选、没有选中、评星关掉）
    var rating: Int? = nil
    var canRate = true
    var onRate: ((Int) -> Void)? = nil
    /// 右边：尺寸（先让位）、其余（「3.9 MB · HEIF」或「共 86.4 MB」）
    var dims: String? = nil
    var trailing: String = ""
    let size: GridSize
    let onSize: (GridSize) -> Void

    @State private var leftWidth: CGFloat = 0
    @State private var dimsWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var hovering = false

    nonisolated static let height: CGFloat = 40
    nonisolated static let sliderBlock: CGFloat = 12 + 8 + 92 + 8 + 16     // 小图标、滑块、大图标
    nonisolated static let starsWidth: CGFloat = 110

    var body: some View {
        GeometryReader { geo in
            let inner = geo.size.width - 16 - 14
            let plan = GridBarLayout.decide(width: inner, left: leftWidth, stars: onRate != nil, dims: dims == nil ? nil : dimsWidth,
                                            trailing: trailing.isEmpty ? nil : trailingWidth)
            ZStack {
                HStack(spacing: 14) {
                    leftView
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if plan.showDims || plan.showTrailing {
                        HStack(spacing: 6) {
                            if plan.showDims, let dims { mono(dims) }
                            if plan.showDims, plan.showTrailing { mono("·") }
                            if plan.showTrailing { mono(trailing) }
                        }
                        .fixedSize()
                    }
                    Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 16)
                    GridSizeSlider(size: size, onSize: onSize)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)
                if plan.showStars, let onRate {
                    InfoRowStars(rating: rating ?? 0, enabled: canRate, stripHovered: hovering, onRate: onRate)
                        .frame(width: Self.starsWidth)
                        .position(x: plan.starsCenter(in: geo.size.width), y: geo.size.height / 2)
                }
                ZStack {
                    leftView.fixedSize().measure { leftWidth = $0 }
                    if let dims { mono(dims).fixedSize().measure { dimsWidth = $0 } }
                    mono(trailing).fixedSize().measure { trailingWidth = $0 }
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
        .regularGlass(Capsule())
        .onHover { hovering = $0 }
    }

    private func mono(_ text: String) -> some View {
        Text(verbatim: text).font(Theme.mono(11, .regular)).foregroundStyle(Theme.text2).lineLimit(1)
    }

    @ViewBuilder
    private var leftView: some View {
        switch left {
        case .file(let name, let tag):
            HStack(spacing: 8) {
                Text(verbatim: name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tag { PreviewTag(text: tag).fixedSize() }
            }
        case .summary(let title, let detail):
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
        }
    }
}

/// 信息条窗口变窄时谁先让位（spec V1-13）：尺寸 → 「大小 · 格式」 → 星；文件名和滑块保留
struct GridBarLayout: Equatable {
    var showDims: Bool
    var showTrailing: Bool
    var showStars: Bool
    /// 右边一组（文字、分隔线、滑块）占的宽度
    var rightWidth: CGFloat
    var leftWidth: CGFloat

    static let gap: CGFloat = 14
    /// 分隔线加滑块
    static let fixedRight: CGFloat = 1 + gap + GridInfoBar.sliderBlock
    /// 左边文件名至少留这么宽
    static let minLeft: CGFloat = 90

    /// 星放在窗口正中；右边一组太宽、正中放不下时往左挪，不压住右边的文字
    func starsCenter(in barWidth: CGFloat) -> CGFloat {
        let half = GridInfoBar.starsWidth / 2
        let limit = barWidth - 14 - rightWidth - Self.gap - half
        return min(barWidth / 2, limit)
    }

    static func decide(width: CGFloat, left: CGFloat, stars: Bool, dims: CGFloat?, trailing: CGFloat?) -> GridBarLayout {
        func right(_ d: Bool, _ t: Bool) -> CGFloat {
            var w = fixedRight
            var text: CGFloat = 0
            if d, let dims { text += dims }
            if t, let trailing { text += trailing }
            if d, t, dims != nil, trailing != nil { text += 6 + 6 + 4 }
            if text > 0 { w += text + gap }
            return w
        }
        let need = min(left, 220)       // 文件名很长时截断，不为它挤掉别的
        func fits(_ d: Bool, _ t: Bool, _ s: Bool) -> Bool {
            let r = right(d, t)
            if s {
                // 星居中时左右对称地占位；不够就看能不能挤在左右之间
                return max(need, minLeft) + gap + GridInfoBar.starsWidth + gap + r <= width
            }
            return max(min(need, minLeft), 40) + gap + r <= width
        }
        let options: [(Bool, Bool, Bool)] = [(true, true, stars), (false, true, stars), (false, false, stars), (false, false, false)]
        for (d, t, s) in options where fits(d && dims != nil, t && trailing != nil, s) {
            return GridBarLayout(showDims: d && dims != nil, showTrailing: t && trailing != nil, showStars: s,
                                 rightWidth: right(d, t), leftWidth: left)
        }
        return GridBarLayout(showDims: false, showTrailing: false, showStars: false, rightWidth: right(false, false), leftWidth: left)
    }
}

/// 缩略图大小滑块（spec V5-01）：5 档，拖动时吸附，松手即生效
struct GridSizeSlider: View {
    let size: GridSize
    let onSize: (GridSize) -> Void
    @State private var dragging = false

    private static let track: CGFloat = 92

    var body: some View {
        HStack(spacing: 8) {
            Button { onSize(size.smaller) } label: {
                Image(systemName: "square").font(.system(size: 9, weight: .medium)).frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("缩小缩略图（⌘−）"))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: 3)
                Capsule().fill(Color.white.opacity(0.75)).frame(width: max(3, Self.track * size.fraction), height: 3)
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: (Self.track - 14) * size.fraction)
            }
            .frame(width: Self.track, height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = Double((value.location.x - 7) / (Self.track - 14))
                onSize(GridSize.nearest(fraction: fraction))
            })
            .accessibilityElement()
            .accessibilityLabel(Text("缩略图大小"))
            .accessibilityValue(Text(verbatim: "\(GridSize.allCases.firstIndex(of: size)! + 1) / \(GridSize.allCases.count)"))
            .accessibilityAdjustableAction { direction in
                onSize(direction == .increment ? size.larger : size.smaller)
            }
            Button { onSize(size.larger) } label: {
                Image(systemName: "square").font(.system(size: 12.5, weight: .medium)).frame(width: 16, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("放大缩略图（⌘+）"))
        }
        .foregroundStyle(Theme.text2)
        .animation(.easeOut(duration: 0.12), value: size)
    }
}

/// 图标视图里多选、没有选中时的信息面板（spec V10-04、V10-05）：只有标题和两三行汇总
struct GridSummaryPanel: View {
    let title: String
    let lines: [String]
    let totalSize: String
    let onClose: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("关闭信息面板（I）"))
                .accessibilityLabel(Text("关闭"))
            }
            HStack {
                Text("总大小").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer(minLength: 12)
                Text(verbatim: totalSize).font(Theme.mono(12, .regular)).foregroundStyle(.white)
            }
            Button(action: onReveal) { Label("在访达中显示", systemImage: "folder") }
                .buttonStyle(PanelButtonStyle())
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(width: InfoPanel.width)
        .thickGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
