import SwiftUI

/// 移到废纸篓前的确认框（设计稿 08 · 删除 · 确认 .alert）：
/// 整个窗口压暗 38%，中间一张宽 300、圆角 26 的厚玻璃卡片。Return 确认，Esc 取消
struct DeleteConfirm: View {
    let name: String
    @Binding var dontAsk: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture {}          // 挡住下面的点按
            card
        }
    }

    private var card: some View {
        VStack(spacing: 8) {
            WelcomeIcon(size: 56)
            Text("将“\(name)”移到废纸篓？", comment: "删除确认框标题，%@ 是文件名")
                .font(.system(size: 14, weight: .semibold))
                .lineSpacing(14 * 0.4)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("可以在废纸篓里恢复，\n也可以在删除后按 ⌘Z 撤销。")
                .font(.system(size: 12))
                .lineSpacing(12 * 0.55)
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $dontAsk) { Text("不再询问") }
                .toggleStyle(GlassCheckboxStyle())
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button(action: onCancel) { Text("取消") }
                    .buttonStyle(AlertButtonStyle(destructive: false))
                    .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) { Text("移到废纸篓") }
                    .buttonStyle(AlertButtonStyle(destructive: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 300)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// 确认框里的按钮（高 32，13pt 中等字重，平分宽度）：取消是玻璃，确认是红色 #FF453A 加 3pt 红色光圈
struct AlertButtonStyle: ButtonStyle {
    let destructive: Bool
    /// 白底深色字的主按钮（提示框里的「好」）
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                if prominent {
                    Capsule().fill(.white)
                } else if destructive {
                    Capsule().fill(Theme.danger)
                        // 外面 3pt 的光圈 rgba(255,69,58,.35)
                        .overlay(Capsule().stroke(Theme.danger.opacity(0.35), lineWidth: 3).padding(-1.5))
                } else {
                    Capsule().fill(Color.white.opacity(0.12))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                }
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

/// 14 × 14 的方形勾选框（圆角 4，白 35% 边，白 6% 底），文字 12pt 白 68%
private struct GlassCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(configuration.isOn ? Color.clear : Color.white.opacity(0.35), lineWidth: 1)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
