import AppKit
import QuartzCore
import SwiftUI

/// 大图区（AppKit 实现）：适应窗口、缩放、拖动、滚轮切换、GIF 动画、切换时淡入淡出
final class ImageStageView: NSView {
    struct Content {
        let url: URL
        let image: CGImage
        /// 原图像素尺寸（缩放比例以它为准）
        let pixelSize: CGSize
        let frames: [CGImage]
        let frameDurations: [Double]
        /// 是否允许“适应窗口”时放大到超过原始像素（矢量图、占位缩略图可以）
        let allowsUpscale: Bool
        /// 同一个文件换了更清晰的版本（RAW 预览 → 完整解码、屏幕尺寸 → 原始分辨率）
        let identity: ObjectIdentifier
    }

    var onNavigate: ((Int) -> Void)?
    var onZoomChanged: ((ZoomState?) -> Void)?
    var onNeedsFullResolution: (() -> Void)?
    /// 所在屏幕的长边物理像素变了（换了屏幕、缩放比例变了），参数是新的像素数
    var onDisplayChanged: ((Int) -> Void)?

    /// 适应窗口时图片可以占用的区域（距窗口四边）
    var fitInsets = NSEdgeInsets(top: 64, left: 32, bottom: 132, right: 32) {
        didSet {
            guard !NSEdgeInsetsEqual(oldValue, fitInsets) else { return }
            // 信息面板开关时图片和面板一起移动（设计稿：0.25 秒）
            layoutImage(animated: window != nil && scale == nil, duration: 0.25)
        }
    }

    /// 显示旋转：顺时针 90° 的倍数（只影响显示）
    var rotation = 0 {
        didSet {
            guard oldValue != rotation else { return }
            // 旋转后回到适应窗口
            scale = nil
            layoutImage(animated: window != nil && animatesRotation)
        }
    }

    /// 编辑模式的拉直角度（度，正数顺时针，spec E6）：照片绕图片中心再转这么多；只影响显示
    var straighten: Double = 0 {
        didSet {
            guard oldValue != straighten else { return }
            layoutImage(animated: false)
        }
    }

    /// 换图的同时改方向（原地改写的文件换上新内容）时不播放转动动画
    var animatesRotation = true

    /// 这次要换上的内容和现在显示的不是同一张
    func isNewContent(_ new: Content?) -> Bool {
        content?.identity != new?.identity || content?.url != new?.url
    }

    private let container = CALayer()
    private let imageLayer = CALayer()
    /// 编辑模式的裁切框（不编辑时隐藏）
    let cropOverlay = CropOverlayView(frame: .zero)

    /// 编辑模式：裁切框的设置；nil 表示在浏览
    var cropConfig: CropOverlayView.Config? {
        didSet {
            cropOverlay.config = cropConfig
            cropOverlay.isHidden = cropConfig == nil
        }
    }
    private var isEditing: Bool { cropConfig != nil }
    /// 视频画面层（AVPlayerLayer），盖在第一帧静帧上面；还没出画面时透出下面的静帧
    private var videoLayer: CALayer?
    private var content: Content?
    /// 每个原图像素对应多少点（100% = 1 像素对应 1 点，与“预览”一致）；nil 表示适应窗口
    private var scale: CGFloat?
    /// 放大时图片中心在视图里的位置
    private var zoomCenter: CGPoint = .zero
    private var reportedZoom: ZoomState?

    // 滚轮切换
    private var scrollAccumulator: CGFloat = 0
    private var scrollGestureFired = false
    private var lastWheelNavigation: TimeInterval = 0
    private var wheelMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var lastSmoothEvent: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true

        // 设计稿 .photo：圆角 4，阴影 0 18 60 黑 55%
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.55
        container.shadowRadius = 30
        container.shadowOffset = CGSize(width: 0, height: 18)
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 4
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        container.addSublayer(imageLayer)
        layer?.addSublayer(container)
        cropOverlay.isHidden = true
        cropOverlay.onPan = { [weak self] dx, dy in self?.pan(dx: dx, dy: dy) }
        cropOverlay.isZoomed = { [weak self] in self?.scale != nil }
        addSubview(cropOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        cropOverlay.frame = bounds
        layoutImage(animated: false)
    }

    /// 画面上面盖着的控件（视频的大播放按钮、出错提示、左右箭头等）会把滚轮吃掉，
    /// 导致滚到视频或坏文件就卡住。这里在窗口层面接住滚轮：只要鼠标在画面区域里，
    /// 就交给本视图处理；缩略图条这种自己能滚动的区域除外。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let window else { return }
        // 窗口拖到另一块屏幕：两块屏幕缩放比例相同时不会触发 viewDidChangeBackingProperties，单独监听
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportDisplay() }
        }
        reportDisplay()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let content = window.contentView, let frameView = content.superview else { return event }
            guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let hit = content.hitTest(frameView.convert(event.locationInWindow, from: nil))
            // 正常情况：事件本来就会送到这里
            if let hit, hit === self || hit.isDescendant(of: self) { return event }
            // 缩略图条等可滚动区域：让它自己滚
            if hit?.enclosingScrollView != nil { return event }
            self.scrollWheel(with: event)
            return nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = backingScale
        layoutImage(animated: false)
        reportDisplay()
    }

    private func reportDisplay() {
        guard let screen = window?.screen else { return }
        let pixels = BrowserModel.maxPixel(for: screen)
        // 可能在视图更新过程中被调用，推迟到下一轮再改状态
        DispatchQueue.main.async { [weak self] in self?.onDisplayChanged?(pixels) }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: - 内容

    /// fade 为 false 时直接换上，不交叉淡入（换图的同时方向也变了：淡出的旧图会按新方向画出来，看上去转了一下）
    func setContent(_ new: Content?, fade allowsFade: Bool = true) {
        let old = content
        guard old?.identity != new?.identity || old?.url != new?.url else { return }
        content = new
        if new == nil, reportedZoom != nil {
            reportedZoom = nil
            onZoomChanged?(nil)
        }
        let sameFile = old?.url == new?.url
        if !sameFile { scale = nil }

        // 切换图片：交叉淡入 0.18s；同一文件换成更清晰的版本：0.3s
        if allowsFade, old != nil, new != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = sameFile ? 0.3 : 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageLayer.add(fade, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.removeAnimation(forKey: "gif")
        imageLayer.contents = new?.image
        container.isHidden = new == nil
        if let new, new.frames.count > 1 { startGIF(new) }
        CATransaction.commit()
        layoutImage(animated: false)
        if let new { Perf.displayed(new.url) }
    }

    /// 挂上或取下视频画面层
    func setVideoLayer(_ layer: CALayer?) {
        guard layer !== videoLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.removeFromSuperlayer()
        videoLayer = layer
        if let layer {
            layer.masksToBounds = true
            layer.cornerRadius = imageLayer.cornerRadius
            layer.frame = imageLayer.frame
            container.addSublayer(layer)
        }
        CATransaction.commit()
    }

    private func startGIF(_ content: Content) {
        let total = content.frameDurations.reduce(0, +)
        guard total > 0 else { return }
        var times: [NSNumber] = []
        var t = 0.0
        for d in content.frameDurations {
            times.append(NSNumber(value: t / total))
            t += d
        }
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = content.frames
        anim.keyTimes = times
        anim.calculationMode = .discrete
        anim.duration = total
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        imageLayer.add(anim, forKey: "gif")
    }

    // MARK: - 布局

    private var fitArea: CGRect {
        CGRect(x: fitInsets.left, y: fitInsets.top,
               width: max(1, bounds.width - fitInsets.left - fitInsets.right),
               height: max(1, bounds.height - fitInsets.top - fitInsets.bottom))
    }

    /// 转 90° / 270° 时宽高互换
    private var isQuarterTurned: Bool { rotation % 2 != 0 }

    /// 旋转后在屏幕上占的像素尺寸
    private var rotatedPixelSize: CGSize {
        guard let c = content else { return .zero }
        return isQuarterTurned ? CGSize(width: c.pixelSize.height, height: c.pixelSize.width) : c.pixelSize
    }

    /// 适应窗口的比例；位图不会放大超过 100%
    private var fitScale: CGFloat {
        let size = rotatedPixelSize
        guard let c = content, size.width > 0, size.height > 0 else { return 1 }
        let area = fitArea
        let s = min(area.width / size.width, area.height / size.height)
        return c.allowsUpscale ? s : min(s, 1)
    }

    private var currentScale: CGFloat { scale ?? fitScale }

    private func layoutImage(animated: Bool, duration: CFTimeInterval = 0.2) {
        guard let c = content else { return }
        let s = currentScale
        let rotated = rotatedPixelSize
        // size：屏幕上占的区域（已旋转）；图层本身按未旋转的尺寸摆放，再整体转过去
        let size = CGSize(width: rotated.width * s, height: rotated.height * s)
        let unrotated = CGSize(width: c.pixelSize.width * s, height: c.pixelSize.height * s)
        let area = fitArea
        var frame: CGRect
        if scale == nil {
            frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            // 放大时 container.frame 已经是旋转后的外框，zoomCenter 用它的中心
            frame = CGRect(x: zoomCenter.x - size.width / 2, y: zoomCenter.y - size.height / 2, width: size.width, height: size.height)
            // 比窗口大：边缘不能拉进窗口里；比窗口小：居中在图片区
            if size.width > bounds.width {
                frame.origin.x = min(0, max(bounds.width - size.width, frame.origin.x))
            } else {
                frame.origin.x = area.midX - size.width / 2
            }
            if size.height > bounds.height {
                frame.origin.y = min(0, max(bounds.height - size.height, frame.origin.y))
            } else {
                frame.origin.y = area.midY - size.height / 2
            }
            zoomCenter = CGPoint(x: frame.midX, y: frame.midY)
        }
        frame = frame.integral
        cropOverlay.imageFrame = frame

        CATransaction.begin()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let bounds = CGRect(origin: .zero, size: CGSize(width: unrotated.width.rounded(), height: unrotated.height.rounded()))
        // bounds / position 不受 transform 影响，直接设置即可
        container.bounds = bounds
        container.position = CGPoint(x: frame.midX, y: frame.midY)
        // 视图是翻转坐标（y 向下），正角度即顺时针
        container.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 2 + CGFloat(straighten) * .pi / 180))
        imageLayer.frame = container.bounds
        videoLayer?.frame = container.bounds
        let isFit = scale == nil
        imageLayer.cornerRadius = isFit ? 4 : 0
        videoLayer?.cornerRadius = isFit ? 4 : 0
        container.shadowOpacity = isFit ? 0.55 : 0
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        // 放大到每个像素 3 个物理像素以上时用最近邻，方便看清像素
        imageLayer.magnificationFilter = s * backingScale > 3 ? .nearest : .linear
        imageLayer.contentsScale = backingScale
        CATransaction.commit()

        // 顶部缩放控件：适应窗口时也显示实际比例（spec E1-02）；最小是适应窗口，最大 3200%（PD-02）
        let state = ZoomState(percent: max(1, Int((s * 100).rounded())), isFit: isFit,
                              canZoomIn: s < maxScale * 0.999, canZoomOut: !isFit)
        if state != reportedZoom {
            reportedZoom = state
            onZoomChanged?(state)
        }
        // 显示尺寸超过了解码尺寸，需要原始分辨率
        let shownPixels = unrotated.width * backingScale
        if !isFit, shownPixels > CGFloat(c.image.width) * 1.05 {
            DispatchQueue.main.async { [weak self] in self?.onNeedsFullResolution?() }
        }
    }

    // MARK: - 缩放

    private var maxScale: CGFloat { 32 }   // 最大 3200%

    private func zoom(to newScale: CGFloat, around point: CGPoint, animated: Bool) {
        guard content != nil else { return }
        let fit = fitScale
        if newScale <= fit * 1.001 {
            scale = nil
            layoutImage(animated: animated)
            return
        }
        let s0 = currentScale
        let s1 = min(newScale, maxScale)
        let c0 = scale == nil ? CGPoint(x: container.frame.midX, y: container.frame.midY) : zoomCenter
        zoomCenter = CGPoint(x: point.x + (c0.x - point.x) * s1 / s0, y: point.y + (c0.y - point.y) * s1 / s0)
        scale = s1
        layoutImage(animated: animated)
    }

    func apply(_ action: ZoomCommand.Action) {
        let center = CGPoint(x: fitArea.midX, y: fitArea.midY)
        switch action {
        case .fit: zoom(to: 0, around: center, animated: true)
        case .actualSize: zoom(to: 1, around: center, animated: true)
        case .percent200: zoom(to: 2, around: center, animated: true)
        case .zoomIn: zoom(to: currentScale * 1.25, around: center, animated: true)
        case .zoomOut: zoom(to: currentScale / 1.25, around: center, animated: true)
        case .toggle: toggleZoom(at: center)
        }
    }

    private func toggleZoom(at point: CGPoint) {
        if scale == nil {
            // 小图本来就是 100%，双击放大到 200%
            let actual: CGFloat = 1
            zoom(to: fitScale >= actual * 0.999 ? fitScale * 2 : actual, around: point, animated: true)
        } else {
            zoom(to: 0, around: point, animated: true)
        }
    }

    // MARK: - 鼠标和触控板

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // ⌃ 是主修饰键；⌘ 也保留，兼容老习惯
        let modifier = !event.modifierFlags.intersection([.control, .command]).isEmpty
        if AppSettings.shared.scrollShouldZoom(modifierPressed: modifier) {
            // 缩放（默认是 ⌃ + 滚轮；设置里选了“缩放”时不按 ⌃ 也缩放）
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(to: currentScale * exp(dy), around: point, animated: false)
            return
        }
        if scale != nil {
            // 放大状态：滚动 = 拖动查看
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            zoomCenter.x += event.scrollingDeltaX * k
            zoomCenter.y += event.scrollingDeltaY * k
            layoutImage(animated: false)
            return
        }
        // 编辑中滚轮不切图（spec ED-08）
        if !isEditing { navigate(with: event) }
    }

    /// 平移放大的图片（编辑时按住空格拖、或在框外拖）
    func pan(dx: CGFloat, dy: CGFloat) {
        guard scale != nil else { return }
        zoomCenter.x += dx
        zoomCenter.y += dy
        layoutImage(animated: false)
    }

    /// 滚轮切换：鼠标滚轮每一格切一张；触控板一次手势只切一张，惯性部分忽略
    private func navigate(with event: NSEvent) {
        if !event.momentumPhase.isEmpty { return }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let now = ProcessInfo.processInfo.systemUptime
        if event.hasPreciseScrollingDeltas && event.phase.isEmpty {
            // “平滑滚动”鼠标（罗技等、或装了平滑滚动工具）：增量连续但没有手势开始/结束，
            // 按停顿分段：停 0.25 秒以上算新的一次；累计够 30 切一张，两次切换至少隔 0.25 秒
            if now - lastSmoothEvent > 0.25 { scrollAccumulator = 0 }
            lastSmoothEvent = now
            scrollAccumulator += delta
            guard abs(scrollAccumulator) > 30, now - lastWheelNavigation > 0.25 else { return }
            lastWheelNavigation = now
            onNavigate?(scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator = 0
        } else if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) {
                scrollAccumulator = 0
                scrollGestureFired = false
            }
            guard !scrollGestureFired else { return }
            scrollAccumulator += delta
            if abs(scrollAccumulator) > 24 {
                scrollGestureFired = true
                onNavigate?(scrollAccumulator > 0 ? -1 : 1)
            }
        } else {
            guard delta != 0 else { return }
            guard now - lastWheelNavigation > 0.06 else { return }
            lastWheelNavigation = now
            onNavigate?(delta > 0 ? -1 : 1)   // 向上滚 = 上一张
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(to: currentScale * (1 + event.magnification), around: point, animated: false)
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: convert(event.locationInWindow, from: nil))
    }

    /// 点在顶部标题栏区域（高度同设计稿标题栏）里：全屏时没有标题栏，不算
    private func isInTitleBarZone(_ event: NSEvent) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen),
              let content = window.contentView else { return false }
        return event.locationInWindow.y >= content.bounds.height - Theme.titleBarHeight
    }

    /// 双击标题栏：按系统设置（桌面与程序坞 › 连按窗口标题栏）缩放、填充、最小化窗口或什么都不做
    private func performTitleBarDoubleClick() {
        guard let window else { return }
        switch TitleBarDoubleClick.action() {
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        case .zoom: window.performZoom(nil)
        case .fill: fill(window)
        }
    }

    /// 填充前的窗口位置：再双击一次时恢复
    private var frameBeforeFill: NSRect?

    /// “填充”：铺满所在屏幕的可用区域（不进全屏）；已经铺满时恢复原来的大小
    private func fill(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let target = screen.visibleFrame
        if TitleBarDoubleClick.isFilled(window.frame, in: target), let previous = frameBeforeFill {
            frameBeforeFill = nil
            window.setFrame(previous, display: true, animate: true)
        } else {
            frameBeforeFill = window.frame
            window.setFrame(target, display: true, animate: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 标题栏区域归窗口：双击缩放窗口、拖动移动窗口，不碰图片的缩放
        if isInTitleBarZone(event) {
            if event.clickCount == 2 { performTitleBarDoubleClick() }
            else if event.clickCount == 1 { window?.performDrag(with: event) }
            return
        }
        if event.clickCount == 2 {
            toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        // 适应窗口时拖动大图 = 拖动窗口（编辑中不拖窗口）
        if scale == nil, event.clickCount == 1, !isEditing { window?.performDrag(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard scale != nil else { return }
        zoomCenter.x += event.deltaX
        zoomCenter.y += event.deltaY
        layoutImage(animated: false)
    }

    override func resetCursorRects() {
        if scale != nil, !isEditing { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// SwiftUI 包装
struct ImageStage: NSViewRepresentable {
    let content: ImageStageView.Content?
    let insets: NSEdgeInsets
    let zoomCommand: ZoomCommand?
    var rotation = 0
    var videoLayer: CALayer?
    let onNavigate: (Int) -> Void
    let onZoomChanged: (ZoomState?) -> Void
    let onNeedsFullResolution: () -> Void
    var onDisplayChanged: (Int) -> Void = { _ in }
    /// 编辑模式的裁切框；nil 表示在浏览
    var crop: CropOverlayView.Config? = nil
    /// 编辑模式的拉直角度（度）
    var straighten: Double = 0
    var onCropChanged: (PixelRect) -> Void = { _ in }

    final class Coordinator {
        var lastZoomSerial: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageStageView {
        let view = ImageStageView(frame: .zero)
        context.coordinator.lastZoomSerial = zoomCommand?.serial
        return view
    }

    func updateNSView(_ view: ImageStageView, context: Context) {
        view.onNavigate = onNavigate
        view.onNeedsFullResolution = onNeedsFullResolution
        view.onDisplayChanged = onDisplayChanged
        view.onZoomChanged = { percent in
            // 布局过程中回调，推迟到下一轮再改状态，避免在视图更新中修改状态
            DispatchQueue.main.async { onZoomChanged(percent) }
        }
        // 换图和改方向同时发生（保存旋转后新内容换上按旧方向暂留的旧画面）：两者看上去一样，
        // 方向直接跳到位、图直接换，不转、不淡入淡出
        let swapsWithTurn = view.isNewContent(content) && view.rotation != rotation
        if swapsWithTurn {
            view.animatesRotation = false
            view.rotation = rotation
            view.animatesRotation = true
        }
        view.setContent(content, fade: !swapsWithTurn)
        view.setVideoLayer(videoLayer)
        view.cropOverlay.onCropChanged = onCropChanged
        view.rotation = rotation
        view.straighten = straighten
        view.cropConfig = crop
        view.fitInsets = insets
        if let cmd = zoomCommand, cmd.serial != context.coordinator.lastZoomSerial {
            context.coordinator.lastZoomSerial = cmd.serial
            view.apply(cmd.action)
        }
        view.window?.invalidateCursorRects(for: view)
    }
}

/// 双击标题栏要做什么：读系统设置“连按窗口标题栏以”
enum TitleBarDoubleClick: Equatable {
    case zoom, fill, minimize, none

    /// 系统存的值：Maximize（缩放）、Fill（填充）、Minimize（最小化）、None（不执行任何操作）；
    /// 没设过时系统默认是“缩放”
    static func action(defaults: UserDefaults = .standard) -> TitleBarDoubleClick {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case "Fill": return .fill
        default: return .zoom
        }
    }

    /// 窗口是否已经铺满可用区域（允许 2 点误差）
    static func isFilled(_ frame: NSRect, in target: NSRect) -> Bool {
        abs(frame.minX - target.minX) <= 2 && abs(frame.minY - target.minY) <= 2
            && abs(frame.width - target.width) <= 2 && abs(frame.height - target.height) <= 2
    }
}
