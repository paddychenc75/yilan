import AppKit
import SwiftUI

/// 画廊视图 ↔ 图标视图的切换动画（spec V2-03）：选中的那一张从格子放大成大图、或从大图缩回格子，
/// 其余部分照旧淡入淡出。
///
/// 做法：切换那一刻模型状态立即切过去（按键作用于切换后的视图），另外记下这一张的「过渡图」和起点；
/// RootView 在两个视图上面盖一张过渡图，0.25 秒从起点矩形飞到终点矩形。飞行期间目标视图里那一张先不画，
/// 落位后再露出来、过渡图淡掉。去画廊时大图是异步解码的：过渡图垫到大图出来为止，不闪黑。
struct ViewSwitchTransition {
    /// 每次切换加 1：过渡图按它重建，旧动画不会接着跑
    let serial: Int
    /// 飞的是哪个文件
    let url: URL
    /// true：画廊 → 图标视图；false：图标视图 → 画廊
    let toGrid: Bool
    /// 过渡图：去画廊用缩略图；回图标视图用大图上正显示的画面（没有就用缩略图）
    let image: CGImage
    /// 缩略图的宽高比（网格里那一格按它排）
    let thumbnailAspect: CGFloat
    /// 画廊那一端画面的像素尺寸（已按显示方向）；nil 表示还不知道，按缩略图的比例铺满图片区
    let galleryPixelSize: CGSize?
    /// 画廊那一端是否允许放大超过原始像素（矢量图、占位缩略图）
    let galleryAllowsUpscale: Bool
    /// 去画廊时网格里那一格缩略图现在的位置（窗口坐标，左上为原点）；回图标视图时为 nil（按网格算法预测落点）
    let gridSourceRect: CGRect?
    /// 过渡图已经飞到终点
    var landed = false

    /// 过渡图落位后最多再垫多久（大图还没解出来时）：到点就拿掉，大图区显示它自己的占位图
    static let duration: Double = 0.25
    static let maxHold: Double = 0.75
}

/// 切换动画的几个矩形（纯函数，测试见 ViewSwitchGeometryTests）。坐标都是窗口里的点，左上为原点，y 向下
enum ViewSwitchGeometry {
    /// 画廊视图里画面「适应窗口」时的位置：和 ImageStageView.layoutImage 同一规则。
    /// 位图不放大超过 100%（1 像素 = 1 点）；pixelSize 不知道时按 aspect 铺满图片区（和占位缩略图一样）
    static func galleryRect(area: CGRect, pixelSize: CGSize?, aspect: CGFloat, allowsUpscale: Bool) -> CGRect {
        let size: CGSize
        let upscale: Bool
        if let p = pixelSize, p.width > 0, p.height > 0 {
            size = p
            upscale = allowsUpscale
        } else {
            let a = aspect > 0 ? aspect : 1.5
            size = CGSize(width: a, height: 1)
            upscale = true
        }
        var s = min(area.width / size.width, area.height / size.height)
        if !upscale { s = min(s, 1) }
        let w = size.width * s, h = size.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    /// 画廊视图的图片区：窗口减去四边留白
    static func galleryArea(size: CGSize, insets: NSEdgeInsets) -> CGRect {
        CGRect(x: insets.left, y: insets.top,
               width: max(1, size.width - insets.left - insets.right),
               height: max(1, size.height - insets.top - insets.bottom))
    }

    /// 刚切到图标视图时，第 index 张的缩略图会落在哪。网格每次切换都是新建的，从顶端开始，
    /// 然后按 reveal 的规则滚到这一张完整可见（spec SEL-03）
    static func predictedGridRect(index: Int, count: Int, metrics: GridMetrics, viewportHeight: CGFloat, aspect: CGFloat) -> CGRect {
        let cell = metrics.cellFrame(at: index)
        let offset = GridMetrics.revealOffset(for: cell, current: 0, viewportHeight: viewportHeight,
                                              contentHeight: metrics.contentHeight(count: count)) ?? 0
        return metrics.thumbnailRect(aspect: aspect).offsetBy(dx: cell.minX, dy: cell.minY - offset)
    }

    /// 起点终点都要像样：有面积、至少一部分在窗口里
    static func isUsable(_ rect: CGRect, in size: CGSize) -> Bool {
        rect.width >= 2 && rect.height >= 2 && rect.intersects(CGRect(origin: .zero, size: size))
    }
}

/// 盖在两个视图上面的过渡图。起点终点只在出现时取一次（之后窗口里别的变化不影响这次飞行）
struct ViewSwitchOverlay: View {
    let image: CGImage
    let onLanded: () -> Void
    @State private var from: CGRect
    @State private var to: CGRect
    @State private var arrived = false

    init(image: CGImage, from: CGRect, to: CGRect, onLanded: @escaping () -> Void) {
        self.image = image
        self.onLanded = onLanded
        _from = State(initialValue: from)
        _to = State(initialValue: to)
    }

    var body: some View {
        let r = arrived ? to : from
        // 格子里缩略图圆角 5，大图圆角 4
        let radius: CGFloat = 4.5
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeInOut(duration: ViewSwitchTransition.duration)) {
                    arrived = true
                } completion: {
                    onLanded()
                }
            }
    }
}

extension BrowserModel {
    /// 切换前拍下过渡动画要的东西；不满足条件（见下）就返回 nil，这次只淡入淡出。
    /// 只读已经在内存里的东西（缓存的缩略图、正显示的画面），不触发任何解码
    func makeViewSwitch(to mode: ViewMode, target url: URL?) -> ViewSwitchTransition? {
        // 上一次的动画还没收尾（连续快速按 G）：这次只淡入淡出，不叠两张过渡图
        guard viewSwitch == nil else { return nil }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        guard let url, let item = items.first(where: { $0.url == url }) else { return nil }
        // 网格那一端要知道缩略图的比例才排得出位置；缓存里没有缩略图就不做
        let thumb = ThumbnailStore.large.cached(item)?.image ?? ThumbnailStore.shared.cached(item)?.image
        guard let thumb, thumb.width > 0, thumb.height > 0 else { return nil }
        let aspect = CGFloat(thumb.width) / CGFloat(thumb.height)
        let serial = self.serial + 1
        defer { self.serial = serial }
        switch mode {
        case .grid:
            // 全屏会先退出全屏（窗口大小在变），放大、转过、出错时画面和缩略图对不上：都只淡入淡出
            guard !isFullScreen, failure == nil, stageRotation == 0, zoomState?.isFit != false,
                  displayedItem?.url == url, current?.url == url else { return nil }
            if let d = displayed {
                return ViewSwitchTransition(serial: serial, url: url, toGrid: true, image: d.image, thumbnailAspect: aspect,
                                            galleryPixelSize: displayedPixelSize, galleryAllowsUpscale: item.format == .svg,
                                            gridSourceRect: nil)
            }
            if let p = placeholder {
                return ViewSwitchTransition(serial: serial, url: url, toGrid: true, image: p, thumbnailAspect: aspect,
                                            galleryPixelSize: CGSize(width: p.width, height: p.height), galleryAllowsUpscale: true,
                                            gridSourceRect: nil)
            }
            return nil
        case .gallery:
            // 那一格滚出了可见区（或网格还没排好）：没有起点，只淡入淡出
            guard let source = gridGeometry?.thumbnailRect(for: url) else { return nil }
            let meta = gridMeta?.url == url ? gridMeta : nil
            let pixel = meta.flatMap { m -> CGSize? in
                guard let w = m.pixelWidth, let h = m.pixelHeight, w > 0, h > 0 else { return nil }
                return CGSize(width: w, height: h)
            }
            return ViewSwitchTransition(serial: serial, url: url, toGrid: false, image: thumb, thumbnailAspect: aspect,
                                        galleryPixelSize: pixel, galleryAllowsUpscale: item.format == .svg,
                                        gridSourceRect: source)
        }
    }

    /// 开始一次切换动画（nil = 只淡入淡出）。过一段时间不管怎样都收尾，不会留下残影
    func beginViewSwitch(_ transition: ViewSwitchTransition?) {
        // 上一次的过渡图还在（连续快速按 G）：跟着这次的淡入淡出一起淡掉
        if transition == nil, viewSwitch != nil {
            withAnimation(.easeOut(duration: 0.15)) { viewSwitch = nil }
        }
        guard let transition else { return }
        viewSwitch = transition
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ViewSwitchTransition.duration + ViewSwitchTransition.maxHold))
            self?.endViewSwitch(transition.serial)
        }
    }

    /// 过渡图飞到了终点
    func viewSwitchLanded(_ serial: Int) {
        guard viewSwitch?.serial == serial else { return }
        viewSwitch?.landed = true
    }

    /// 拿掉过渡图（淡出 0.12 秒），目标视图里那一张露出来。serial 为 nil：不管是哪一次都拿掉
    func endViewSwitch(_ serial: Int? = nil) {
        guard let current = viewSwitch, serial == nil || current.serial == serial else { return }
        withAnimation(.easeOut(duration: 0.12)) { viewSwitch = nil }
    }

    /// 过渡图可以拿掉了吗：去图标视图时落位即可；去画廊时要等大图（或出错卡片）出来，
    /// 用户在这期间换了图、又切回去了也不再等
    var viewSwitchCanFinish: Bool {
        guard let t = viewSwitch, t.landed else { return false }
        if t.toGrid { return true }
        guard !isGrid, current?.url == t.url else { return true }
        if failure != nil { return true }
        guard displayedItem?.url == t.url else { return false }
        if displayed != nil { return true }
        // 不知道原图尺寸时，过渡图落点就是按缩略图铺满的占位图的位置：占位图出来就能换
        return placeholder != nil && t.galleryPixelSize == nil
    }
}
