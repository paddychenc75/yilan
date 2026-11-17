import SwiftUI

/// 信息面板（设计稿 08 · 信息面板 .ip）：宽 300，圆角 22，内边距 16 / 16 / 14，厚玻璃。
/// 高度随内容，最多到距窗口底边 16；放不下时中间部分滚动。
/// 任何窗口宽度下都浮在图片上，不挤占图片区（布局规则见 StageLayout）
struct InfoPanel: View {
    nonisolated static let width: CGFloat = 300
    /// 距窗口右边、顶边
    nonisolated static let trailing: CGFloat = 16
    nonisolated static let top: CGFloat = 64

    let item: MediaItem?
    let content: InfoContent?
    let maxHeight: CGFloat
    let onClose: () -> Void
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onCopyCoordinates: () -> Void

    /// 滚动区下面还有没显示的内容
    @State private var hasMoreBelow = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(scrolls: false)
            panel(scrolls: true)
        }
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .thickGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func panel(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if scrolls {
                // 内容放不下时：底部渐隐 + 打开时闪一下滚动条，告诉人下面还有内容（设计稿 .ipb 的做法）。
                // 以前这里没有任何提示，下面的“位置”组被生硬地截掉，看起来像是空的
                ScrollView(.vertical) { sections.padding(.trailing, 2) }
                    .scrollIndicators(.automatic)
                    .scrollIndicatorsFlash(onAppear: true)
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 1
                    } action: { _, more in
                        hasMoreBelow = more
                    }
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, hasMoreBelow ? .clear : .black],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                        }
                    }
                    .frame(maxHeight: .infinity)
            } else {
                sections
            }
            footer
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(maxHeight: scrolls ? maxHeight : nil, alignment: .top)
    }

    // MARK: - 顶部：缩略图、文件名、类型，关闭按钮

    private var header: some View {
        HStack(spacing: 10) {
            InfoThumbnail(item: item)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: content?.title ?? item?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 17)
                Text(verbatim: content?.subtitle ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
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
    }

    // MARK: - 分组

    @ViewBuilder
    private var sections: some View {
        if let content {
            VStack(alignment: .leading, spacing: 14) {
                InfoSectionView(title: "文件") { InfoRows(rows: content.file) }
                if let video = content.video {
                    Divider14()
                    InfoSectionView(title: "视频") { InfoRows(rows: video) }
                }
                if content.hasCapture {
                    Divider14()
                    InfoSectionView(title: "拍摄") {
                        if !content.captureTop.isEmpty { InfoRows(rows: content.captureTop) }
                        if !content.tiles.isEmpty { ExposureTiles(tiles: content.tiles).padding(.vertical, 2) }
                        if !content.captureBottom.isEmpty { InfoRows(rows: content.captureBottom) }
                    }
                } else if content.isComplete && content.video == nil {
                    // 视频没有拍摄信息时不显示这一组；图片显示一行说明
                    Divider14()
                    InfoSectionView(title: "拍摄") { NoCaptureNote() }
                }
                if let location = content.location {
                    Divider14()
                    InfoSectionView(title: "位置", accessory: {
                        Button(action: onCopyCoordinates) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.text2)
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("拷贝坐标"))
                    }) { InfoRows(rows: location) }
                }
            }
        }
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onReveal) {
                Label("在访达中显示", systemImage: "arrow.up.forward.square")
            }
            Button(action: onCopy) {
                Label("拷贝信息", systemImage: "doc.on.doc")
            }
            .disabled(content == nil)
        }
        .buttonStyle(PanelButtonStyle())
    }
}

/// 分组标题（设计稿 .ip h5：10.5pt 粗体，字距 0.06em，白 44%）+ 内容，间距 8
private struct InfoSectionView<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.63)
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 13)
            content
        }
    }
}

/// 一组“名称 — 数值”（设计稿 .kv：行距 7，名称白 68%，数值 500 字重，数字用 SF Mono 11.5）
private struct InfoRows: View {
    let rows: [InfoRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(verbatim: row.value)
                        .font(row.mono ? Theme.mono(11.5) : .system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: row.value))
                }
                .frame(minHeight: 17)   // 设计稿行高 1.4（12pt → 17）
            }
        }
    }
}

/// 光圈 / 快门 / ISO / 焦距四个小方块（设计稿 .exif：间距 6，圆角 9，白 8% 底）
private struct ExposureTiles: View {
    let tiles: [InfoTile]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tiles) { tile in
                VStack(spacing: 2) {
                    Text(verbatim: tile.value)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: tile.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            }
        }
    }
}

/// 没有 EXIF 时“拍摄”组里的一行说明（设计稿 .ip .empty）
private struct NoCaptureNote: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .opacity(0.8)
            VStack(alignment: .leading, spacing: 1) {
                Text("没有拍摄信息")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text2)
                Text("截图和导出的图片通常不带相机数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private struct Divider14: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }
}

/// 面板顶部 44 × 44 的缩略图（圆角 9）
private struct InfoThumbnail: View {
    let item: MediaItem?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: item?.url) {
            guard let item else { image = nil; return }
            image = ThumbnailStore.shared.cached(item)?.image
            if image == nil { image = await ThumbnailStore.shared.thumbnail(for: item)?.image }
        }
    }
}

/// 面板底部的小玻璃按钮（设计稿 .ip .foot .btn：高 28，12pt，平分宽度）
struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PanelButtonLabelStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

private struct PanelButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .medium))
            configuration.title
        }
    }
}
