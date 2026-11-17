import AppKit
import SwiftUI

/// 设置窗口（设计稿 05 · 设置 · 浏览，820 × 700）：左边悬浮侧边栏，右边分组列表。
/// 只放真正起作用的选项；还没做的页面显示一句说明。
/// 英文比中文长：控件不改尺寸，放不下时用更短的英文说法
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, browsing, video, formats, cache, shortcuts
        var id: String { rawValue }
        var title: LocalizedStringResource {
            switch self {
            case .general: "通用"
            case .browsing: "浏览"
            case .video: "视频"
            case .formats: "文件格式"
            case .cache: "缓存与性能"
            case .shortcuts: "快捷键"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .browsing: "photo"
            case .video: "video.fill"
            case .formats: "doc.fill"
            case .cache: "clock.fill"
            case .shortcuts: "keyboard.fill"
            }
        }
        /// 设计稿里图标底色
        var color: Color {
            switch self {
            case .general: Color(hex: 0x8E8E93)
            case .browsing: Color(hex: 0x0A84FF)
            case .video: Color(hex: 0xFF9F0A)
            case .formats: Color(hex: 0x30D158)
            case .cache: Color(hex: 0xBF5AF2)
            case .shortcuts: Color(hex: 0x636366)
            }
        }
    }

    static let size = CGSize(width: 820, height: 700)

    @Bindable var settings: AppSettings
    @Bindable var language: LanguageSettings
    // 截图时可以用 `--shot-settings=general` 直接打开某一页
    @State private var nav = SettingsNavigation.shared
    private var pane: Pane {
        get { nav.pane }
        nonmutating set { nav.pane = newValue }
    }
    @State private var search = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .padding(.leading, 236)
            sidebar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(hex: 0x1E1E21))
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    // MARK: - 侧边栏（距窗口 8，宽 212，圆角 14）

    private var visiblePanes: [Pane] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? Pane.allCases : Pane.allCases.filter { String(localized: $0.title).localizedCaseInsensitiveContains(q) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 12).padding(.bottom, 18)   // 红绿灯（由窗口摆放到这里）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField("搜索", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
            .padding(.bottom, 10)
            ForEach(visiblePanes) { item in
                Button { pane = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.color))
                        Text(item.title).font(.system(size: 13)).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(pane == item ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.045)], startPoint: .top, endPoint: .bottom))
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .padding(8)
    }

    // MARK: - 右侧（距左 236，内边距 22 / 28，分组间距 16）

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(pane.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 2)
                switch pane {
                case .general: generalPane
                case .browsing: browsingPane
                case .video: videoPane
                case .formats: formatsPane
                case .shortcuts: ShortcutsPane()
                case .cache: placeholder
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @State private var updater = UpdateChecker.shared

    /// 通用（设计稿 05 · 设置 · 通用）：界面语言、更新检查（spec U7）
    @ViewBuilder
    private var generalPane: some View {
        languageGroup
        if UpdateChecker.isAvailable {
            SettingsGroup {
                SettingsRow("自动检查更新", note: "一览只在检查更新时联网，不会上传任何信息。") {
                    SettingsSwitch(isOn: Binding(get: { settings.autoCheckUpdates }, set: {
                        settings.autoCheckUpdates = $0
                        updater.autoCheckChanged()
                    }))
                }
                HStack(spacing: 12) {
                    Text("上次检查：\(UpdateDateText.lastChecked(updater.lastCheck))", comment: "设置：上次检查更新的时间")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 设计稿 .btn.g：高 26，字 12 的玻璃小按钮
                    Button { Task { await updater.checkNow() } } label: {
                        Text("立即检查").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(updater.checking)
                    .opacity(updater.checking ? 0.5 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 40)
            }
        }
    }

    private var languageGroup: some View {
        SettingsGroup {
            SettingsRow("语言", note: "跟随系统时：系统语言是中文或英文就用它，否则用英文") {
                SettingsMenu(selection: $language.choice,
                             options: AppLanguage.allCases.map { ($0, $0.title) })
            }
            if language.needsRelaunch {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                    Text("重新打开一览后生效")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("立即重新打开") { LanguageSettings.relaunch() }
                        .buttonStyle(AccentButtonStyle(height: 26, fontSize: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 40)
            }
        }
    }

    @ViewBuilder
    private var browsingPane: some View {
        SettingsGroup {
            SettingsRow("启动时") {
                SettingsMenu(selection: $settings.reopenLastFolder,
                             options: [(true, "打开上次的文件夹"), (false, "显示欢迎界面")])
            }
            SettingsRow("默认显示") {
                SettingsMenu(selection: $settings.startFilter,
                             options: AppSettings.StartFilter.allCases.map { ($0, $0.title) })
            }
            // 目前只有一种排序和一种双击行为：如实显示，不给假的选项
            SettingsRow("排序方式", note: "数字按大小排序：img2 在 img10 前面") {
                SettingsMenu(selection: .constant(0), options: [(0, "文件名")])
            }
            SettingsRow("到达最后一个时") {
                SettingsSegmented(selection: $settings.wrapAround, options: [(false, "停止"), (true, "循环到第一个")])
            }
        }
        SettingsGroup {
            SettingsRow("鼠标滚轮", note: "按住 ⌃ 时执行另一种操作") {
                SettingsSegmented(selection: $settings.scrollZooms, options: [(false, "切换图片"), (true, "缩放")])
            }
            SettingsRow("双击图片") {
                SettingsMenu(selection: .constant(0), options: [(0, "在适应窗口和 100% 之间切换")])
            }
        }
        SettingsGroup {
            SettingsRow("评星时在画面上闪现星级", note: "默认打开。按 0–5 评星后，画面底部居中闪现约 1 秒五星；关掉后画面上不出现任何东西，反馈只在缩略图栏信息行里") {
                SettingsSwitch(isOn: $settings.flashRatingOnStage)
            }
            SettingsRow("打星后自动跳到下一张", note: "默认关闭。打开后，按 1–5 或 0 评星会立刻显示下一张") {
                SettingsSwitch(isOn: $settings.autoAdvanceAfterRating)
            }
        }
        ratingStorageGroup
        SettingsGroup {
            SettingsRow("自动隐藏控件", note: "鼠标静止一段时间后，只显示图片") {
                SettingsSwitch(isOn: $settings.autoHideControls)
            }
            SettingsRow("隐藏延迟") {
                HStack(spacing: 10) {
                    // 不用 step（会画刻度），在这里取整到整秒
                    Slider(value: Binding(get: { settings.hideDelay },
                                          set: { settings.hideDelay = $0.rounded() }),
                           in: AppSettings.hideDelayRange)
                        .controlSize(.small)
                        .frame(width: 150)
                    Text("\(Int(settings.hideDelay)) 秒", comment: "隐藏延迟的秒数")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!settings.autoHideControls)
                .opacity(settings.autoHideControls ? 1 : 0.45)
            }
            SettingsRow("环境光背景", note: "用当前图片的颜色铺满窗口背景") {
                SettingsSwitch(isOn: $settings.ambientBackground)
            }
        }
        SettingsGroup {
            SettingsRow("删除前确认", note: "关闭后按 ⌫ 直接移到废纸篓，可以按 ⌘Z 撤销") {
                SettingsSwitch(isOn: $settings.confirmBeforeDelete)
            }
        }
        defaultViewerGroup
    }

    /// 星级保存到哪里（spec SE-01、S-02）：两个单选 + 一行说明
    private var ratingStorageGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("星级保存到哪里")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 4)
            SettingsGroup {
                SettingsRadioRow(title: "写入文件内部（推荐，其他软件可读）",
                                 note: "JPEG、PNG、HEIC 等直接写进文件的元数据，其他软件（如 Lightroom）也能读到",
                                 selected: settings.ratingStorage == .embedded) { settings.ratingStorage = .embedded }
                SettingsRadioRow(title: "一律使用旁边的 .xmp 小文件",
                                 note: "不改动图片本身；换到别的软件时要连同 .xmp 一起带走",
                                 selected: settings.ratingStorage == .sidecar) { settings.ratingStorage = .sidecar }
            }
            Text("RAW（ARW、CR3、NEF 等）不能写入文件内部，始终使用旁边的 .xmp。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 4)
        }
    }

    private var defaultViewerGroup: some View {
        VStack(spacing: 0) {
            SettingsRow("默认打开方式", note: "让一览打开下列格式的文件") {
                DefaultViewerButton(isDefault: $isDefaultViewer)
            }
            FormatChips()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .settingsGroupBackground()
    }

    @State private var isDefaultViewer = DefaultViewer.isDefault

    private var videoPane: some View {
        SettingsGroup {
            SettingsRow("自动播放", note: "切到视频时直接开始播放；关闭时停在第一帧，按空格播放") {
                SettingsSwitch(isOn: $settings.autoplayVideo)
            }
            SettingsRow("播完后循环", note: "播到结尾后从头再播；也可以点控制条上的循环按钮") {
                SettingsSwitch(isOn: $settings.loopVideo)
            }
        }
    }

    private var formatsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("一览能打开的格式", note: "RAW 使用系统自带的解码，支持的相机型号以 macOS 为准") { EmptyView() }
            FormatChips().padding(.horizontal, 14).padding(.vertical, 10)
        }
        .settingsGroupBackground()
    }

    private var placeholder: some View {
        Text("这一页的选项会在后续版本加入。")
            .font(.system(size: 13))
            .foregroundStyle(Theme.text3)
    }
}

/// 设计稿 .fmts：格式小标签
struct FormatChips: View {
    static let formats = ["JPEG", "PNG", "HEIF", "HEIC", "WebP", "GIF", "SVG", "TIFF", "BMP",
                          "ARW", "CR3", "NEF", "RAF", "DNG", "MP4", "MOV"]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Self.formats, id: \.self) { name in
                Text(name)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 自动换行的横排
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (maxX, y + rowHeight)
    }
}

/// 设计稿 .pop：高 24 的弹出菜单（圆角 7，白 10% 底，上下箭头）
struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, LocalizedStringResource)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    if value == selection {
                        Label { Text(title) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                selectedTitle
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.count < 2)
    }

    private var selectedTitle: Text {
        options.first { $0.0 == selection }.map { Text($0.1) } ?? Text(verbatim: "")
    }
}

/// 设计稿 .sseg：小分段（圆角 7，白 8% 底，选中白 22%）
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, LocalizedStringResource)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background {
                            if value == selection {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.22))
                                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

/// 单选的一行（设计稿 .rd：16 的圆圈，选中时强调色实心 + 白点）
struct SettingsRadioRow: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(selected ? Theme.accent : Color.white.opacity(0.08))
                    .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0 : 0.25), lineWidth: 1))
                    .overlay(Circle().fill(.white).frame(width: 6, height: 6).opacity(selected ? 1 : 0))
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(.white)
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 设置窗口当前显示哪一页（“查看快捷键”等地方可以直接跳到某一页）
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var pane: SettingsView.Pane = ShotHooks.settingsPane.flatMap(SettingsView.Pane.init(rawValue:)) ?? .browsing
}

/// 设计稿 .tg：38 × 22 的开关，打开时蓝色
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? Theme.accent : Color.white.opacity(0.18))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

extension View {
    /// 设计稿 .grp：圆角 12，白 5% 底，白 6% 描边
    func settingsGroupBackground() -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 设置里的一组，行之间有分隔线
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
                    row
                }
            }
        }
        .settingsGroupBackground()
    }
}

/// 一行（设计稿 .row：最小高 40，左边说明 13pt，小字 11.5pt）
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey?
    @ViewBuilder let control: Control

    init(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.white)
                if let note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

/// 设置窗口：用 AppKit 窗口承载，内容一直伸到标题栏下面，红绿灯放进侧边栏里
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    /// 打开设置并切到某一页
    func show(pane: SettingsView.Pane) {
        SettingsNavigation.shared.pane = pane
        show()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.titlebarSeparatorStyle = .none
            w.title = String(localized: "设置", comment: "设置窗口的标题（窗口菜单里显示）")
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x21 / 255, alpha: 1)
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // SwiftUI 视图套一层普通 NSView：窗口大小由这里定，SwiftUI 不会再按“内容区 + 标题栏”把窗口撑高
            let hosting = NSHostingView(rootView: SettingsView(settings: AppSettings.shared, language: LanguageSettings.shared))
            hosting.sizingOptions = []
            let container = NSView(frame: NSRect(origin: .zero, size: SettingsView.size))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            w.contentView = container
            w.delegate = self
            // 内容伸到标题栏下面：整个窗口就是 820 × 700（按内容区创建会多出标题栏的高度）
            w.setFrame(NSRect(origin: .zero, size: SettingsView.size), display: false)
            w.center()
            window = w
        }
        guard let window else { return }
        placeTrafficLights(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 设计稿：红绿灯在侧边栏里，第一个距窗口左 24，中心距顶 28
    private func placeTrafficLights(_ window: NSWindow) {
        WindowStyler.positionTrafficLights(window, left: 24, height: 56)
    }

    func windowDidBecomeKey(_ notification: Notification) { if let window { placeTrafficLights(window) } }
    func windowDidResignKey(_ notification: Notification) { if let window { placeTrafficLights(window) } }
    func windowDidResize(_ notification: Notification) { if let window { placeTrafficLights(window) } }
}
