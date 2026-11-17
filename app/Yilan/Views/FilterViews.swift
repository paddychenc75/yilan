import SwiftUI

/// 漏斗图标（设计稿 funnel：M4 5.5h16l-6.2 7.2v5.3l-3.6 1.8v-7.1z）
struct FunnelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(4, 5.5), (20, 5.5), (13.8, 12.7), (13.8, 18), (10.2, 19.8), (10.2, 12.7)]
        var p = Path()
        p.addLines(pts.map { CGPoint(x: rect.minX + $0.0 / 24 * rect.width, y: rect.minY + $0.1 / 24 * rect.height) })
        p.closeSubpath()
        return p
    }
}

struct FunnelIcon: View {
    var size: CGFloat = 15
    var body: some View {
        FunnelShape()
            .stroke(style: StrokeStyle(lineWidth: 1.8 / 24 * size, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// 顶部栏的筛选按钮（设计稿 .rb，spec R5-02 ~ R5-04）：
/// 没筛选时普通玻璃；有筛选时强调色并写出摘要；窄了缩成“筛选 · 2”，再缩成漏斗 + 数字徽标
struct FilterButton: View {
    let filter: BrowseFilter
    let mode: FilterButtonMode
    let open: Bool
    let action: () -> Void

    var body: some View {
        let active = filter.isActive
        Button(action: action) {
            HStack(spacing: 7) {
                FunnelIcon()
                if mode == .icon {
                    if active {
                        Text(verbatim: "\(filter.activeKinds)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(.white))
                    }
                } else {
                    Text("筛选")
                    if active {
                        Text(verbatim: "·").opacity(0.6)
                        Text(verbatim: mode == .full ? filter.summaryParts.joined(separator: " · ") : "\(filter.activeKinds)")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(active || open ? Color.white : Color.white.opacity(0.86))
            .padding(.leading, 11)
            .padding(.trailing, mode == .icon ? 11 : 12)
            .frame(height: 36)
            .background(Capsule().fill(active ? Theme.accent : Color.white.opacity(open ? 0.24 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .regularGlass(Capsule())
        .fixedSize()
        .help(Text("筛选（⌘F）"))
        .accessibilityLabel(Text("筛选"))
        .accessibilityValue(Text(verbatim: filter.summaryParts.joined(separator: ", ")))
    }
}

/// 筛选面板（设计稿 .fpop）：宽 336，圆角 22，内边距 14 / 16 / 12，厚玻璃；分区可以继续往下加
struct FilterPanel: View {
    static let width: CGFloat = 336

    let filter: BrowseFilter
    let type: MediaFilter
    let facets: FilterFacets
    /// 星级还在后台读取（spec R4-08）
    let loadingRatings: Bool
    let onRating: (RatingCriterion.Mode) -> Void
    let onToggleFormat: (FormatGroup) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ratingSection
                    if !facets.presentFormats.isEmpty { formatSection }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .frame(width: Self.width)
        .thickGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 头部：筛选 / 符合 N 个 共 M 个

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("筛选").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if loadingRatings {
                Text("正在读取星级…").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Text("符合 \(Text(verbatim: Formatting.count(facets.resultCount)).font(Theme.mono(13, .semibold)).foregroundColor(.white)) 个",
                 comment: "筛选面板头部：结果数；%@ 是数字")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text2)
            Text("共 \(facets.total) 个", comment: "筛选面板头部：文件夹里一共几个文件")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
    }

    // MARK: 星级

    private var ratingValue: Int {
        if case .atLeast(let n) = filter.rating.mode { return n }
        return 0
    }

    private var ratingSection: some View {
        let videoOnly = type == .videos
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("星级"), value: videoOnly ? Text("视频不支持星级") : {
                switch filter.rating.mode {
                case .any: Text("不限")
                case .unrated: Text("未评星")
                case .atLeast(let n): Text("不低于 \(n) 星", comment: "筛选面板星级分区的当前值")
                }
            }())
            HStack(spacing: 8) {
                FilterChip(title: Text("不限"), count: nil, selected: filter.rating.mode == .any, enabled: true) { onRating(.any) }
                StarRow(rating: ratingValue, size: 21, spacing: 4) { value in
                    onRating(value == 0 ? .any : .atLeast(value))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                FilterChip(title: Text("未评星"), count: Formatting.count(facets.unratedCount),
                           selected: filter.rating.mode == .unrated, enabled: true) {
                    onRating(filter.rating.mode == .unrated ? .any : .unrated)
                }
            }
            // 类型是“视频”时整个星级分区不可用（视频不评星）
            .disabled(videoOnly)
            .opacity(videoOnly ? 0.35 : 1)
        }
    }

    // MARK: 格式

    private var formatSection: some View {
        let images = facets.presentFormats.filter { $0.kind == .image }
        let videos = facets.presentFormats.filter { $0.kind == .video }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("格式"), value: filter.format.isActive
                ? Text("已选 \(filter.format.selected.count) 种", comment: "筛选面板格式分区的当前值") : Text("不限"))
            VStack(alignment: .leading, spacing: 6) {
                if !images.isEmpty { chips(images) }
                if !videos.isEmpty { chips(videos) }
            }
        }
    }

    private func chips(_ groups: [FormatGroup]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(groups) { group in
                // 类型切换排除了这一类：变灰、数量写“—”（spec R5b-06）
                let excluded = (type == .images && group.kind == .video) || (type == .videos && group.kind == .image)
                let count = facets.formatCounts[group] ?? 0
                let selected = filter.format.selected.contains(group)
                FilterChip(title: Text(verbatim: group.title), count: excluded ? "—" : Formatting.count(count),
                           selected: selected, enabled: !excluded && (count > 0 || selected)) { onToggleFormat(group) }
            }
        }
    }

    private func sectionTitle(_ title: Text, value: Text) -> some View {
        HStack {
            title.font(.system(size: 10.5, weight: .semibold)).tracking(0.63).foregroundStyle(Theme.text3)
            Spacer()
            value.font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text2)
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            HStack {
                Button(action: onClear) { Text("清除筛选").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(filter.isActive ? Theme.link : Theme.text3)
                    .disabled(!filter.isActive)
                Spacer()
                Text("即时生效 · ⌘F 开关 · Esc 关闭").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
    }
}

/// 面板里的小胶囊（设计稿 .fchip）：高 26，左右 10，白 9% 底；选中强调色；不可用 35%
struct FilterChip: View {
    let title: Text
    let count: String?
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                title.font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                if let count {
                    Text(verbatim: count).font(Theme.mono(10.5)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(selected ? Theme.accent : Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .fixedSize()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 结果为空（设计稿“没有符合条件的文件”，spec F-05）
struct EmptyFilterResultCard: View {
    let condition: String
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            FunnelIcon(size: 26)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.1)))
                .padding(.bottom, 2)
            Text("没有符合条件的文件")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 6)
            (Text("当前筛选：\(condition)", comment: "空结果卡片；%@ 是类型和条件，例如“视频 · ≥5 星”") + Text(verbatim: "\n")
             + Text("放宽条件，或清除筛选后查看全部文件。"))
                .font(.system(size: 13))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text2)
            Button("清除筛选", action: onClear)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 30, leading: 32, bottom: 26, trailing: 32))
        .frame(width: 420)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
