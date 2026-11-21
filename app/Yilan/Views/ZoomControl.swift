import SwiftUI

/// 顶部缩放控件（设计稿 .zoomt）：[− 38% +]，高 36，和序号同材质；窄窗口时只留百分比（spec E1）
struct ZoomControl: View {
    let state: ZoomState
    /// true：只留百分比，放大 / 缩小进它的菜单
    let percentOnly: Bool
    /// 菜单最上面一行不可点的小字（相机预览图状态下写「相机预览图 · 宽 × 高」，spec C1-10）
    var note: String? = nil
    let onZoom: (ZoomCommand.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if !percentOnly {
                ZoomStepButton(symbol: "minus", enabled: state.canZoomOut, help: "缩小（⌘−）") { onZoom(.zoomOut) }
            }
            Menu {
                if let note {
                    Section(note) { ZoomMenuItems(state: state, includeSteps: percentOnly, onZoom: onZoom) }
                } else {
                    ZoomMenuItems(state: state, includeSteps: percentOnly, onZoom: onZoom)
                }
            } label: {
                ZoomPercentLabel(percent: state.percent, minWidth: percentOnly ? 58 : 62)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help(Text("缩放比例"))
            .accessibilityLabel(Text("缩放比例"))
            .accessibilityValue(Text(verbatim: ZoomPercentLabel.text(state.percent)))
            if !percentOnly {
                ZoomStepButton(symbol: "plus", enabled: state.canZoomIn, help: "放大（⌘+）") { onZoom(.zoomIn) }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .regularGlass(Capsule())
    }
}

/// 缩放菜单里的项（顶部百分比菜单和窄窗口时的 ⋯ 菜单共用）：适应窗口 ⌘9 / 实际大小 ⌘0 / 200%，当前状态打勾
struct ZoomMenuItems: View {
    let state: ZoomState?
    /// 只留百分比或在 ⋯ 菜单里时，加上“放大 ⌘+ / 缩小 ⌘−”
    let includeSteps: Bool
    var stepsFirst = false
    let onZoom: (ZoomCommand.Action) -> Void

    var body: some View {
        if includeSteps && stepsFirst { steps }
        check(Text("适应窗口"), on: state?.isFit == true) { onZoom(.fit) }
            .keyboardShortcut("9")
        check(Text("实际大小"), on: state.map { !$0.isFit && $0.percent == 100 } ?? false) { onZoom(.actualSize) }
            .keyboardShortcut("0")
        check(Text(verbatim: "200%"), on: state.map { !$0.isFit && $0.percent == 200 } ?? false) { onZoom(.percent200) }
        if includeSteps && !stepsFirst {
            Divider()
            steps
        }
    }

    @ViewBuilder private var steps: some View {
        Button("放大") { onZoom(.zoomIn) }
            .keyboardShortcut("+")
            .disabled(!(state?.canZoomIn ?? false))
        Button("缩小") { onZoom(.zoomOut) }
            .keyboardShortcut("-")
            .disabled(!(state?.canZoomOut ?? false))
    }

    private func check(_ title: Text, on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) { title }
    }
}

/// 百分比：等宽字 12，后面一个上下小箭头（设计稿 .zp）
struct ZoomPercentLabel: View {
    let percent: Int
    let minWidth: CGFloat
    @State private var hovering = false

    static func text(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: Self.text(percent)).font(Theme.mono(12))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.6)
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minWidth: minWidth)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

/// − / + 按钮：30 × 28，悬停白 16%，按下白 28% 并缩到 0.94，不可用 30%
struct ZoomStepButton: View {
    let symbol: String
    let enabled: Bool
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 28)
                .background(Capsule().fill(Color.white.opacity(hovering && enabled ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(ZoomStepStyle())
        .onHover { hovering = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(Text(help))
    }
}

private struct ZoomStepStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
