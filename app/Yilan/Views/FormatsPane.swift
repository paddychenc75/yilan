import AppKit
import SwiftUI

/// 设置 › 文件格式：每组一张卡片，一行一个格式；开着的行只有名字和开关，关着的行在开关左边写现在由谁打开。
/// RAW 有 8 种，默认收起成一行，点开才展开。
struct FormatsPane: View {
    @Bindable var model: DefaultHandlers
    @State private var rawExpanded = ShotHooks.formats == "raw"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("打开开关后，双击这种格式的文件就用一览打开。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = model.banner {
                FormatsBanner(banner: banner, onStop: model.stop)
            }
            ForEach(HandlerFormat.Group.allCases) { group in
                groupView(group)
            }
            HStack(spacing: 8) {
                Text("关掉开关后交还给系统默认应用（预览 / QuickTime Player）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                Button("全部关闭") { model.requestAll(on: false) }
                    .buttonStyle(GrayButtonStyle(enabled: !model.isBusy && model.anyOn))
                    .disabled(model.isBusy || !model.anyOn)
                Button("全部设为一览") { model.requestAll(on: true) }
                    .buttonStyle(GrayButtonStyle(enabled: !model.isBusy && !model.allOn))
                    .disabled(model.isBusy || model.allOn)
            }
            .padding(.horizontal, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isBusy { model.refresh() }
        }
        .onAppear { if !model.isBusy { model.refresh() } }
    }

    /// RAW 组收起时只显示一行摘要；这一组正在批量设置或有未改动提示时自动展开
    private func isCollapsed(_ group: HandlerFormat.Group) -> Bool {
        guard group == .raw, !rawExpanded else { return false }
        return !group.formats.contains { model.notes[$0] != nil }
    }

    private func groupView(_ group: HandlerFormat.Group) -> some View {
        let formats = group.formats
        let on = model.onCount(group)
        let collapsed = isCollapsed(group)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                Button(on == formats.count ? "全部关闭" : "全部打开") { model.requestGroup(group) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(model.isBusy ? Theme.text3 : Theme.link)
                    .disabled(model.isBusy)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                if group == .raw {
                    Button { rawExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Text("相机 RAW").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            Text("索尼、佳能、尼康、富士等 \(formats.count) 种", comment: "文件格式页：RAW 组收起时的说明")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                            Spacer(minLength: 0)
                            Text("\(on) 种由一览打开", comment: "文件格式页：RAW 组里几种由一览打开")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !collapsed {
                    ForEach(Array(formats.enumerated()), id: \.element) { index, format in
                        if index > 0 || group == .raw { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
                        row(format)
                    }
                }
            }
            .settingsGroupBackground()
        }
    }

    private func row(_ format: HandlerFormat) -> some View {
        let isOn = model.isYilan(format)
        return HStack(spacing: 10) {
            Text(format.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Text(format.detail).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            Spacer(minLength: 8)
            status(format, isOn: isOn)
                .font(.system(size: 12))
                .lineLimit(1)
            SettingsSwitch(isOn: Binding(get: { isOn }, set: { value in
                Task { await model.setSwitch(format, on: value) }
            }))
            .disabled(model.isBusy)
            .accessibilityLabel(Text("默认用一览打开 \(format.name)"))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(model.notes[format] == .busy ? Color.white.opacity(0.06) : .clear)
    }

    /// 开关左边的小字：开着且没有提示时什么都不写；关着时写现在由谁打开
    @ViewBuilder private func status(_ format: HandlerFormat, isOn: Bool) -> some View {
        switch model.notes[format] {
        case .justSet:
            Label { Text("已设为默认") } icon: { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .restored:
            HStack(spacing: 6) {
                Text("已交给").foregroundStyle(Theme.text3)
                AppIcon(app: model.current[format])
                Text(verbatim: model.appName(format)).foregroundStyle(Theme.text2)
            }
        case .unchanged:
            Text("未改动").foregroundStyle(Theme.yellow)
        case .busy:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在设置…").foregroundStyle(Theme.text3)
            }
        case .waiting:
            Text("等待中…").foregroundStyle(Theme.text3)
        case nil:
            if isOn {
                EmptyView()
            } else if model.current[format] == nil {
                Text("没有应用", comment: "文件格式：这个格式没有应用能打开").foregroundStyle(Theme.text3)
            } else {
                HStack(spacing: 6) {
                    AppIcon(app: model.current[format])
                    Text(verbatim: model.appName(format)).foregroundStyle(Theme.text2)
                }
            }
        }
    }
}

/// 应用图标 14 × 14
private struct AppIcon: View {
    let app: AppRef?

    var body: some View {
        if let app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 14, height: 14)
        }
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// 组头三态复选框 16 × 16：空 / 「−」 / 勾；点空或混合 = 全开，点勾 = 全关
struct TriStateBox: View {
    let on: Int
    let total: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on > 0 ? Theme.accent : .clear)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(on > 0 ? Theme.accent : Color.white.opacity(0.4), lineWidth: 1.5)
                if on == total {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                } else if on > 0 {
                    Image(systemName: "minus").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(on == total ? "全部打开" : on == 0 ? "全部关闭" : "部分打开"))
    }
}

/// 说明条：黄色（失败）、绿色（结果）、灰色（进行中，带「停止」）
private struct FormatsBanner: View {
    let banner: DefaultHandlers.Banner
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            switch banner.kind {
            case .warn: Image(systemName: "exclamationmark.triangle.fill")
            case .ok: Image(systemName: "checkmark.circle.fill")
            case .progress: ProgressView().controlSize(.small)
            }
            Text(banner.text).fixedSize(horizontal: false, vertical: true)
            if banner.kind == .progress {
                Spacer(minLength: 0)
                Button("停止", action: onStop).buttonStyle(GrayButtonStyle(height: 24, fontSize: 11.5))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
    }

    private var color: Color {
        switch banner.kind {
        case .warn: Color(hex: 0xFFE27A)
        case .ok: Color(hex: 0x7EE2A0)
        case .progress: Theme.text2
        }
    }

    private var fill: Color {
        switch banner.kind {
        case .warn: Theme.yellow.opacity(0.12)
        case .ok: Color(nsColor: .systemGreen).opacity(0.12)
        case .progress: Color.white.opacity(0.07)
        }
    }
}

/// 批量之前的说明（PD-17）：会弹几次系统确认框，用户同意才开始
struct FormatsPlanSheet: View {
    let plan: DefaultHandlers.Plan
    let model: DefaultHandlers

    var body: some View {
        let n = plan.formats.count
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.turnOn ? "把 \(n) 种格式改成用一览打开？" : "把 \(n) 种格式交还给系统默认应用？")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(plan.turnOn
                 ? "这 \(n) 种格式现在由 \(appList) 打开。只改「用哪个应用打开」，不动文件本身，之后可以在这里随时还原。"
                 : "图片和 RAW 交给“预览”，视频交给“QuickTime Player”。想用别的应用打开，可以之后在访达的「显示简介」里设置。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS 会为每种格式各问你一次，共 \(n) 次。如果在某一次选择保留原来的应用，就停在那里，剩下的不再询问。")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(HandlerFormat.Group.allCases) { group in
                    let count = plan.formats.filter { $0.group == group }.count
                    if count > 0 {
                        HStack(spacing: 5) {
                            Text(group.title)
                            Text("\(count) 次", comment: "批量说明：这一组要确认几次").foregroundStyle(Theme.text3)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { model.cancelPlan() }
                    .buttonStyle(GrayButtonStyle(height: 28, fontSize: 12.5))
                    .keyboardShortcut(.cancelAction)
                Button("继续") { Task { await model.runPlan() } }
                    .buttonStyle(AccentButtonStyle(height: 28, fontSize: 12.5))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 400)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// 现在由哪些应用打开（最多列 3 个，多了写「等」）
    private var appList: String {
        var names: [String] = []
        for f in plan.formats {
            let name = model.appName(f)
            if !names.contains(name) { names.append(name) }
        }
        let shown = names.prefix(3).joined(separator: String(localized: "、", comment: "列举应用名的分隔符"))
        return names.count > 3 ? String(localized: "\(shown) 等应用") : shown
    }
}

/// 灰色按钮（设计稿 .btn.g）
struct GrayButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(enabled ? .white : Theme.text3)
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(height: height)
            .background(Capsule().fill(Color.white.opacity(enabled ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(enabled ? 0.14 : 0.06), lineWidth: 1))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}
