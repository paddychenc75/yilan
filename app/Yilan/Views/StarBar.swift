import AppKit
import SwiftUI

/// 设计稿的星形（24 网格：M12 3.8 l2.5 5.2 5.7.8 -4.1 4 1 5.7 L12 16.8 l-5.1 2.7 1-5.7 -4.1-4 5.7-.8z）
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint] = [(12, 3.8), (14.5, 9.0), (20.2, 9.8), (16.1, 13.8), (17.1, 19.5),
                              (12, 16.8), (6.9, 19.5), (7.9, 13.8), (3.8, 9.8), (9.5, 9.0)]
            .map { CGPoint(x: rect.minX + $0.0 / 24 * rect.width, y: rect.minY + $0.1 / 24 * rect.height) }
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }
}

/// 一颗星：亮星实心 sun #FFE2A0；未亮的白 62% 描边（线宽 1.7 / 24）；悬停预览半透明填充（设计稿 .st）
struct RatingStar: View {
    enum Look { case off, on, preview }
    let look: Look
    let size: CGFloat

    var body: some View {
        let line = 1.7 / 24 * size
        ZStack {
            switch look {
            case .on:
                StarShape().fill(Theme.Brand.sun)
                StarShape().stroke(Theme.Brand.sun, style: StrokeStyle(lineWidth: line, lineJoin: .round))
            case .preview:
                StarShape().fill(Theme.Brand.sun.opacity(0.42))
                StarShape().stroke(Theme.Brand.sun, style: StrokeStyle(lineWidth: line, lineJoin: .round))
            case .off:
                StarShape().stroke(Color.white.opacity(0.62), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(look == .on ? 0.45 : 0), radius: 1, y: 1)
    }
}

/// 五颗可点的星（画面胶囊和信息面板共用）：点第 N 颗 = N 星，点当前已亮的最后一颗 = 清除（spec R2-06、R2-07）
struct StarRow: View {
    let rating: Int
    let size: CGFloat
    let spacing: CGFloat
    var enabled = true
    /// 正在闪现的星级（第 N 颗放大 130% 并发光）
    var flash: RatingFlash?
    let onRate: (Int) -> Void

    @State private var hovered: Int?
    @State private var popped: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { n in
                RatingStar(look: look(n), size: size)
                    .scaleEffect(popped == n ? 1.3 : 1)
                    .shadow(color: Theme.Brand.sun.opacity(popped == n ? 0.7 : 0), radius: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = n } else if hovered == n { hovered = nil }
                    }
                    .onTapGesture { onRate(n == rating ? 0 : n) }
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(n) 星", comment: "读屏：第 N 颗星"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .allowsHitTesting(true)
        .onChange(of: flash?.serial) {
            guard let value = flash?.value, value > 0, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.15)) { popped = value }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeInOut(duration: 0.6)) { popped = nil }
            }
        }
    }

    private func look(_ n: Int) -> RatingStar.Look {
        if n <= rating { return .on }
        if enabled, let h = hovered, h > rating, n <= h { return .preview }
        return .off
    }
}

/// 按键评星时闪现的五星胶囊（设计稿 .rate，spec R3a）：高 38，圆角 19，左右 14，星 22、间距 4；深色玻璃；不能点
struct StarBar: View {
    let rating: Int
    let enabled: Bool
    let flash: RatingFlash?

    var body: some View {
        let flashing = flash != nil
        StarRow(rating: rating, size: 22, spacing: 4, enabled: false, flash: flash) { _ in }
            .allowsHitTesting(false)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Capsule().fill(LinearGradient(
                colors: [Color(red: 44 / 255, green: 44 / 255, blue: 50 / 255).opacity(0.62),
                         Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.68)],
                startPoint: .top, endPoint: .bottom)))
            .glassEffect(.regular, in: Capsule())
            .overlay(Capsule().stroke(flashing ? Theme.Brand.sun.opacity(0.6) : Color.white.opacity(0.16), lineWidth: 1))
            .shadow(color: Theme.Brand.sun.opacity(flashing ? 0.26 : 0), radius: 13)
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            .animation(.easeOut(duration: 0.2), value: flashing)
            .accessibilityHidden(true)
    }

    /// 胶囊底边离窗口底边（spec R3a-02）：缩略图栏显示 140，隐藏 32，全屏 140（只有图片能评星，不再有视频的位置）
    static func bottomOffset(stripVisible: Bool, fullScreen: Bool) -> CGFloat {
        fullScreen || stripVisible ? 140 : 32
    }
}

/// 缩略图左上角的星级角标“★ 4”（设计稿 .bdg.s）：高 16，圆角 5，左 4 右 6，黑 78%，星 10 + 白色数字 10.5 粗体
struct RatingBadge: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 3) {
            StarShape().fill(Theme.Brand.sun).frame(width: 10, height: 10)
            Text(verbatim: "\(rating)")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.78)))
        .accessibilityLabel(Text("\(rating) 星", comment: "星级值"))
    }
}

/// 顶部提示卡片（设计稿 .hint）：宽 430 / 480，圆角 22，左边 34 的图标块，标题 13 粗、正文 12，按钮 26 高
struct HintCardView: View {
    let card: HintCard
    let onPrimary: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card == .shortcutsChanged ? "keyboard" : "doc")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                message
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onPrimary) { primaryTitle }
                    .buttonStyle(card == .shortcutsChanged ? AnyHintButtonStyle.glass : AnyHintButtonStyle.primary)
                    .padding(.top, 7)
            }
            .padding(.trailing, card == .shortcutsChanged ? 20 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16))
        .frame(width: card == .shortcutsChanged ? 480 : 430)
        .thickGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if card == .shortcutsChanged {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel(Text("关闭"))
            }
        }
    }

    @ViewBuilder private var title: some View {
        switch card {
        case .shortcutsChanged: Text("快捷键有变化")
        case .sidecarCreated(let name, _): Text("已在旁边创建 \(name)", comment: "第一次为图片创建 .xmp 的提示；%@ 是小文件名")
        }
    }

    @ViewBuilder private var message: some View {
        switch card {
        case .shortcutsChanged:
            // 方括号里的是键帽（设计稿 .hint .kc）
            KeycapText(String(localized: "数字键 [1]–[5] 现在用来评星，[0] 清除星级。[0] 和 [1] 不再用来缩放：按 [Z] 在适应窗口和实际大小之间切换，[⌘0] 实际大小，[⌘9] 适应窗口。",
                              comment: "快捷键变化提示；方括号里的内容显示成键帽，不要翻译方括号里的按键"))
        case .sidecarCreated(_, let isRaw):
            // RAW 多一句 Lightroom 的读取方法
            isRaw ? Text("照片本身不会被改动，星级记在这个同名的 .xmp 小文件里。Lightroom 里要用「元数据 › 从文件读取元数据」才会看到新星级。") : Text("照片本身不会被改动，星级记在这个同名的 .xmp 小文件里。")
        }
    }

    @ViewBuilder private var primaryTitle: some View {
        switch card {
        case .shortcutsChanged: Text("查看快捷键")
        case .sidecarCreated: Text("知道了")
        }
    }
}

/// 提示卡片里的小按钮：高 26，字 12（设计稿 .hint .btn）
enum AnyHintButtonStyle: ButtonStyle {
    case glass, primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(self == .primary ? Color(white: 0.07) : .white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(self == .primary ? Color.white : Color.white.opacity(0.14)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

/// 一段文字，方括号里的部分画成小键帽（设计稿 .hint .kc：最小宽 18，高 18，圆角 5，字 11）
struct KeycapText: View {
    let source: String
    @Environment(\.displayScale) private var scale

    init(_ source: String) { self.source = source }

    var body: some View {
        Self.segments(source).reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .plain(let s): text + Text(verbatim: s)
            case .key(let k): text + Text(Image(nsImage: Self.keycap(k, scale: scale))).baselineOffset(-4)
            }
        }
    }

    enum Segment: Equatable { case plain(String), key(String) }

    /// “按 [Z] 切换” → [.plain("按 "), .key("Z"), .plain(" 切换")]
    static func segments(_ source: String) -> [Segment] {
        var out: [Segment] = []
        var rest = Substring(source)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            if open > rest.startIndex { out.append(.plain(String(rest[..<open]))) }
            out.append(.key(String(rest[rest.index(after: open)..<close])))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.plain(String(rest))) }
        return out
    }

    @MainActor
    private static func keycap(_ key: String, scale: CGFloat) -> NSImage {
        let view = Text(verbatim: key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = max(scale, 2)
        return renderer.nsImage ?? NSImage()
    }
}

/// 缩略图栏信息行里的五颗星（设计稿“评星控件：缩略图栏信息行里的星”，spec R2）：
/// 星 16、间距 3、整行宽 92；未评星淡空心（白 34%，悬停整行时 60%），亮星 sun；
/// 悬停第 N 颗时第 1…N 颗预览；悬停当前星级那颗时提示“再点一次 = 清除星级”；不可写时 40%，点击给提示
struct InfoRowStars: View {
    let rating: Int
    let enabled: Bool
    let onRate: (Int) -> Void

    @State private var hovered: Int? = ShotHooks.rowHover
    @State private var rowHovered = ShotHooks.rowHover != nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { n in
                star(n)
                    .frame(width: 19, height: 24)   // 热区 19 × 24，相邻不留缝
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = n } else if hovered == n { hovered = nil }
                    }
                    .onTapGesture { onRate(n == rating ? 0 : n) }
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(n) 星", comment: "读屏：第 N 颗星"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(width: 92, height: 16)
        .onHover { rowHovered = $0 }
        .opacity(enabled ? 1 : 0.4)
        .overlay(alignment: .top) {
            if enabled, let h = hovered, h == rating, rating > 0 {
                Text("再点一次 = 清除星级")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .thickGlass(Capsule())
                    .offset(y: -34)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("评星"))
        .accessibilityValue(rating > 0 ? Text("\(rating) 星", comment: "星级值") : Text("未评星"))
    }

    private func star(_ n: Int) -> some View {
        let line: CGFloat = 1.5 / 24 * 16
        let preview = enabled && (hovered.map { n <= $0 } ?? false)
        let lit = n <= rating
        return ZStack {
            if preview {
                StarShape().fill(Theme.Brand.sun.opacity(0.45))
                StarShape().stroke(Theme.Brand.sun, style: StrokeStyle(lineWidth: line, lineJoin: .round))
            } else if lit {
                StarShape().fill(Theme.Brand.sun)
                StarShape().stroke(Theme.Brand.sun, style: StrokeStyle(lineWidth: line, lineJoin: .round))
            } else {
                StarShape().stroke(Color.white.opacity(rowHovered && enabled ? 0.6 : 0.34),
                                   style: StrokeStyle(lineWidth: line, lineJoin: .round))
            }
        }
        .frame(width: 16, height: 16)
    }
}
