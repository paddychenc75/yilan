import AppKit
import SwiftUI

/// 设置 › 文件格式（spec 19、设计稿 1.8）：每组一张卡片，里面两栏格子，每格一个「默认用一览打开」开关
struct FormatsPane: View {
    @Bindable var model: DefaultHandlers

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("打开开关，这个格式的文件双击后就用一览打开；关掉开关，就还原成之前打开它的应用。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("全部设为一览") { model.requestAll(on: true) }
                    .buttonStyle(GrayButtonStyle(enabled: !model.isBusy && !model.allOn))
                    .disabled(model.isBusy || model.allOn)
                Button("全部还原") { model.requestAll(on: false) }
                    .buttonStyle(GrayButtonStyle(enabled: !model.isBusy && model.anyOn))
                    .disabled(model.isBusy || !model.anyOn)
            }
            if let banner = model.banner {
                FormatsBanner(banner: banner, onStop: model.stop)
            }
            ForEach(HandlerFormat.Group.allCases) { group in
                groupView(group)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RAW 使用系统自带的解码，支持的相机型号以 macOS 为准。")
                Text("一览不会自己修改这些设置，只有你拨开关才会改。")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isBusy { model.refresh() }
        }
        .onAppear { if !model.isBusy { model.refresh() } }
    }

    private func groupView(_ group: HandlerFormat.Group) -> some View {
        let formats = group.formats
        let on = model.onCount(group)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                Text("已开 \(on) / \(formats.count)", comment: "文件格式组头：这一组几个格式由一览打开")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                TriStateBox(on: on, total: formats.count) { model.requestGroup(group) }
                    .disabled(model.isBusy)
                    .help(on == formats.count ? String(localized: "全部关闭") : String(localized: "全部打开"))
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            // 两栏格子：一行两个，奇数个时最后一格独占左栏
            VStack(spacing: 0) {
                ForEach(Array(stride(from: 0, to: formats.count, by: 2)), id: \.self) { start in
                    if start > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
                    HStack(spacing: 0) {
                        cell(formats[start])
                        Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                        if start + 1 < formats.count { cell(formats[start + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsGroupBackground()
        }
    }

    private func cell(_ format: HandlerFormat) -> some View {
        let isOn = model.isYilan(format)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(format.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text(format.detail).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                statusLine(format, isOn: isOn)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(isOn: Binding(get: { isOn }, set: { value in
                Task { await model.setSwitch(format, on: value) }
            }))
            .disabled(model.isBusy)
            .accessibilityLabel(Text("默认用一览打开 \(format.name)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(model.notes[format] == .busy ? Color.white.opacity(0.06) : .clear)
    }

    @ViewBuilder private func statusLine(_ format: HandlerFormat, isOn: Bool) -> some View {
        let name = model.appName(format)
        switch model.notes[format] {
        case .justSet:
            Label { Text("已设为默认") } icon: { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .restored:
            HStack(spacing: 5) {
                AppIcon(app: model.current[format])
                Text("已还原 · 由“\(name)”打开").foregroundStyle(Theme.text3)
            }
        case .unchanged:
            Text("未改动 · 由“\(name)”打开").foregroundStyle(Theme.yellow)
        case .busy:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在设置…").foregroundStyle(Theme.text3)
            }
        case .waiting:
            Text("等待中…").foregroundStyle(Theme.text3)
        case nil:
            if model.current[format] == nil {
                Text("没有应用", comment: "文件格式：这个格式没有应用能打开").foregroundStyle(Theme.text3)
            } else {
                HStack(spacing: 5) {
                    AppIcon(app: model.current[format])
                    Text("由“\(name)”打开").foregroundStyle(Theme.text3)
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
            Text(plan.turnOn ? "把 \(n) 种格式改成用一览打开？" : "把 \(n) 种格式还原成原来的应用？")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(plan.turnOn
                 ? "这 \(n) 种格式现在由 \(appList) 打开。只改「用哪个应用打开」，不动文件本身，之后可以在这里随时还原。"
                 : "每种格式还原成打开开关之前的应用；不知道之前是谁的，恢复成系统默认（预览 / QuickTime Player）。")
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
