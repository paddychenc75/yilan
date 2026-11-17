import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 没有打开任何文件时（设计稿 05 · 首次启动 · 欢迎）：图标、打开按钮、最近打开、设为默认
struct WelcomeCard: View {
    let recents: [RecentFolder]
    let onOpen: () -> Void
    let onOpenRecent: (RecentFolder) -> Void
    let onRemoveRecent: (RecentFolder) -> Void

    @State private var showsShortcuts = false
    @State private var isDefaultViewer = DefaultViewer.isDefault

    var body: some View {
        VStack(spacing: 10) {
            WelcomeIcon(size: 88)
            Text("欢迎使用一览")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 10)
            Text("打开一张图片或一个文件夹，就能看完整个文件夹。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    Label("打开…", systemImage: "folder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button { showsShortcuts.toggle() } label: {
                    Label("快捷键", systemImage: "keyboard")
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                .popover(isPresented: $showsShortcuts, arrowEdge: .bottom) { ShortcutList() }
            }
            .padding(.top, 14)
            .padding(.bottom, 8)

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近打开")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(EdgeInsets(top: 4, leading: 9, bottom: 2, trailing: 9))
                    ForEach(recents) { folder in
                        RecentRow(folder: folder) { onOpenRecent(folder) }
                            .contextMenu {
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                                Button("从列表中移除") { onRemoveRecent(folder) }
                            }
                    }
                }
                .padding(.top, 8)
            }

            // 设计稿底部一行：已经是默认时按钮变成灰色的“已是默认”
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                .padding(.top, 10).padding(.bottom, 4)
            HStack(spacing: 10) {
                Text(isDefaultViewer ? "一览已是图片和视频的默认打开方式" : "把一览设为图片和视频的默认打开方式？")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DefaultViewerButton(isDefault: $isDefaultViewer)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 34, bottom: 22, trailing: 34))
        .frame(width: 520)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// 最近打开的一行（高 46，缩略图 40 × 30）
struct RecentRow: View {
    let folder: RecentFolder
    let action: () -> Void
    @State private var hovering = false
    @State private var cover: CGImage?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08))
                    if let cover {
                        Image(decorative: cover, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.text3)
                    }
                }
                .frame(width: 40, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Text(folder.displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer(minLength: 24)
                Text("\(folder.itemCount) 个文件")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(folder.displayPath)
        .task(id: folder.coverPath) { cover = await Self.loadCover(folder) }
    }

    /// 封面：上次停留的文件的缩略图（直接用缩略图缓存）
    private static func loadCover(_ folder: RecentFolder) async -> CGImage? {
        guard let path = folder.coverPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let format = SupportedFormats.format(forExtension: url.pathExtension),
              let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let item = MediaItem(url: url, format: format, fileSize: Int64(v.fileSize ?? 0),
                             modificationDate: v.contentModificationDate ?? .distantPast)
        return await ThumbnailStore.shared.thumbnail(for: item)?.image
    }
}

/// 快捷键一览（欢迎界面“快捷键”按钮）
struct ShortcutList: View {
    /// 左边按键（符号不翻译，只有“空格”要翻译），右边说明
    private let rows: [(String, LocalizedStringResource)] = [
        ("← → ↑ ↓", "上一个 / 下一个"),
        ("Home / End", "第一个 / 最后一个"),
        ("⌘1 ⌘2 ⌘3", "全部 / 只看图片 / 只看视频"),
        ("1–5 / 0", "设置星级 / 清除星级"),
        ("⌘9 / ⌘0", "适应窗口 / 实际大小"),
        ("Z", "适应窗口 ↔ 实际大小（切换）"),
        ("⌘+ ⌘−", "放大 / 缩小"),
        ("T", "显示或隐藏缩略图栏"),
        ("I", "显示或隐藏信息面板"),
        ("F / Esc", "进入 / 退出全屏"),
        ("R / ⇧R", "向右 / 向左旋转"),
        (String(localized: "空格", comment: "快捷键列表里的空格键"), "视频：播放 / 暂停"),
        ("J / L", "视频：快退 / 快进 5 秒"),
        ("M", "视频：静音"),
        ("⌫", "移到废纸篓"),
        ("⌘Z", "撤销上一次评星 / 删除"),
        ("⌘O", "打开…"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key).font(Theme.mono(12)).foregroundStyle(.white)
                    Text(action).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                }
            }
        }
        .padding(16)
    }
}

/// 设计稿里的 App 图标（由设计稿 SVG 渲染的 PNG）
struct WelcomeIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = NSImage(named: "WelcomeIcon") {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            StackedPhotosIcon()
        }
    }
}

/// 拖入窗口时的遮罩（设计稿 .drop：距窗口 10，圆角 20，2pt 白色虚线，品牌深青绿半透明模糊底）
struct DropOverlay: View {
    let summary: DropSummary

    var body: some View {
        ZStack {
            // 框外 10pt 那一圈也压暗，不露出亮的环境光（品牌深青绿，暗度同原来）
            Theme.Brand.tealNight.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: summary.acceptable ? "folder" : "nosign")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .regularGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text(summary.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                Text(summary.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 系统材质的模糊半径调不了：模糊 + 设计稿的品牌深青绿 62% + 一层黑，接近设计稿的暗度
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Theme.Brand.tealNight.opacity(0.62)
                    Color.black.opacity(0.25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            .padding(10)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// 拖放：进入窗口时读出拖的是什么，显示遮罩；松开后打开
struct FileDropDelegate: DropDelegate {
    @Binding var summary: DropSummary?
    let onOpen: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { summary = .pending }
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return }
        let binding = $summary
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let described = DropSummary.describe(url)   // 在后台线程扫描
            Task { @MainActor in
                // 已经拖出去了就不再显示
                if binding.wrappedValue != nil { binding.wrappedValue = described }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: summary?.acceptable == false ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) { summary = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let accepted = summary?.acceptable != false
        withAnimation(.easeOut(duration: 0.15)) { summary = nil }
        guard accepted, let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in onOpen(url) }
        }
        return true
    }
}

/// 设为默认打开方式（设计稿欢迎界面底部、设置里的“设为默认”）
@MainActor
enum DefaultViewer {
    static let types: [UTType] = [.jpeg, .png, .heic, .heif, .webP, .gif, .tiff, .bmp, .svg, .rawImage,
                                  .mpeg4Movie, .quickTimeMovie]

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .jpeg) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefault() async {
        let app = Bundle.main.bundleURL
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            } catch {
                Log.app.error("设为默认失败 \(type.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// “设为默认”按钮：已经是默认时显示灰色的“已是默认”，不能点
struct DefaultViewerButton: View {
    @Binding var isDefault: Bool

    var body: some View {
        Button(isDefault ? "已是默认" : "设为默认") {
            Task {
                await DefaultViewer.makeDefault()
                isDefault = DefaultViewer.isDefault
            }
        }
        .buttonStyle(AccentButtonStyle(height: 26, fontSize: 12, enabled: !isDefault))
        .disabled(isDefault)
    }
}

/// 蓝色强调按钮（设计稿 .btn.blue）
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var fontSize: CGFloat = 13
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(enabled ? .white : Theme.text2)
            .padding(.horizontal, height < 30 ? 12 : 16)
            .frame(height: height)
            .background(Capsule().fill(enabled ? Theme.accent : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}
