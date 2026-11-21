import AppKit
import SwiftUI

/// 图标视图的排列（spec V1-01、V1-08）：等大的格子，从左到右、从上到下。位置全由 GridMetrics 算出来，
/// 和键盘移动用的是同一套列数
final class GridLayout: NSCollectionViewLayout {
    var metrics = GridMetrics(size: .default, width: 1280) { didSet { if metrics != oldValue { invalidateLayout() } } }
    var count = 0

    func frame(at index: Int) -> CGRect {
        let cols = metrics.columns
        let row = index / cols, col = index % cols
        return CGRect(x: GridMetrics.sideMargin + CGFloat(col) * (metrics.cellWidth + metrics.columnGap),
                      y: GridMetrics.topInset + CGFloat(row) * metrics.rowStride,
                      width: metrics.cellWidth, height: metrics.cellHeight)
    }

    var rows: Int { count == 0 ? 0 : (count - 1) / metrics.columns + 1 }

    override var collectionViewContentSize: NSSize {
        let height = GridMetrics.topInset + CGFloat(rows) * metrics.rowStride - (rows > 0 ? GridMetrics.rowGap : 0) + GridMetrics.bottomInset
        return NSSize(width: metrics.width, height: max(height, 1))
    }

    /// 和这块区域相交的格子
    func indexes(in rect: CGRect) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let cols = metrics.columns
        let first = max(0, Int(floor((rect.minY - GridMetrics.topInset) / metrics.rowStride)))
        let last = min(rows - 1, Int(floor((rect.maxY - GridMetrics.topInset) / metrics.rowStride)))
        guard first <= last else { return 0..<0 }
        return (first * cols)..<min(count, (last + 1) * cols)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        indexes(in: rect).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item < count else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        a.frame = frame(at: indexPath.item)
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }
}

/// 网格本体。选中由浏览模型说了算（技术方案 3.2）：这里不用系统自带的选择，只把点按、框选报给模型
final class GridCollectionNSView: NSCollectionView {
    weak var coordinator: GridCollection.Coordinator?
    private let band = CALayer()

    /// 按键全部由窗口层面的监听交给浏览模型（spec 第 9 节），这里不接
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return }
        if event.modifierFlags.contains(.control) {
            coordinator.blankContextClick(event)
            return
        }
        coordinator.trackBand(from: event, in: self)
    }

    override func rightMouseDown(with event: NSEvent) { coordinator?.blankContextClick(event) }

    func showBand(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            if band.superlayer == nil {
                band.borderWidth = 1
                band.cornerRadius = 2
                band.zPosition = 100
                layer?.addSublayer(band)
            }
            band.borderColor = NSColor.controlAccentColor.cgColor
            band.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            band.frame = rect
        } else {
            band.removeFromSuperlayer()
        }
        CATransaction.commit()
    }
}

/// 图标视图的网格（设计稿 11）：NSCollectionView 包一层
struct GridCollection: NSViewRepresentable {
    let model: BrowserModel
    let items: [MediaItem]
    let selection: Set<URL>
    /// 要显示星标的评分；评星关掉时传空
    let ratings: [URL: Int]
    let size: GridSize
    let viewport: CGSize
    let scrollRequest: GridScrollRequest?
    /// 正在拖出去的文件：变淡（spec X8）
    var dimmed: Set<URL> = []

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerInsets = NSEdgeInsets(top: 60, left: 0, bottom: 64, right: 0)
        let view = GridCollectionNSView()
        view.coordinator = context.coordinator
        view.collectionViewLayout = context.coordinator.layout
        view.backgroundColors = [.clear]
        view.isSelectable = false
        view.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.attach(view, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: BrowserModel
        let layout = GridLayout()
        private weak var view: GridCollectionNSView?
        private weak var scroll: NSScrollView?
        private var items: [MediaItem] = []
        private var selection: Set<URL> = []
        private var ratings: [URL: Int] = [:]
        private var dimmed: Set<URL> = []
        private var lastScrollSerial: Int?
        private var lastHeight: CGFloat = 0
        private var boundsObserver: NSObjectProtocol?
        /// 在多选中的一张上按下、没带修饰键：松手时才收成只选它（按住可以拖出去）
        private var collapseOnMouseUp: URL?

        init(model: BrowserModel) { self.model = model }

        func attach(_ view: GridCollectionNSView, scroll: NSScrollView) {
            self.view = view
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisible() }
            }
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
        }

        // MARK: 跟上模型

        func update(_ p: GridCollection) {
            guard let view else { return }
            let metrics = GridMetrics(size: p.size, width: max(p.viewport.width, 1))
            let metricsChanged = metrics != layout.metrics
            let itemsChanged = p.items != items
            items = p.items
            selection = p.selection
            ratings = p.ratings
            dimmed = p.dimmed
            if itemsChanged || metricsChanged {
                layout.count = items.count
                layout.metrics = metrics
                if itemsChanged {
                    view.reloadData()
                } else {
                    layout.invalidateLayout()
                    for case let item as GridItem in view.visibleItems() { item.cell.reloadThumbnailForSize(metrics) }
                }
                view.setFrameSize(layout.collectionViewContentSize)
            }
            // 不重建，只改看得见的格子的状态
            for case let item as GridItem in view.visibleItems() {
                guard let file = item.cell.item else { continue }
                item.cell.setSelected(selection.contains(file.url))
                item.cell.setRating(ratings[file.url] ?? 0)
                item.cell.setDimmed(dimmed.contains(file.url))
            }
            model.gridColumns = metrics.columns
            model.gridVisibleRows = metrics.visibleRows(height: p.viewport.height)
            let heightChanged = abs(p.viewport.height - lastHeight) > 0.5
            lastHeight = p.viewport.height
            if let request = p.scrollRequest, request.serial != lastScrollSerial {
                lastScrollSerial = request.serial
                view.layoutSubtreeIfNeeded()
                reveal(request.url)
            } else if metricsChanged || heightChanged, let focus = model.grid.focus {
                // 重排后焦点项保持可见（spec V1-08、V5-03）
                view.layoutSubtreeIfNeeded()
                reveal(focus)
            }
            reportVisible()
        }

        /// 滚到这一张完整露在顶部栏和信息条之间
        private func reveal(_ url: URL) {
            guard let scroll, let index = items.firstIndex(where: { $0.url == url }) else { return }
            let frame = layout.frame(at: index)
            let clip = scroll.contentView
            // 网格刚建出来、还没排进窗口：等排好再滚，不然会被当成滚到 0
            if clip.bounds.height < 1 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let clip = self.scroll?.contentView, clip.bounds.height >= 1 else { return }
                    self.reveal(url)
                }
                return
            }
            // 高度用 SwiftUI 给的：这时候 AppKit 那边可能还没按新尺寸排过，clip 的高度是旧的
            let height = lastHeight > 0 ? lastHeight : clip.bounds.height
            let visible = CGRect(x: 0, y: clip.bounds.minY, width: clip.bounds.width, height: height)
            let top = frame.minY - 64, bottom = frame.maxY + 68
            let maxY = max(0, layout.collectionViewContentSize.height - visible.height)
            var y = visible.minY
            if top < visible.minY { y = top } else if bottom > visible.maxY { y = bottom - visible.height }
            y = min(max(y, 0), maxY)
            guard abs(y - visible.minY) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }

        /// 第一张露在顶部栏下面的是第几个（没有焦点时键盘从它开始，spec V4-01）
        private func reportVisible() {
            guard let scroll, !items.isEmpty else { return }
            let y = scroll.contentView.bounds.minY + 56
            let row = max(0, Int(ceil((y - GridMetrics.topInset) / layout.metrics.rowStride)))
            model.gridFirstVisible = min(row * layout.metrics.columns, items.count - 1)
        }

        // MARK: 数据

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let made = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
            guard let item = made as? GridItem, indexPath.item < items.count else { return made }
            let file = items[indexPath.item]
            let cell = item.cell
            cell.configure(item: file, metrics: layout.metrics, selected: selection.contains(file.url),
                           rating: ratings[file.url] ?? 0, dimmed: dimmed.contains(file.url))
            cell.onMouseDown = { [weak self] file, event in self?.mouseDown(file, event) }
            cell.onMouseUp = { [weak self] file, _ in self?.mouseUp(file) }
            cell.onContextClick = { [weak self] file, _ in self?.contextClick(file) }
            cell.onDrag = { [weak self, weak cell] file, event in
                guard let self, let cell else { return }
                self.collapseOnMouseUp = nil
                self.model.beginGridDrag(file, event: event, from: cell)
            }
            return item
        }

        /// 滚出屏幕：还没开始的缩略图任务取消（spec V7-02）
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? GridItem)?.cell.cancelLoading()
        }

        // MARK: 鼠标

        private func mouseDown(_ file: MediaItem, _ event: NSEvent) {
            let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
            collapseOnMouseUp = nil
            if event.clickCount == 2, !command, !shift {
                model.openFromGrid(file.url)    // 双击：看大图（spec V3-01）
            } else if !command, !shift, model.grid.selection.contains(file.url), model.isMultiSelection {
                collapseOnMouseUp = file.url
            } else {
                model.gridClick(file.url, command: command, shift: shift)
            }
        }

        private func mouseUp(_ file: MediaItem) {
            if collapseOnMouseUp == file.url { model.gridClick(file.url, command: false, shift: false) }
            collapseOnMouseUp = nil
        }

        /// 在某一张上点右键（spec M2-03、X4-01）
        private func contextClick(_ file: MediaItem) {
            guard model.canShowGridMenu else { return }
            if !model.grid.selection.contains(file.url) { model.gridClick(file.url, command: false, shift: false) }
            ContextMenuPresenter.show(model.fileMenu(.gridItem)) { [model] in model.perform($0) }
        }

        /// 在空白处点右键（spec M5-01）
        func blankContextClick(_ event: NSEvent) {
            guard model.canShowGridMenu else { return }
            model.showGridBlankMenu()
        }

        /// 在空白处按下：拖动超过 4 点是框选，不拖是取消选中（spec X1-06、X1-08 至 X1-10）
        func trackBand(from down: NSEvent, in view: GridCollectionNSView) {
            guard let window = view.window, let scroll, !model.batchRunning else { return }
            let command = down.modifierFlags.contains(.command), shift = down.modifierFlags.contains(.shift)
            let start = view.convert(down.locationInWindow, from: nil)
            let base = command || shift ? model.grid.selection : []
            var dragging = false
            NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.03)
            defer { NSEvent.stopPeriodicEvents() }
            while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
                if event.type == .leftMouseUp { break }
                let inWindow = window.mouseLocationOutsideOfEventStream
                if event.type == .periodic {
                    guard dragging else { continue }
                    // 离可见区上下边缘 40 点以内：自动滚动，越近越快
                    let clip = scroll.contentView
                    let p = clip.convert(inWindow, from: nil)
                    let visible = clip.bounds
                    var delta: CGFloat = 0
                    if p.y < visible.minY + 40 { delta = -min(28, (visible.minY + 40 - p.y) * 0.5 + 2) }
                    if p.y > visible.maxY - 40 { delta = min(28, (p.y - (visible.maxY - 40)) * 0.5 + 2) }
                    guard delta != 0 else { continue }
                    let maxY = max(0, layout.collectionViewContentSize.height - visible.height)
                    let y = min(max(visible.minY + delta, 0), maxY)
                    guard y != visible.minY else { continue }
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(clip)
                }
                let now = view.convert(inWindow, from: nil)
                if !dragging {
                    guard hypot(now.x - start.x, now.y - start.y) > 4 else { continue }
                    dragging = true
                }
                let rect = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
                view.showBand(rect)
                let hit = urls(touching: rect, in: view)
                // ⌘：框内的在原有选择上切换；⇧：加入；都没按：只选框内的
                let new = command ? base.symmetricDifference(hit) : base.union(hit)
                model.gridViewSelectionChanged(new)
                view.displayIfNeeded()
            }
            view.showBand(nil)
            if !dragging, !command, !shift { model.deselectAllInGrid() }
        }

        /// 框碰到缩略图或文件名的文件
        private func urls(touching rect: CGRect, in view: GridCollectionNSView) -> Set<URL> {
            var result: Set<URL> = []
            for index in layout.indexes(in: rect) where index < items.count {
                let frame = layout.frame(at: index)
                guard frame.intersects(rect) else { continue }
                if let cell = (view.item(at: IndexPath(item: index, section: 0)) as? GridItem)?.cell {
                    let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
                    if cell.touches(local) { result.insert(items[index].url) }
                } else if frame.insetBy(dx: GridMetrics.boxInset, dy: GridMetrics.boxInset).intersects(rect) {
                    result.insert(items[index].url)
                }
            }
            return result
        }
    }
}
