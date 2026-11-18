import SwiftUI

/// 顶部中间的类型切换（设计稿 .seg）：高 36，内边距 3，选中项高亮像液体一样滑动
struct FilterControl: View {
    let selection: MediaFilter
    let counts: [MediaFilter: Int]
    let compact: Bool
    let onSelect: (MediaFilter) -> Void

    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MediaFilter.allCases) { filter in
                segment(filter)
            }
        }
        .padding(3)
        .frame(height: 36)
        .regularGlass(Capsule())
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.8), value: selection)
    }

    private func segment(_ filter: MediaFilter) -> some View {
        let count = counts[filter] ?? 0
        let selected = filter == selection
        return Button {
            onSelect(filter)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.85)
                if !compact {
                    Text(filter.title)
                        .font(.system(size: 12.5, weight: .medium))
                }
                Text(verbatim: Formatting.count(count))
                    .font(Theme.mono(11))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Theme.text3)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.82))
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.selectedFill)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.32 : 1)
        .help(Text(filter.help))
        .accessibilityLabel(filter.accessibilityLabel(count: count))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 序号胶囊：“9 / 20”
struct CounterPill: View {
    let index: Int
    let total: Int
    /// 缩略图栏隐藏或全屏时序号后面带星级“· ★4”（spec R3-05）；nil 或 0 不显示
    var rating: Int? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "\(Formatting.count(index + 1)) / \(Formatting.count(total))")
            if let rating, rating > 0 {
                Text(verbatim: " · ").foregroundStyle(Theme.text3)
                StarShape().fill(Theme.Brand.sun).frame(width: 11, height: 11).padding(.trailing, 3)
                Text(verbatim: "\(rating)")
            }
        }
            .font(Theme.mono(12))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)   // 和分段控件、工具组同高（36），顶部一排对齐
            .regularGlass(Capsule())
            .accessibilityLabel("第 \(index + 1) 个，共 \(total) 个")
    }
}

/// 右上角工具组（设计稿 .tools / .ib）：旋转、信息、更多
struct ToolGroup: View {
    let enabled: Bool
    let infoSelected: Bool
    /// 浏览时转过（「保存旋转」胶囊出现时旋转按钮高亮，设计稿 edit 09）
    var rotateSelected = false
    /// 视频、GIF、SVG、出错：编辑按钮置灰但仍能悬停看提示（spec ED-02）
    var editUnsupported = true
    var onEdit: () -> Void = {}
    let onRotate: () -> Void
    let onInfo: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onOpen: () -> Void
    /// 窗口很窄时缩放控件收进这里（spec E1-10 ⑤）
    var zoomState: ZoomState? = nil
    var zoomInMenu = false
    var onZoom: (ZoomCommand.Action) -> Void = { _ in }
    /// 有新版本：⋯ 按钮上的小点和菜单第一项（spec U2-04）
    var updateVersion: String? = nil
    var onUpdate: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            // 按钮图标是逆时针箭头，点按向左转；R 向右转、⇧R 向左转（菜单“文件 › 向右旋转”）
            ToolButton(symbol: "arrow.counterclockwise", help: "向左旋转（⇧R）", selected: rotateSelected, action: onRotate)
                .disabled(!enabled)
            // 编辑（spec ED-01、ED-02）：不支持时不用 disabled，好让悬停提示照常出现
            EditEntryButton(unsupported: editUnsupported, action: onEdit)
            ToolButton(symbol: "info.circle", help: "信息（I）", selected: infoSelected, action: onInfo)
                .disabled(!enabled)
            Menu {
                if let updateVersion {
                    Button(String(localized: "有新版本 v\(updateVersion)…", comment: "菜单：有新版本；%@ 是版本号"), action: onUpdate)
                    Divider()
                }
                if zoomInMenu, let zoomState {
                    Section(String(localized: "缩放 · \(ZoomPercentLabel.text(zoomState.percent))", comment: "⋯ 菜单里缩放组的标题；%@ 是当前比例")) {
                        ZoomMenuItems(state: zoomState, includeSteps: true, stepsFirst: true, onZoom: onZoom)
                    }
                    Divider()
                }
                Button("在访达中显示", action: onReveal).disabled(!enabled)
                Button("拷贝文件路径", action: onCopyPath).disabled(!enabled)
                Divider()
                Button("打开…", action: onOpen)
            } label: {
                ToolButtonLabel(symbol: "ellipsis")
                    .overlay(alignment: .topTrailing) {
                        if updateVersion != nil {
                            // 直径 9，系统强调色，1pt 深色描边，距按钮上、右 3
                            Circle().fill(Theme.accent).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                                .padding(3)
                        }
                    }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("更多")
        }
        .padding(.horizontal, 3)
        .frame(height: 36)
        .regularGlass(Capsule())
    }
}

struct ToolButton: View {
    let symbol: String
    let help: LocalizedStringKey
    /// 打开状态（信息面板显示时 ⓘ 高亮，白 24% 底）
    var selected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) { ToolButtonLabel(symbol: symbol, selected: selected) }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.3)
            .help(help)
    }
}

/// 顶部工具组里的「编辑」入口：铅笔图标，和旁边的图标按钮同一个样式。
/// 不用裁切图标：编辑模式里不只有裁切，裁切图标看不出是“进入编辑”。
/// 不支持编辑的文件上不用 disabled，好让悬停提示照常出现
struct EditEntryButton: View {
    let unsupported: Bool
    let action: () -> Void

    var body: some View {
        ToolButton(symbol: "pencil", help: unsupported ? "此类文件不支持编辑" : "编辑（E）") {
            if !unsupported { action() }
        }
        .opacity(unsupported ? 0.3 : 1)
        .accessibilityLabel(Text("编辑"))
    }
}

struct ToolButtonLabel: View {
    let symbol: String
    var selected = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(selected ? Theme.selectedFill : Color.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// 左右切换箭头（设计稿 .nav）：44pt 圆形玻璃
struct NavArrow: View {
    let isNext: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isNext ? "chevron.right" : "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .regularGlass(Circle(), interactive: enabled)
        .opacity(enabled ? 1 : 0.35)
        .allowsHitTesting(enabled)
        .help(isNext ? "下一个（→ ↓）" : "上一个（← ↑）")
        .accessibilityLabel(isNext ? "下一个" : "上一个")
    }
}
