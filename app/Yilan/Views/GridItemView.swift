import AppKit

/// 图标视图里一个格子的内容（设计稿 11，spec V1-02 至 V1-07）：4:3 的缩略图区 + 一行文件名。
/// 用 AppKit 直接画：几千张快速滚动时比每格一个 SwiftUI 宿主视图轻得多
final class GridCellView: NSView {
    /// 这个格子现在显示的文件
    private(set) var item: MediaItem?
    private var metrics = GridMetrics(size: .default, width: 1280)
    private var isSelectedCell = false
    private var isHovered = false
    private var isDimmed = false
    private var rating = 0
    private var thumbnail: Thumbnail?
    private var loadTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?

    /// 点了这一格：文件、事件（看修饰键和点击次数）
    var onMouseDown: ((MediaItem, NSEvent) -> Void)?
    /// 在这一格上按下后没有拖动就松手
    var onMouseUp: ((MediaItem, NSEvent) -> Void)?
    /// 在这一格上点了右键
    var onContextClick: ((MediaItem, NSEvent) -> Void)?
    /// 在缩略图上按住拖动（拖出去，spec X8）
    var onDrag: ((MediaItem, NSEvent) -> Void)?

    private let boxLayer = CALayer()
    private let shadowLayer = CALayer()
    private let thumbLayer = CALayer()
    private let nameBackground = CALayer()
    private let nameField = NSTextField(labelWithString: "")
    private let ratingBadge = BadgeLabel()
    private let kindBadge = BadgeLabel()
    private let warning = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        boxLayer.cornerRadius = 12
        boxLayer.cornerCurve = .continuous
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.5
        shadowLayer.shadowRadius = 7
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        shadowLayer.cornerRadius = 5
        thumbLayer.cornerRadius = 5
        thumbLayer.masksToBounds = true
        thumbLayer.contentsGravity = .resizeAspectFill
        thumbLayer.backgroundColor = NSColor(red: 28 / 255, green: 29 / 255, blue: 33 / 255, alpha: 1).cgColor
        thumbLayer.minificationFilter = .trilinear
        nameBackground.cornerRadius = 6
        nameBackground.cornerCurve = .continuous
        for l in [boxLayer, shadowLayer, thumbLayer, nameBackground] { layer?.addSublayer(l) }
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.textColor = NSColor.white.withAlphaComponent(0.86)
        nameField.backgroundColor = .clear
        addSubview(nameField)
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        warning.contentTintColor = NSColor(red: 1, green: 214 / 255, blue: 10 / 255, alpha: 1)
        warning.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        warning.isHidden = true
        addSubview(warning)
        addSubview(ratingBadge)
        addSubview(kindBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - 内容

    func configure(item: MediaItem, metrics: GridMetrics, selected: Bool, rating: Int, dimmed: Bool) {
        let changedFile = self.item != item
        self.item = item
        self.metrics = metrics
        self.isSelectedCell = selected
        self.rating = rating
        self.isDimmed = dimmed
        nameField.stringValue = item.name
        nameField.font = .systemFont(ofSize: metrics.size == .xs ? 11 : metrics.size >= .l ? 12.5 : 12,
                                     weight: selected ? .medium : .regular)
        toolTip = item.name
        if changedFile {
            thumbnail = nil
            loadThumbnail()
        }
        needsLayout = true
        applyState()
        setAccessibilityLabel(item.name)
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelectedCell else { return }
        isSelectedCell = selected
        nameField.font = .systemFont(ofSize: nameField.font?.pointSize ?? 12, weight: selected ? .medium : .regular)
        applyState()
        needsLayout = true
    }

    func setRating(_ value: Int) {
        guard value != rating else { return }
        rating = value
        needsLayout = true
    }

    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        applyState()
    }

    /// 用哪个缩略图缓存：最大两档用大的（spec V5-04）
    private var store: ThumbnailStore { metrics.size.usesLargeThumbnails ? .large : .shared }

    private func loadThumbnail() {
        loadTask?.cancel()
        guard let item else { return }
        if let hit = store.cached(item) {
            thumbnail = hit
            return
        }
        // 大缩略图还没好时先用小的垫着，不显示占位块
        if metrics.size.usesLargeThumbnails, let small = ThumbnailStore.shared.cached(item) { thumbnail = small }
        let store = self.store
        loadTask = Task { [weak self] in
            guard let thumb = await store.thumbnail(for: item), !Task.isCancelled else { return }
            guard let self, self.item == item else { return }
            self.thumbnail = thumb
            self.needsLayout = true
        }
    }

    /// 缩略图大小那一档变了：换一份缩略图
    func reloadThumbnailForSize(_ metrics: GridMetrics) {
        let wasLarge = self.metrics.size.usesLargeThumbnails
        self.metrics = metrics
        if wasLarge != metrics.size.usesLargeThumbnails { loadThumbnail() }
        needsLayout = true
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoading()
        item = nil
        thumbnail = nil
        isHovered = false
    }

    // MARK: - 布局

    /// 缩略图在格子里的位置
    private var thumbFrame: CGRect {
        let image = thumbnail?.image
        let aspect: CGFloat = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        let size = metrics.thumbnailSize(aspect: aspect)
        let box = CGRect(x: GridMetrics.boxInset, y: GridMetrics.boxInset, width: metrics.size.box, height: metrics.size.boxHeight)
        return CGRect(x: (box.midX - size.width / 2).rounded(), y: (box.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    private var nameFrame: CGRect {
        let top = metrics.size.boxHeight + GridMetrics.boxInset * 2 + GridMetrics.nameGap
        // 标签控件自己左右各有 2 点内边距，多留一点，不然没到格子宽度就开始省略
        let wanted = min(bounds.width, ceil(nameField.attributedStringValue.size().width) + 20)
        return CGRect(x: ((bounds.width - wanted) / 2).rounded(), y: top, width: wanted, height: GridMetrics.nameHeight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: metrics.size.boxHeight + GridMetrics.boxInset * 2)
        let t = thumbFrame
        thumbLayer.frame = t
        shadowLayer.frame = t
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: t.size), cornerWidth: 5, cornerHeight: 5, transform: nil)
        let failed = thumbnail?.failed == true
        thumbLayer.contents = thumbnail?.image
        thumbLayer.backgroundColor = (failed ? NSColor(red: 35 / 255, green: 36 / 255, blue: 40 / 255, alpha: 1)
                                             : NSColor(red: 28 / 255, green: 29 / 255, blue: 33 / 255, alpha: 1)).cgColor
        shadowLayer.isHidden = thumbnail == nil
        warning.isHidden = !failed
        warning.frame = CGRect(x: t.midX - 12, y: t.midY - 12, width: 24, height: 24)
        let n = nameFrame
        nameBackground.frame = n
        nameField.frame = n.insetBy(dx: 5, dy: 0).offsetBy(dx: 0, dy: 2)
        layoutBadges(in: t, failed: failed)
        CATransaction.commit()
    }

    private func layoutBadges(in t: CGRect, failed: Bool) {
        // 左上角星标（有星且没出错时）
        if rating > 0, !failed {
            ratingBadge.setRating(rating)
            ratingBadge.isHidden = false
            let s = ratingBadge.fittingSize
            ratingBadge.frame = CGRect(x: t.minX + 4, y: t.minY + 4, width: s.width, height: s.height)
        } else {
            ratingBadge.isHidden = true
        }
        // 右下角 RAW / GIF / 视频时长
        var text: String?
        if let item, thumbnail?.image != nil {
            switch item.format {
            case .raw: text = "RAW"
            case .gif: text = "GIF"
            case .video: text = thumbnail?.duration.map { "▶ " + Formatting.duration($0) }
            default: break
            }
        }
        if let text, t.width >= 56 {
            kindBadge.setText(text)
            kindBadge.isHidden = false
            let s = kindBadge.fittingSize
            kindBadge.frame = CGRect(x: t.maxX - 4 - s.width, y: t.maxY - 4 - s.height, width: s.width, height: s.height)
        } else {
            kindBadge.isHidden = true
        }
    }

    /// 选中、悬停、拖出时变淡的样子（设计稿第 07 章「选中样式」）
    private func applyState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accent = NSColor.controlAccentColor
        boxLayer.backgroundColor = NSColor.white.withAlphaComponent(isSelectedCell ? 0.15 : isHovered ? 0.06 : 0).cgColor
        thumbLayer.borderColor = accent.cgColor
        thumbLayer.borderWidth = isSelectedCell ? 2.5 : 0
        nameBackground.backgroundColor = isSelectedCell ? accent.cgColor : NSColor.clear.cgColor
        nameField.textColor = isSelectedCell ? .white : NSColor.white.withAlphaComponent(0.86)
        alphaValue = isDimmed ? 0.4 : 1
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyState()   // 系统强调色变了
    }

    // MARK: - 鼠标

    /// 只有缩略图本身和文件名算「项目」，格子里其余留白算空白（spec X1-07）：点在留白上会落到背景，可以起框
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return thumbFrame.insetBy(dx: -2, dy: -2).contains(local) || nameFrame.contains(local) ? self : nil
    }

    private var mouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if event.modifierFlags.contains(.control) {
            onContextClick?(item, event)
            return
        }
        mouseDownEvent = event
        onMouseDown?(item, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }   // 拖动超过 4 点才算（spec X8-01）
        mouseDownEvent = nil
        onDrag?(item, down)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil, let item { onMouseUp?(item, event) }
        mouseDownEvent = nil
    }

    /// 这块区域（格子自己的坐标）碰没碰到缩略图或文件名（框选用，spec X1-08）
    func touches(_ rect: CGRect) -> Bool { thumbFrame.intersects(rect) || nameFrame.intersects(rect) }

    override func rightMouseDown(with event: NSEvent) {
        guard let item else { return }
        onContextClick?(item, event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyState()
    }
}

/// 缩略图上的小角标（和缩略图栏里的一样）：高 15 / 16，圆角 5，黑底白字
final class BadgeLabel: NSView {
    private let field = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        field.font = .systemFont(ofSize: 9.5, weight: .semibold)
        field.textColor = .white
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setText(_ text: String) {
        field.font = .systemFont(ofSize: 9.5, weight: .semibold)
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.white, .font: field.font!])
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        needsLayout = true
    }

    /// 星标：品牌暖黄的星 + 白色数字，底更深一些（设计稿 .bdg.s）
    func setRating(_ rating: Int) {
        let sun = NSColor(red: 1, green: 226 / 255, blue: 160 / 255, alpha: 1)
        let text = NSMutableAttributedString(string: "★", attributes: [.foregroundColor: sun, .font: NSFont.systemFont(ofSize: 9.5, weight: .bold)])
        text.append(NSAttributedString(string: " \(rating)", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10.5, weight: .bold)]))
        field.attributedStringValue = text
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let s = field.attributedStringValue.size()
        return NSSize(width: ceil(s.width) + 12, height: 16)
    }

    override func layout() {
        super.layout()
        let s = field.attributedStringValue.size()
        field.frame = CGRect(x: 4, y: ((bounds.height - s.height) / 2).rounded(.down), width: bounds.width - 6, height: ceil(s.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 集合视图的一项
final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridItem")

    override func loadView() { view = GridCellView() }

    var cell: GridCellView { view as! GridCellView }

    override func prepareForReuse() {
        super.prepareForReuse()
        cell.prepareForReuse()
    }
}
