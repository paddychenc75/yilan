import AppKit
import Carbon.HIToolbox

/// 编辑模式的裁切框（设计稿 edit 02–05、「给开发的说明 › 裁切框」）：
/// 框外压暗 58%，边框 1pt 白 90% + 1pt 黑 25% 衬底，三分线 1pt 白 38%，
/// L 形角柄 20×20 粗 3、边柄 22×3（都贴在框外），把手可点范围 24×24
final class CropOverlayView: NSView {
    /// 编辑图（转完之后）的尺寸和上面的裁切框
    struct Config: Equatable {
        var editedSize: PixelSize
        var crop: PixelRect
        /// 要保持的宽 / 高（自由时 nil）
        var ratio: Double?
        /// 拉直的角度（度，spec E6）：照片绕图片中心转了这么多，压暗范围跟着转，拖框不能露出空角
        var angle: Double = 0
        /// 正在拉直：参考线加密成横 9 竖 6（spec E6-05）
        var fineGrid = false
    }

    var config: Config? {
        didSet {
            guard config != oldValue else { return }
            if config == nil { drag = nil }
            // 拖动中的框以自己算的为准，界面回传同样的值时不重画
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 图片在本视图里占的区域（已旋转、已缩放），由大图区每次布局后告诉它
    var imageFrame: CGRect = .zero {
        didSet {
            guard imageFrame != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onCropChanged: ((PixelRect) -> Void)?
    /// 平移放大的图片（点数）
    var onPan: ((CGFloat, CGFloat) -> Void)?
    /// 图片是否放大了（放大时拖框外 = 平移）
    var isZoomed: () -> Bool = { false }

    private struct Drag {
        let handle: CropHandle?   // nil = 平移
        let start: PixelRect
        let startPoint: CGPoint
        var lastPoint: CGPoint
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }

    /// 标题栏区域（高 56）不接鼠标，交给下面的大图区（拖窗口、双击缩放窗口）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard config != nil, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.y >= Theme.titleBarHeight else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 换算

    /// 每个像素对应多少点
    private var pointsPerPixel: CGFloat {
        guard let c = config, c.editedSize.width > 0 else { return 1 }
        return imageFrame.width / CGFloat(c.editedSize.width)
    }

    private var boxRect: CGRect {
        guard let c = config else { return .zero }
        let k = pointsPerPixel
        return CGRect(x: imageFrame.minX + CGFloat(c.crop.x) * k, y: imageFrame.minY + CGFloat(c.crop.y) * k,
                      width: CGFloat(c.crop.width) * k, height: CGFloat(c.crop.height) * k)
    }

    // MARK: - 画

    /// 转过 angle 度的图片范围（绕图片中心，正数顺时针；本视图 y 向下）
    private func rotatedImagePath(_ angle: Double) -> NSBezierPath {
        let t = CGFloat(angle) * .pi / 180, c = cos(t), s = sin(t)
        let o = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
        let hw = imageFrame.width / 2, hh = imageFrame.height / 2
        let path = NSBezierPath()
        for (i, (x, y)) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].enumerated() {
            let p = CGPoint(x: o.x + x * c - y * s, y: o.y + x * s + y * c)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let config, imageFrame.width > 0 else { return }
        let box = boxRect
        // 框外压暗：只在图片范围内（圆角 4）；拉直时是转过的照片范围
        NSGraphicsContext.saveGraphicsState()
        if config.angle == 0 {
            NSBezierPath(roundedRect: imageFrame, xRadius: 4, yRadius: 4).addClip()
        } else {
            rotatedImagePath(config.angle).addClip()
        }
        let dim = NSBezierPath(rect: config.angle == 0 ? imageFrame : bounds.union(imageFrame))
        dim.append(NSBezierPath(rect: box))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.58).setFill()
        dim.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 参考线：平时三分线；拖刻度尺时加密成横 9 竖 6（设计稿 96）
        let columns = config.fineGrid ? 9 : 3, rows = config.fineGrid ? 6 : 3
        NSColor.white.withAlphaComponent(config.fineGrid ? 0.28 : 0.38).setFill()
        for i in 1..<columns {
            let x = (box.minX + box.width * CGFloat(i) / CGFloat(columns)).rounded()
            NSRect(x: x, y: box.minY, width: 1, height: box.height).fill()
        }
        for i in 1..<rows {
            let y = (box.minY + box.height * CGFloat(i) / CGFloat(rows)).rounded()
            NSRect(x: box.minX, y: y, width: box.width, height: 1).fill()
        }
        // 边框：外面 1pt 黑 25% 衬底，里面 1pt 白 90%
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let outer = NSBezierPath(rect: box.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        outer.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let inner = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        inner.stroke()

        // 把手：白色，带一点投影
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        let t: CGFloat = 3, l: CGFloat = 20, e: CGFloat = 22
        let handles = NSBezierPath()
        // 四角 L 形，贴在框外
        for (cx, cy, sx, sy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                 (box.minX, box.maxY, 1.0, -1.0), (box.maxX, box.maxY, -1.0, -1.0)] {
            let ox = cx - (sx > 0 ? t : 0), oy = cy - (sy > 0 ? t : 0)
            let hx = sx > 0 ? ox : cx + t - l, vy = sy > 0 ? oy : cy + t - l
            handles.append(NSBezierPath(rect: NSRect(x: hx, y: sy > 0 ? oy : cy, width: l, height: t)))
            handles.append(NSBezierPath(rect: NSRect(x: sx > 0 ? ox : cx, y: vy, width: t, height: l)))
        }
        // 四边中点的短柄
        handles.append(NSBezierPath(roundedRect: NSRect(x: box.midX - e / 2, y: box.minY - t, width: e, height: t), xRadius: 1, yRadius: 1))
        handles.append(NSBezierPath(roundedRect: NSRect(x: box.midX - e / 2, y: box.maxY, width: e, height: t), xRadius: 1, yRadius: 1))
        handles.append(NSBezierPath(roundedRect: NSRect(x: box.minX - t, y: box.midY - e / 2, width: t, height: e), xRadius: 1, yRadius: 1))
        handles.append(NSBezierPath(roundedRect: NSRect(x: box.maxX, y: box.midY - e / 2, width: t, height: e), xRadius: 1, yRadius: 1))
        handles.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 把手

    /// 点到哪个把手：四角 24×24、四边 ±12、框内 = 移动
    func handle(at p: CGPoint) -> CropHandle? {
        let box = boxRect
        let r: CGFloat = 12
        let nearL = abs(p.x - box.minX) <= r, nearR = abs(p.x - box.maxX) <= r
        let nearT = abs(p.y - box.minY) <= r, nearB = abs(p.y - box.maxY) <= r
        let inX = p.x > box.minX - r && p.x < box.maxX + r, inY = p.y > box.minY - r && p.y < box.maxY + r
        if nearT && nearL { return .topLeft }
        if nearT && nearR { return .topRight }
        if nearB && nearL { return .bottomLeft }
        if nearB && nearR { return .bottomRight }
        if nearT && inX { return .top }
        if nearB && inX { return .bottom }
        if nearL && inY { return .left }
        if nearR && inY { return .right }
        if box.contains(p) { return .move }
        return nil
    }

    override func resetCursorRects() {
        guard config != nil, imageFrame.width > 0 else { return }
        let box = boxRect
        let r: CGFloat = 12
        addCursorRect(box.insetBy(dx: r, dy: r), cursor: .openHand)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x, y: y, width: w, height: h) }
        addCursorRect(rect(box.minX + r, box.minY - r, max(0, box.width - 2 * r), 2 * r), cursor: .frameResize(position: .top, directions: .all))
        addCursorRect(rect(box.minX + r, box.maxY - r, max(0, box.width - 2 * r), 2 * r), cursor: .frameResize(position: .bottom, directions: .all))
        addCursorRect(rect(box.minX - r, box.minY + r, 2 * r, max(0, box.height - 2 * r)), cursor: .frameResize(position: .left, directions: .all))
        addCursorRect(rect(box.maxX - r, box.minY + r, 2 * r, max(0, box.height - 2 * r)), cursor: .frameResize(position: .right, directions: .all))
        addCursorRect(rect(box.minX - r, box.minY - r, 2 * r, 2 * r), cursor: .frameResize(position: .topLeft, directions: .all))
        addCursorRect(rect(box.maxX - r, box.minY - r, 2 * r, 2 * r), cursor: .frameResize(position: .topRight, directions: .all))
        addCursorRect(rect(box.minX - r, box.maxY - r, 2 * r, 2 * r), cursor: .frameResize(position: .bottomLeft, directions: .all))
        addCursorRect(rect(box.maxX - r, box.maxY - r, 2 * r, 2 * r), cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    // MARK: - 鼠标

    private var spaceDown: Bool { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space)) }

    override func mouseDown(with event: NSEvent) {
        guard let c = config else { return }
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 { superview?.mouseDown(with: event); return }   // 双击仍是缩放
        // 按住空格、或放大后在框外拖：平移图片
        let h = spaceDown ? nil : handle(at: p)
        if h == nil && !(spaceDown || isZoomed()) { return }
        drag = Drag(handle: h, start: c.crop, startPoint: p, lastPoint: p)
        if h == .move || h == nil { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let c = config else { return }
        let p = convert(event.locationInWindow, from: nil)
        defer { d.lastPoint = p; drag = d }
        guard let handle = d.handle else {
            onPan?(p.x - d.lastPoint.x, p.y - d.lastPoint.y)
            return
        }
        let k = pointsPerPixel
        guard k > 0 else { return }
        // 最小 64pt，同时不小于 16 像素
        let minSide = max(16, Int((64 / k).rounded(.up)))
        var ratio = c.ratio
        // 自由比例下按住 ⇧ 拖角：锁定开始拖动时的比例（spec ED-15）
        if ratio == nil, handle.isCorner, event.modifierFlags.contains(.shift) {
            ratio = Double(d.start.width) / Double(max(1, d.start.height))
        }
        // 拉直过的照片：拖框不能露出空角（spec E6-04）；角度为 0 时和原来完全一样
        let rect = StraightenMath.drag(handle, start: d.start, dx: Double((p.x - d.startPoint.x) / k),
                                       dy: Double((p.y - d.startPoint.y) / k), bounds: c.editedSize, ratio: ratio,
                                       minSide: minSide, angle: c.angle)
        guard rect != c.crop else { return }
        config?.crop = rect
        onCropChanged?(rect)
    }

    override func mouseUp(with event: NSEvent) {
        if let d = drag, d.handle == .move || d.handle == nil { NSCursor.pop() }
        drag = nil
        window?.invalidateCursorRects(for: self)
    }
}
