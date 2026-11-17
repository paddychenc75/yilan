import SwiftUI

/// 底部缩略图栏（设计稿 .dock）：上面一行文件信息，下面横向缩略图
struct ThumbnailDock: View {
    /// 信息行中间的五颗星（spec R2）：当前文件的星级（没读出来时 nil）、能不能评、点击
    var rating: Int? = nil
    var canRate = false
    var onRate: ((Int) -> Void)? = nil
    let items: [MediaItem]
    let current: MediaItem?
    let meta: DockMeta
    let width: CGFloat
    /// 文件夹里刚出现的文件：高亮 2 秒
    var fresh: Set<URL> = []
    /// 星级（左上角角标，spec R3-01）
    var ratings: [URL: Int] = [:]
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            MetaLine(meta: meta, rating: rating, canRate: canRate, onRate: onRate)
            ThumbnailStrip(items: items, current: current, fresh: fresh, ratings: ratings, onSelect: onSelect)
                .frame(height: 62)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
        .frame(width: width)
        .regularGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 缩略图栏上方的一行：左边文件名 + 尺寸，右边 时长 · 大小 · 格式
struct DockMeta: Equatable {
    var name: String
    var dimensions: String?
    var trailing: String
    var failed: Bool
}

struct MetaLine: View {
    let meta: DockMeta
    var rating: Int? = nil
    var canRate = false
    var onRate: ((Int) -> Void)? = nil

    /// 星的整行宽 92，和两边文字至少留 14
    private static let starsWidth: CGFloat = 92
    private static let gap: CGFloat = 14

    /// 各段文字的实际宽度（隐藏测量），决定让位
    @State private var nameWidth: CGFloat = 0
    @State private var dimsWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // 三段：左（名称 + 尺寸）、中（星，永远在、永远居中）、右（时长 · 大小 · 格式）。
            // 不够放时：① 先隐藏尺寸 ② 再隐藏右边 ③ 最后名称截断（设计稿“让位顺序”）
            let side = onRate == nil ? geo.size.width : max(0, (geo.size.width - Self.starsWidth) / 2 - Self.gap)
            let showDims = nameWidth + 8 + dimsWidth <= side
            let showTrailing = trailingWidth <= side && nameWidth <= side
            ZStack {
                HStack(spacing: 0) {
                    left(withDimensions: showDims)
                        .frame(maxWidth: side, alignment: .leading)
                    Spacer(minLength: 0)
                    if showTrailing { trailing.fixedSize() }
                }
                if let onRate {
                    InfoRowStars(rating: rating ?? 0, enabled: canRate, onRate: onRate)
                }
                // 测量用，不显示
                ZStack {
                    nameText.fixedSize().measure { nameWidth = $0 }
                    if let d = meta.dimensions { dimsText(d).fixedSize().measure { dimsWidth = $0 } }
                    trailing.fixedSize().measure { trailingWidth = $0 }
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 4)
        .frame(height: 16)
    }

    private var nameText: some View {
        Text(meta.name)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func dimsText(_ d: String) -> some View {
        Text(d).font(Theme.mono(11, .regular)).foregroundStyle(Theme.text2)
    }

    private func left(withDimensions: Bool) -> some View {
        HStack(spacing: 8) {
            nameText
                .truncationMode(.middle)
                .frame(minWidth: 44, alignment: .leading)   // 至少保留约 6 个字符
                .layoutPriority(1)
            if meta.failed {
                Text("无法读取").font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize()
            } else if withDimensions, let d = meta.dimensions {
                dimsText(d).fixedSize()
            }
        }
    }

    private var trailing: some View {
        Text(meta.trailing)
            .font(Theme.mono(11, .regular))
            .foregroundStyle(Theme.text2)
            .lineLimit(1)
    }
}

/// 横向缩略图：LazyHStack 只渲染可见的格子，上千张也流畅；选中项自动滚到中间
struct ThumbnailStrip: View {
    let items: [MediaItem]
    let current: MediaItem?
    let fresh: Set<URL>
    var ratings: [URL: Int] = [:]
    let onSelect: (Int) -> Void

    @State private var fadeLeading = false
    @State private var fadeTrailing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            // 被两端 28pt 渐隐区遮住的格子不画星级角标（spec R3-03）
                            ThumbnailCell(item: item, selected: item == current, fresh: fresh.contains(item.url),
                                          rating: ratings[item.url] ?? 0,
                                          badgeZone: (fadeLeading ? 28 : 0)...(geo.size.width - (fadeTrailing ? 28 : 0)))
                                .id(item.id)
                                .onTapGesture { onSelect(index) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 62)
                    // 数量少时整体居中
                    .frame(minWidth: geo.size.width)
                }
                .scrollIndicators(.never)
                .coordinateSpace(name: ThumbnailStrip.space)
                .onScrollGeometryChange(for: [Bool].self) { g in
                    [g.contentOffset.x > 1, g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1]
                } action: { _, edges in
                    fadeLeading = edges[0]
                    fadeTrailing = edges[1]
                }
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: current) { scroll(proxy, animated: true) }
                .onChange(of: items) { scroll(proxy, animated: false) }
            }
            .mask(edgeMask)
        }
    }

    static let space = "thumbnailStrip"

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = current?.id else { return }
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// 两端还有更多缩略图时渐隐 28pt（设计稿 .strip.fl / .fr）
    private var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [fadeLeading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
            Color.black
            LinearGradient(colors: [.black, fadeTrailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
        }
    }
}

/// 一个缩略图格子（设计稿 .th）：76 × 52，圆角 10；选中放大 1.12 + 2pt 白圈
struct ThumbnailCell: View {
    let item: MediaItem
    let selected: Bool
    var fresh = false
    var rating = 0
    /// 格子完整露出时才画星级角标：允许的横向范围（缩略图栏坐标）
    var badgeZone: ClosedRange<CGFloat> = -CGFloat.infinity...CGFloat.infinity

    @State private var thumb: Thumbnail?
    @State private var hovering = false
    @State private var fullyVisible = true

    init(item: MediaItem, selected: Bool, fresh: Bool = false, rating: Int = 0,
         badgeZone: ClosedRange<CGFloat> = -CGFloat.infinity...CGFloat.infinity) {
        self.item = item
        self.selected = selected
        self.fresh = fresh
        self.rating = rating
        self.badgeZone = badgeZone
        // 内存里有就同步拿到，避免闪一下占位格
        _thumb = State(initialValue: ThumbnailStore.shared.cached(item))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            badge.padding(4)
            if fresh && !selected {
                // 设计稿 .th.new：左下角“● 新”角标
                Badge {
                    HStack(spacing: 3) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        Text("新", comment: "缩略图角标：刚出现在文件夹里的文件")
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity)
            }
        }
        .frame(width: 76, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
                    .padding(-2)
            } else if fresh {
                // 设计稿：1.5pt 白 75% 圈 + 18pt 白 28% 光晕
                RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.75), lineWidth: 1.5)
                    .padding(-1.5)
                    .shadow(color: .white.opacity(0.28), radius: 9)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 8, y: 6)
        .opacity(selected || fresh ? 1 : (hovering ? 0.95 : 0.66))
        // 星级角标画在压暗之后：不跟着格子变暗（设计稿“缩略图角标”）
        .overlay(alignment: .topLeading) {
            if rating > 0, fullyVisible, thumb?.failed != true {
                RatingBadge(rating: rating).padding(4)
            }
        }
        .scaleEffect(selected ? 1.12 : 1)
        .onGeometryChange(for: Bool.self) { proxy in
            let f = proxy.frame(in: .named(ThumbnailStrip.space))
            return f.minX >= badgeZone.lowerBound - 0.5 && f.maxX <= badgeZone.upperBound + 0.5
        } action: { fullyVisible = $0 }
        .zIndex(selected ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: item.id) {
            if thumb == nil || thumb?.image == nil && ThumbnailStore.shared.cached(item) == nil {
                if let t = await ThumbnailStore.shared.thumbnail(for: item) { thumb = t }
            }
        }
        .help(item.name)
        .accessibilityElement()
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var content: some View {
        if let thumb {
            if let image = thumb.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 76, height: 52)
                    .clipped()
            } else {
                // 无法读取（设计稿 .th.err）
                ZStack {
                    Color(red: 42 / 255, green: 43 / 255, blue: 48 / 255)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.yellow)
                }
            }
        } else {
            // 生成中（设计稿 .th.load）
            LinearGradient(
                stops: [
                    .init(color: Color(red: 37 / 255, green: 38 / 255, blue: 43 / 255), location: 0.3),
                    .init(color: Color(red: 52 / 255, green: 53 / 255, blue: 59 / 255), location: 0.5),
                    .init(color: Color(red: 37 / 255, green: 38 / 255, blue: 43 / 255), location: 0.7),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder private var badge: some View {
        switch item.format {
        case .video:
            if let d = thumb?.duration {
                Badge {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill").font(.system(size: 6.5))
                        Text(Formatting.duration(d))
                    }
                }
            }
        case .raw:
            if thumb?.image != nil { Badge { Text(verbatim: "RAW") } }
        case .gif:
            if thumb?.image != nil { Badge { Text(verbatim: "GIF") } }
        default:
            EmptyView()
        }
    }
}

/// 缩略图角标（设计稿 .bdg）
struct Badge<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.58)))
    }
}
