import SwiftUI

/// 设计稿 01 设计规范里的取值
enum Theme {
    static let stage = Color(red: 5 / 255, green: 5 / 255, blue: 6 / 255)        // #050506
    static let text2 = Color.white.opacity(0.68)
    static let text3 = Color.white.opacity(0.44)
    static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)            // #FFD60A
    /// 「相机预览图」标签的文字颜色 #FFE27A（设计稿第 07 章）；底色是 yellow 16%
    static let previewTag = Color(red: 1, green: 226 / 255, blue: 122 / 255)
    static let selectedFill = Color.white.opacity(0.24)
    static let link = Color(red: 100 / 255, green: 181 / 255, blue: 1)             // #64B5FF
    static let danger = Color(red: 1, green: 69 / 255, blue: 58 / 255)              // #FF453A
    /// 控件强调色跟随系统强调色（默认蓝色），不使用品牌色——看图界面保持中性
    static let accent = Color(nsColor: .controlAccentColor)

    /// 品牌色（松石绿）：取自 App 图标（design/yilan-icon.svg）。
    /// 必须和设计稿 yilan-design.html 里 :root 的 --brand-* 保持一致，改一边就要改另一边。
    /// 只用在没有图片时的环境光、拖入遮罩这类非看图界面；不要用在开关、滑块、按钮和看图界面上。
    enum Brand {
        static let teal = Color(hex: 0x128A80)      // --brand-teal，中间调，图标底板渐变的下端
        static let jade = Color(hex: 0x3FC4B0)      // --brand-jade，亮色，图标底板渐变的上端
        static let tealDeep = Color(hex: 0x0E3B3B)  // --brand-teal-deep，很深，图标画面的天空
        static let sun = Color(hex: 0xFFE2A0)       // --brand-sun，暖奶黄，图标里的太阳和倒影
        /// 拖入遮罩的底色：brand-teal-deep 每个通道 ×0.4 压暗（#061717），暗度和原来的 #0F1331 相当（亮度都约 19）
        static let tealNight = Color(hex: 0x061717) // --brand-teal-night
    }

    // 标注页（07 开发标注）里的尺寸
    static let titleBarHeight: CGFloat = 56
    static let imageInsetTop: CGFloat = 64
    static let imageInsetSide: CGFloat = 32
    static let imageInsetBottom: CGFloat = 132          // 缩略图栏上方
    static let imageInsetBottomNoStrip: CGFloat = 24
    // 视频控制条（设计稿 .vbar）：高 46，宽 580，距底 128（缩略图栏上方）；图片区再让出 58
    static let videoBarHeight: CGFloat = 46
    static let videoBarWidth: CGFloat = 580
    static let videoBarBottom: CGFloat = 128
    static let videoBarBottomNoStrip: CGFloat = 16
    static let compactWidth: CGFloat = 900              // 小于这个宽度：隐藏文件名，分段控件只显示图标
    static let dockMaxWidth: CGFloat = 900
    static let dockFullScreenWidth: CGFloat = 960      // 全屏时的缩略图栏宽度

    /// macOS 15 替代玻璃上加的黑色底（不透明度）
    static let legacyGlassTint: Double = 0.32

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// 常规玻璃：标题栏控件、缩略图栏、箭头（设计稿 .g）
    func regularGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        systemGlass(shape, interactive: interactive)
    }

    /// 系统玻璃。macOS 26 起用 Liquid Glass；macOS 15 没有，用半透明的毛玻璃材质加一圈细描边代替。
    /// 全应用只在这里判断系统版本，别处不要直接调用 glassEffect。
    @ViewBuilder
    func systemGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            // 毛玻璃很透，压在很亮的照片上时白字和蓝字看不清（v0.3.1 F1-04）：材质上再铺一层黑 32%
            background(ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(Theme.legacyGlassTint))
            })
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// 直接压在照片上的小字（标题栏的文件夹名）：macOS 15 上加一层阴影，亮照片上也看得清；macOS 26 不变
    @ViewBuilder
    func legacyLegibilityShadow() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        }
    }

    /// 标题栏第二行（文件夹名、计数）：macOS 26 是设计稿的白 68%；
    /// macOS 15 上压在白色照片上太淡（F2-04），改成白 90%，阴影加深（黑 75% 半径 2.5 + 黑 50% 半径 8 的一圈晕）
    @ViewBuilder
    func titleSubtitleStyle() -> some View {
        if #available(macOS 26.0, *) {
            foregroundStyle(Theme.text2)
        } else {
            foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.75), radius: 2.5, y: 1)
                .shadow(color: .black.opacity(0.5), radius: 8)
        }
    }

    /// 厚玻璃：卡片、菜单（设计稿 .gt，深灰 78–82%）
    /// 系统玻璃本身很透，上面再铺设计稿的灰色渐变（58,58,64 @78% → 34,34,38 @82%），描边白 11%
    func thickGlass<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(LinearGradient(
            colors: [Color(red: 58 / 255, green: 58 / 255, blue: 64 / 255).opacity(0.78),
                     Color(red: 34 / 255, green: 34 / 255, blue: 38 / 255).opacity(0.82)],
            startPoint: .top, endPoint: .bottom)))
        .systemGlass(shape)
        .overlay(shape.stroke(Color.white.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
    }
}

/// 白底主要按钮（设计稿 .btn.pri）
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(white: 0.07))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.3), radius: 7, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

/// 玻璃按钮（设计稿 .btn.g）
struct GlassCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .regularGlass(Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}
