import SwiftUI

/// 编辑模式的界面（设计稿 edit.html 01–10、「给开发的说明」）

// MARK: - 顶部栏

/// 编辑顶部栏（高 56）：左边标题 +「● 编辑中」，右边缩放、取消、保存（spec ED-05）
struct EditTopBar: View {
    @Bindable var session: EditSession
    let zoom: ZoomState?
    let narrow: Bool
    let titleMax: CGFloat
    let onZoom: (ZoomCommand.Action) -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    let onReplace: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 52, height: 12)   // 红绿灯占位
            if !narrow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text("编辑中", comment: "编辑模式标题下面的状态")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: titleMax, alignment: .leading)
                .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            if let zoom {
                ZoomControl(state: zoom, percentOnly: narrow, onZoom: onZoom)
            }
            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: narrow ? 60 : 68, height: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .regularGlass(Capsule(), interactive: true)
            .disabled(session.saving)
            .help(Text("放弃编辑（Esc）"))
            SaveSplitButton(session: session, onSave: onSave, onReplace: onReplace)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: Theme.titleBarHeight)
    }
}

/// 保存按钮（设计稿 .sbtn）：左半默认动作（定宽 118），右半箭头（宽 30）展开其他保存方式
struct SaveSplitButton: View {
    @Bindable var session: EditSession
    let onSave: () -> Void
    let onReplace: () -> Void
    @State private var hoverLeft = false
    @State private var hoverRight = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSave) {
                ZStack {
                    if session.saving {
                        ProgressView().controlSize(.small).tint(.white).scaleEffect(0.8)
                    } else {
                        HStack(spacing: 7) {
                            Text(verbatim: EditTexts.saveLabel(session))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(verbatim: "↩").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.leading, 8)
                .frame(width: 118, height: 32)
                .background(Color.white.opacity(hoverLeft && !session.saving ? 0.08 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverLeft = $0 }
            Rectangle().fill(Color.white.opacity(0.28)).frame(width: 1, height: 32)
            Button {
                session.ratioMenuOpen = false
                session.resizeOpen = false
                session.straightenOpen = false
                session.saveMenuOpen.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 29, height: 32)
                    .background(Color.black.opacity(session.saveMenuOpen ? 0.18 : 0))
                    .background(Color.white.opacity(hoverRight && !session.saveMenuOpen ? 0.08 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverRight = $0 }
            .help(Text("其他保存方式"))
        }
        .foregroundStyle(.white)
        .background(Theme.accent)
        .clipShape(Capsule())
        .shadow(color: Theme.accent.opacity(0.28), radius: 7, y: 4)
        .disabled(session.saving)
        .overlay(alignment: .topTrailing) {
            if session.saveMenuOpen {
                SaveMenu(session: session, onSave: onSave, onReplace: onReplace)
                    .fixedSize()
                    .offset(y: 40)
                    .transition(.opacity)
            }
        }
    }
}

/// 保存按钮的箭头菜单（设计稿 06、07；spec ED-29、ED-33、ED-34）
struct SaveMenu: View {
    @Bindable var session: EditSession
    let onSave: () -> Void
    let onReplace: () -> Void

    var body: some View {
        let target = session.target
        let copyName = EditTexts.copyName(session)
        EditMenuPanel(minWidth: 250) {
            switch target.reason {
            case .raw:
                // RAW 不能进编辑（spec C6-01），走不到这里
                EmptyView()
            case .unwritable(let format):
                let text = target.isPNG ? String(localized: "存为 PNG 副本") : String(localized: "存为 JPEG 副本")
                let why = target.isPNG
                    ? String(localized: "\(format) 无法直接写入，存为 PNG", comment: "保存菜单说明；%@ 是原格式名，例如 WebP")
                    : String(localized: "\(format) 无法直接写入，存为 JPEG", comment: "保存菜单说明；%@ 是原格式名，例如 WebP")
                EditMenuRow(title: text, subtitle: why, checked: true, shortcut: "↩", action: onSave)
                EditMenuRow(title: String(localized: "替换原图…"),
                            subtitle: String(localized: "\(format) 无法直接写入", comment: "替换原图置灰的原因；%@ 是原格式名"),
                            enabled: false) {}
            case .same:
                EditMenuRow(title: String(localized: "另存为副本"),
                            subtitle: String(localized: "\(copyName) · 原图不动", comment: "保存菜单：%@ 是副本文件名"),
                            checked: true, shortcut: "↩", action: onSave)
                EditMenuRow(title: String(localized: "替换原图…"), subtitle: String(localized: "原图移到废纸篓，⌘Z 可找回"),
                            shortcut: "⌥↩", action: onReplace)
            }
        }
    }
}

// MARK: - 底部工具条

/// 底部编辑工具条（设计稿 .ebar）：比例、横竖、像素尺寸 | 左转、右转、拉直 | 缩小 | 复原
struct EditToolbar: View {
    @Bindable var session: EditSession
    let narrow: Bool
    let onRotate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ratioButton
            EditIconButton(symbol: session.portrait ? "rectangle.portrait" : "rectangle",
                           help: String(localized: "横竖互换（X）"), selected: session.canSwap) {
                session.swapOrientation()
            }
            .disabled(!session.canSwap)
            Text(verbatim: "\(session.outputSize.width) × \(session.outputSize.height)")
                .font(Theme.mono(12.5))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: narrow ? 96 : 118)
                .help(Text("保存后的像素尺寸"))
            separator
            EditIconButton(symbol: "rotate.left", help: String(localized: "向左旋转（⇧R）")) { onRotate(-1) }
            EditIconButton(symbol: "rotate.right", help: String(localized: "向右旋转（R）")) { onRotate(1) }
            StraightenButton(session: session, narrow: narrow)
            separator
            resizeButton
            if !narrow {
                separator
                Button { session.reset() } label: {
                    Text("复原")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!session.isDirty)
                .opacity(session.isDirty ? 1 : 0.32)
                .help(Text("撤掉本次所有改动（⌘⌫）"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .regularGlass(Capsule())
        .disabled(session.saving)
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 6)
    }

    private var ratioButton: some View {
        EditDropButton(open: session.ratioMenuOpen, width: narrow ? 104 : 118) {
            session.saveMenuOpen = false
            session.resizeOpen = false
            session.straightenOpen = false
            session.ratioMenuOpen.toggle()
        } label: {
            Image(systemName: "aspectratio").font(.system(size: 13.5))
            if !narrow { Text("比例").font(.system(size: 12)).foregroundStyle(Theme.text3).fixedSize() }
            Text(verbatim: EditTexts.ratioShort(session.ratio))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .help(Text("裁切比例"))
        .overlay(alignment: .bottomLeading) {
            // 菜单底边在工具条上沿再往上 12
            if session.ratioMenuOpen {
                RatioMenu(session: session)
                    .fixedSize()
                    .offset(y: -(34 + 7 + 12))
                    .transition(.opacity)
            }
        }
    }

    private var resizeButton: some View {
        EditDropButton(open: session.resizeOpen, width: narrow ? 82 : 96) {
            session.saveMenuOpen = false
            session.ratioMenuOpen = false
            session.straightenOpen = false
            session.resizeOpen.toggle()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 13))
            Text(verbatim: ZoomPercentLabel.text(ResizeMath.percent(session.scale)))
                .font(Theme.mono(12))
                .lineLimit(1)
                .frame(minWidth: 38, alignment: .trailing)
        }
        .help(Text("调整尺寸"))
        .overlay(alignment: .bottom) {
            // 面板在缩放按钮正上方 12（从工具条上沿算）
            if session.resizeOpen {
                ResizePanel(session: session)
                    .fixedSize()
                    .offset(y: -(34 + 7 + 12))
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - 拉直（spec E6；设计稿 95–97）

/// 工具条上的「拉直」：高 34 的胶囊，图标、文字「拉直」（窄窗口省掉）、角度（等宽字体，不是 0 时黄色）。
/// 点它开关刻度尺，开着时底 白 22%
struct StraightenButton: View {
    @Bindable var session: EditSession
    let narrow: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            session.ratioMenuOpen = false
            session.saveMenuOpen = false
            session.resizeOpen = false
            session.straightening = false
            session.straightenOpen.toggle()
        } label: {
            HStack(spacing: 7) {
                LevelIcon().frame(width: 15, height: 15)
                if !narrow { Text("拉直").font(.system(size: 12)).foregroundStyle(Theme.text3).fixedSize() }
                Text(verbatim: StraightenMath.label(session.angle))
                    .font(Theme.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(session.angle != 0 ? Theme.yellow : Color.white)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .padding(.leading, narrow ? 10 : 12)
            .padding(.trailing, 10)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(session.straightenOpen ? 0.22 : (hovering ? 0.12 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("拉直"))
    }
}

/// 拉直图标（设计稿 ic('level')，24×24 画布，线宽 1.8）：一条斜线、上面一个向下的箭头、下面一条半透明的水平线
struct LevelIcon: View {
    private struct Lines: Shape {
        let segments: [[CGPoint]]
        func path(in rect: CGRect) -> Path {
            let k = min(rect.width, rect.height) / 24
            var path = Path()
            for seg in segments {
                path.addLines(seg.map { CGPoint(x: rect.minX + $0.x * k, y: rect.minY + $0.y * k) })
            }
            return path
        }
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: 1.8 * 15 / 24, lineCap: .round, lineJoin: .round)
        ZStack {
            Lines(segments: [[CGPoint(x: 3, y: 16.5), CGPoint(x: 21, y: 12.5)],
                             [CGPoint(x: 12, y: 4), CGPoint(x: 12, y: 10.5)],
                             [CGPoint(x: 9.5, y: 8), CGPoint(x: 12, y: 10.5), CGPoint(x: 14.5, y: 8)]])
                .stroke(style: style)
            Lines(segments: [[CGPoint(x: 3, y: 20.5), CGPoint(x: 21, y: 20.5)]])
                .stroke(style: style)
                .opacity(0.5)
        }
    }
}

/// 刻度尺（设计稿 .ruler）：玻璃，宽 440（窄窗口 340）、高 44、圆角 22。指针固定在正中，刻度在下面左右移动：
/// 每小格 1 度（8 点），每 5 度一条长刻度，量程 ±45。左右拖改变角度，按住 ⌥ 精细到 0.1 度；双击归零（spec E6-03）
struct StraightenRuler: View {
    @Bindable var session: EditSession
    let width: CGFloat
    /// 拖动中：没取整的角度和上一次的位移（⌥ 可以在拖动中途按下或松开）
    @State private var dragAngle: Double?
    @State private var lastX: CGFloat = 0

    var body: some View {
        let angle = session.angle
        ZStack(alignment: .top) {
            Canvas { ctx, size in
                let mid = size.width / 2
                let step = CGFloat(StraightenMath.pointsPerDegree)
                for k in -45...45 {
                    let x = (mid + CGFloat(Double(k) - angle) * step).rounded()
                    guard x > -2, x < size.width + 2 else { continue }
                    let major = k % 5 == 0
                    let rect = major ? CGRect(x: x, y: 22, width: 1, height: 12) : CGRect(x: x, y: 25, width: 1, height: 9)
                    ctx.fill(Path(rect), with: .color(.white.opacity(major ? 0.85 : 0.45)))
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                         .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            RoundedRectangle(cornerRadius: 1).fill(Theme.yellow).frame(width: 2, height: 20).padding(.top, 18)
            Text(verbatim: StraightenMath.label(angle))
                .font(Theme.mono(11.5, .semibold))
                .monospacedDigit()
                // 和工具条上的数字一致：不是 0 才变黄（spec E6-06）
                .foregroundStyle(angle == 0 ? Color.white : Theme.yellow)
                .padding(.top, 4)
        }
        .frame(width: width, height: 44)
        .regularGlass(Capsule())
        .contentShape(Capsule())
        .onTapGesture(count: 2) { session.setAngle(0) }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragAngle == nil {
                        dragAngle = session.angle
                        lastX = 0
                        session.straightening = true
                    }
                    let dx = value.translation.width - lastX
                    lastX = value.translation.width
                    let perPoint = (NSEvent.modifierFlags.contains(.option) ? 0.1 : 1) / StraightenMath.pointsPerDegree
                    // 刻度跟着手走：往右拖，指针下的刻度变小；到头停住，往回拖马上有反应
                    let next = min(max((dragAngle ?? 0) - Double(dx) * perPoint, -StraightenMath.maxAngle), StraightenMath.maxAngle)
                    dragAngle = next
                    session.setAngle(next)
                }
                .onEnded { _ in
                    dragAngle = nil
                    session.straightening = false
                }
        )
        .help(Text("拉直"))
    }
}

/// 工具条上带下拉箭头的按钮（设计稿 .ddb）：高 34，打开时底 白 22%，悬停 白 12%
struct EditDropButton<Label: View>: View {
    let open: Bool
    let width: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(width: width, height: 34)
            .background(Capsule().fill(Color.white.opacity(open ? 0.22 : (hovering ? 0.12 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.32)
    }
}

/// 工具条上的图标按钮（34×34，图标 18）
struct EditIconButton: View {
    let symbol: String
    let help: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(selected && isEnabled ? 0.24 : (hovering ? 0.14 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.32)
        .help(Text(verbatim: help))
    }
}

/// 比例菜单（设计稿 03，定宽 188）
struct RatioMenu: View {
    @Bindable var session: EditSession

    var body: some View {
        EditMenuPanel(minWidth: 188) {
            row(.free)
            row(.original)
            EditMenuSeparator()
            row(.square)
            row(.r4x3)
            row(.r3x2)
            row(.r16x9)
            EditMenuSeparator()
            EditMenuRow(title: String(localized: "横竖互换"), shortcut: "X", enabled: session.canSwap) { session.swapOrientation() }
        }
    }

    private func row(_ r: CropRatio) -> some View {
        EditMenuRow(title: EditTexts.ratioName(r),
                    shortcut: r == .original ? CropRatio.label(for: session.editedSize) : nil,
                    checked: session.ratio == r) { session.setRatio(r) }
    }
}

// MARK: - 菜单积木（设计稿 .menu / .mi）

struct EditMenuPanel<Content: View>: View {
    let minWidth: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(5)
            .frame(minWidth: minWidth, alignment: .leading)
            .thickGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EditMenuSeparator: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 8)
    }
}

struct EditMenuRow: View {
    let title: String
    var subtitle: String? = nil
    var shortcut: String? = nil
    var checked = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    init(title: String, subtitle: String? = nil, shortcut: String? = nil, checked: Bool = false, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.checked = checked
        self.enabled = enabled
        self.action = action
    }

    init(title: String, subtitle: String? = nil, checked: Bool, shortcut: String?, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, shortcut: shortcut, checked: checked, enabled: true, action: action)
    }

    var body: some View {
        let lit = hovering && enabled
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: checked ? "✓" : "").font(.system(size: 12)).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 13))
                    if let subtitle {
                        Text(verbatim: subtitle).font(.system(size: 11))
                            .foregroundStyle(lit ? Color.white.opacity(0.8) : Theme.text3)
                    }
                }
                Spacer(minLength: 0)
                if let shortcut {
                    Text(verbatim: shortcut).font(.system(size: 12.5)).tracking(0.5)
                        .foregroundStyle(lit ? Color.white : Theme.text3)
                        .padding(.leading, 24)
                }
            }
            .lineLimit(1)
            .foregroundStyle(enabled ? Color.white : Theme.text3)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - 调整尺寸面板（设计稿 04；spec ED-20 ~ ED-25）

struct ResizePanel: View {
    @Bindable var session: EditSession
    @State private var percentMode = false
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var percentText = ""
    /// 超过上限的那一项（宽 / 高 / 百分比），显示红框和说明
    @State private var overflow: Field?
    @FocusState private var focus: Field?

    enum Field: Hashable { case width, height, percent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("调整尺寸").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("保持比例 · 只能缩小").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            }
            segmented
            if percentMode { percentFields } else { pixelFields }
            Text(verbatim: message)
                .font(.system(size: 11.5))
                .lineSpacing(11.5 * 0.5)
                .foregroundStyle(overflow != nil ? Color(red: 1, green: 122 / 255, blue: 112 / 255) : Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 292)
        .thickGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            load()
            focus = percentMode ? .percent : .width
        }
    }

    private var crop: PixelSize { session.crop.size }

    private var segmented: some View {
        HStack(spacing: 2) {
            segment(String(localized: "resize.mode.pixels", defaultValue: "像素", comment: "调整尺寸面板的分段按钮：按像素输入（英文写全称 Pixels，输入框里的单位才缩写成 px）"), on: !percentMode) { switchMode(percent: false) }
            segment(String(localized: "百分比"), on: percentMode) { switchMode(percent: true) }
        }
        .padding(2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.white : Theme.text2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Color.white.opacity(0.2) : .clear)
                    .shadow(color: .black.opacity(on ? 0.25 : 0), radius: 1.5, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pixelFields: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field(String(localized: "宽"), text: $widthText, unit: String(localized: "像素"), which: .width)
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 18, height: 30)
            field(String(localized: "高"), text: $heightText, unit: String(localized: "像素"), which: .height)
        }
    }

    private var percentFields: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field(String(localized: "缩放到"), text: $percentText, unit: "%", which: .percent)
            VStack(alignment: .leading, spacing: 5) {
                Text("得到").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text(verbatim: "\(previewSize.width) × \(previewSize.height)")
                    .font(Theme.mono(13)).monospacedDigit()
                    .frame(height: 30, alignment: .leading)
                    .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, text: Binding<String>, unit: String, which: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack(spacing: 4) {
                TextField(text: text) { EmptyView() }
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .monospacedDigit()
                    .focused($focus, equals: which)
                    .onSubmit { commit(close: true) }
                    .onChange(of: text.wrappedValue) { _, new in typed(new, in: which) }
                Text(verbatim: unit).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay {
                let error = overflow == which
                let focused = focus == which
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(error ? Theme.danger : (focused ? Theme.accent : Color.white.opacity(0.12)), lineWidth: 1)
                if error || focused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke((error ? Theme.danger : Theme.accent).opacity(error ? 0.28 : 0.35), lineWidth: 3)
                        .padding(-1.5)
                }
            }
            .onChange(of: focus) { old, _ in if old == which { commit(close: false) } }
        }
        .frame(maxWidth: .infinity)
    }

    private var previewSize: PixelSize {
        if let p = Int(percentText), let s = ResizeMath.scale(forPercent: min(p, 100)) { return ResizeMath.output(crop: crop, scale: s) }
        return session.outputSize
    }

    private var message: String {
        switch overflow {
        case .width?:
            return String(localized: "不能放大。宽最大 \(String(crop.width)) 像素；离开输入框后自动改回 \(String(crop.width))。",
                          comment: "调整尺寸超过上限；两个参数都是最大宽度")
        case .height?:
            return String(localized: "不能放大。高最大 \(String(crop.height)) 像素；离开输入框后自动改回 \(String(crop.height))。",
                          comment: "调整尺寸超过上限；两个参数都是最大高度")
        case .percent?:
            return String(localized: "不能放大。最大 100%；离开输入框后自动改回 100。")
        case nil:
            return percentMode ? String(localized: "1–99 之间的整数。")
                : String(localized: "裁切后的尺寸是 \(String(crop.width)) × \(String(crop.height))，最大只能填这么多。回车确认数值。",
                         comment: "调整尺寸面板说明；参数是裁切后的宽和高")
        }
    }

    private func load() {
        let out = session.outputSize
        widthText = String(out.width)
        heightText = String(out.height)
        percentText = String(ResizeMath.percent(session.scale))
        overflow = nil
    }

    private func switchMode(percent: Bool) {
        commit(close: false)
        percentMode = percent
        load()
        focus = percent ? .percent : .width
    }

    /// 打字时：只留数字；宽高联动；超过上限标红
    private func typed(_ text: String, in which: Field) {
        let digits = ResizeMath.digits(text)
        if digits != text {
            switch which {
            case .width: widthText = digits
            case .height: heightText = digits
            case .percent: percentText = digits
            }
            return
        }
        guard focus == which, let value = Int(digits) else { return }
        switch which {
        case .width:
            overflow = value > crop.width ? .width : nil
            if value >= 1 { heightText = String(max(1, Int((Double(value) * Double(crop.height) / Double(crop.width)).rounded()))) }
        case .height:
            overflow = value > crop.height ? .height : nil
            if value >= 1 { widthText = String(max(1, Int((Double(value) * Double(crop.width) / Double(crop.height)).rounded()))) }
        case .percent:
            overflow = value > 100 ? .percent : nil
        }
    }

    /// 确认数值：超过上限改回上限（spec ED-23）；回车时关闭面板（spec ED-24）
    private func commit(close: Bool) {
        var scale: Double?
        if percentMode {
            let p = min(max(Int(percentText) ?? 100, 1), 100)
            scale = ResizeMath.scale(forPercent: p)
        } else if focus == .height || (focus == nil && Int(heightText) != session.outputSize.height && Int(widthText) == session.outputSize.width) {
            let h = min(max(Int(heightText) ?? crop.height, 1), crop.height)
            scale = ResizeMath.scale(forHeight: h, crop: crop)
        } else {
            let w = min(max(Int(widthText) ?? crop.width, 1), crop.width)
            scale = ResizeMath.scale(forWidth: w, crop: crop)
        }
        if let scale { session.scale = scale }
        load()
        if close { session.resizeOpen = false }
    }
}

// MARK: - 确认框、失败框（设计稿 06、10）

struct EditAlert: View {
    let symbol: String
    var symbolColor: Color = .white
    let title: String
    let message: String
    let secondary: String
    let primary: String
    let onSecondary: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(symbolColor)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.1)))
                Text(verbatim: title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)
                Text(verbatim: message)
                    .font(.system(size: 12))
                    .lineSpacing(12 * 0.6)
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: onSecondary) { Text(verbatim: secondary) }
                        .buttonStyle(EditAlertButtonStyle(primary: false))
                        .keyboardShortcut(.cancelAction)
                    Button(action: onPrimary) { Text(verbatim: primary) }
                        .buttonStyle(EditAlertButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
            .frame(width: 300)
            .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityAddTraits(.isModal)
        }
    }
}

private struct EditAlertButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                if primary {
                    Capsule().fill(Theme.accent).shadow(color: Theme.accent.opacity(0.28), radius: 7, y: 4)
                } else {
                    Capsule().fill(Color.white.opacity(0.12))
                }
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

// MARK: - 保存后的提示条（设计稿 08）

/// 底部提示条：图标 + 文字 +「撤销 ⌘Z」胶囊；高 36，厚玻璃
struct EditToastView: View {
    let toast: Toast
    let maxWidth: CGFloat
    var onAction: ((ToastAction) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(toast.tone == .warning ? Theme.yellow : .white)
            Text(verbatim: toast.text).font(.system(size: 12.5, weight: .medium)).truncationMode(.middle)
            if let action = toast.action {
                Button { onAction?(action) } label: {
                    HStack(spacing: 6) {
                        Text("撤销").font(.system(size: 12.5, weight: .semibold))
                        Text(verbatim: "⌘Z").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, toast.action == nil ? 14 : 6)
        .frame(height: 36)
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: maxWidth > 900, vertical: false)
        .thickGlass(Capsule())
    }
}

// MARK: - 浏览时的「保存旋转」胶囊（设计稿 09；spec ED-41 ~ ED-43）

struct SaveRotationChip: View {
    let lossless: Bool
    let menuOpen: Bool
    let copyName: String
    let onSave: () -> Void
    let onToggleMenu: () -> Void
    let onRotateOriginal: () -> Void
    let onSaveCopy: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSave) {
                HStack(spacing: 6) {
                    Image(systemName: "rotate.right").font(.system(size: 12.5, weight: .medium))
                    Text("保存旋转").font(.system(size: 12, weight: .medium))
                }
                .padding(.leading, 11)
                .padding(.trailing, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(lossless ? Text("改正原图的方向，画质不变（⌘Z 可撤销）") : Text("另存一份转好方向的副本"))
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 30)
            Button(action: onToggleMenu) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
                    .frame(width: 25, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .regularGlass(Capsule())
        .overlay(alignment: .topTrailing) {
            if menuOpen {
                EditMenuPanel(minWidth: 236) {
                    EditMenuRow(title: String(localized: "改原图方向"),
                                subtitle: lossless ? String(localized: "只改方向标记，画质不变，⌘Z 可撤销")
                                    : String(localized: "此格式无法只改方向"),
                                shortcut: nil, checked: lossless, enabled: lossless, action: onRotateOriginal)
                    EditMenuRow(title: String(localized: "另存为副本"), subtitle: copyName,
                                checked: !lossless, shortcut: nil, action: onSaveCopy)
                }
                .fixedSize()
                .offset(y: 36)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - 文案

enum EditTexts {
    /// 比例的名字（菜单里）
    static func ratioName(_ r: CropRatio) -> String {
        switch r {
        case .free: String(localized: "自由", comment: "裁切比例：不限")
        case .original: String(localized: "原始比例")
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        }
    }

    /// 比例按钮上显示的（「原始比例」写成「原始」）
    static func ratioShort(_ r: CropRatio) -> String {
        r == .original ? String(localized: "原始", comment: "比例按钮上：原始比例的简称") : ratioName(r)
    }

    /// 保存按钮左半的文字（spec ED-27、ED-34）
    @MainActor
    static func saveLabel(_ s: EditSession) -> String {
        let t = s.target
        switch t.reason {
        case .same: return String(localized: "存为副本")
        case .raw, .unwritable:
            if t.isPNG { return String(localized: "存为 PNG") }
            return String(localized: "存为 JPEG")
        }
    }

    /// 副本文件名（菜单小字）
    @MainActor
    static func copyName(_ s: EditSession) -> String {
        let ext = s.target.pathExtension
        let base = s.item.url.deletingPathExtension().lastPathComponent
        return EditNaming.baseName(base, attempt: 1) + (ext.isEmpty ? "" : ".\(ext)")
    }
}
