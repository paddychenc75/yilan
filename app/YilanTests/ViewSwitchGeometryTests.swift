import AppKit
import Foundation
import Testing
@testable import Yilan

@Suite("视图切换动画的起点和终点（spec V2-03）")
struct ViewSwitchGeometryTests {
    let area = CGRect(x: 32, y: 64, width: 1216, height: 604)   // 1280 × 800 窗口、带缩略图栏时的图片区

    @Test("大图区：比图片区大的位图缩小到放得下，居中")
    func galleryFitsLargeImage() {
        let r = ViewSwitchGeometry.galleryRect(area: area, pixelSize: CGSize(width: 4000, height: 3000), aspect: 1.333, allowsUpscale: false)
        // 高度顶满：604 / 3000 → 宽 805.3
        #expect(r.height == 604)
        #expect(abs(r.width - 806) <= 1)
        #expect(abs(r.midX - area.midX) <= 1 && abs(r.midY - area.midY) <= 1)
    }

    @Test("大图区：小位图不放大（1 像素 = 1 点），矢量图可以放大")
    func galleryDoesNotUpscaleBitmaps() {
        let small = CGSize(width: 300, height: 200)
        let r = ViewSwitchGeometry.galleryRect(area: area, pixelSize: small, aspect: 1.5, allowsUpscale: false)
        #expect(r.size == small)
        #expect(r.origin == CGPoint(x: 490, y: 266))
        let svg = ViewSwitchGeometry.galleryRect(area: area, pixelSize: small, aspect: 1.5, allowsUpscale: true)
        #expect(svg.height == 604 && svg.width == 906)
    }

    @Test("不知道原图尺寸：按缩略图比例铺满图片区（和占位缩略图一样）")
    func galleryUnknownSize() {
        let r = ViewSwitchGeometry.galleryRect(area: area, pixelSize: nil, aspect: 2, allowsUpscale: false)
        #expect(r.width == 1208 && r.height == 604)
    }

    @Test("图片区 = 窗口减四边留白")
    func galleryArea() {
        let a = ViewSwitchGeometry.galleryArea(size: CGSize(width: 1280, height: 800),
                                               insets: NSEdgeInsets(top: 64, left: 32, bottom: 132, right: 32))
        #expect(a == area)
    }

    @Test("网格：第一行不用滚，缩略图在格子的 4:3 区里居中")
    func gridFirstRow() {
        let metrics = GridMetrics(size: .m, width: 1280)
        let r = ViewSwitchGeometry.predictedGridRect(index: 1, count: 40, metrics: metrics, viewportHeight: 800, aspect: 1.5)
        let cell = metrics.cellFrame(at: 1)
        // 160 宽的区里 3:2 顶满宽，高 107，上下居中
        #expect(r == CGRect(x: cell.minX + 8, y: cell.minY + 15, width: 160, height: 107))
        #expect(cell.minY == GridMetrics.topInset)
    }

    @Test("网格：靠下的一张，预测的落点就是滚到它完整可见后的位置（spec SEL-03）")
    func gridScrolledRow() {
        let metrics = GridMetrics(size: .m, width: 1280)
        let index = 60, height: CGFloat = 800
        let r = ViewSwitchGeometry.predictedGridRect(index: index, count: 100, metrics: metrics, viewportHeight: height, aspect: 1.5)
        let cell = metrics.cellFrame(at: index)
        let offset = GridMetrics.revealOffset(for: cell, current: 0, viewportHeight: height,
                                              contentHeight: metrics.contentHeight(count: 100))
        #expect(offset == cell.maxY + 68 - height)
        #expect(r.minY == cell.minY + 15 - (offset ?? 0))
        // 落点在顶部栏和信息条之间
        #expect(r.minY >= 64 && r.maxY <= height - 68)
    }

    @Test("网格：已经完整可见时不滚；滚到底不越界")
    func revealRules() {
        let metrics = GridMetrics(size: .m, width: 1280)
        let content = metrics.contentHeight(count: 12)
        #expect(GridMetrics.revealOffset(for: metrics.cellFrame(at: 0), current: 0, viewportHeight: 800, contentHeight: content) == nil)
        // 内容比窗口还矮：怎么都不滚
        #expect(GridMetrics.revealOffset(for: metrics.cellFrame(at: 11), current: 0, viewportHeight: 800, contentHeight: content) == nil)
        // 最后一行：底下留出信息条的空
        let big = metrics.contentHeight(count: 100)
        let last = metrics.cellFrame(at: 99)
        let y = GridMetrics.revealOffset(for: last, current: 0, viewportHeight: 800, contentHeight: big)
        #expect(y == last.maxY + 68 - 800)
        // 要求的位置超过内容底端：停在底端
        let beyond = CGRect(x: 24, y: big - 40, width: 176, height: 162)
        #expect(GridMetrics.revealOffset(for: beyond, current: 0, viewportHeight: 800, contentHeight: big) == big - 800)
    }

    @Test("网格排版和预测用的是同一套位置")
    @MainActor
    func layoutMatchesMetrics() {
        let layout = GridLayout()
        layout.metrics = GridMetrics(size: .l, width: 1100)
        layout.count = 37
        for i in [0, 5, 36] { #expect(layout.frame(at: i) == layout.metrics.cellFrame(at: i)) }
        #expect(layout.collectionViewContentSize.height == layout.metrics.contentHeight(count: 37))
    }

    @Test("矩形不在窗口里、没有面积：不做放大")
    func usable() {
        let size = CGSize(width: 1280, height: 800)
        #expect(ViewSwitchGeometry.isUsable(CGRect(x: 10, y: 10, width: 100, height: 80), in: size))
        #expect(!ViewSwitchGeometry.isUsable(CGRect(x: 10, y: 900, width: 100, height: 80), in: size))
        #expect(!ViewSwitchGeometry.isUsable(CGRect(x: 10, y: 10, width: 0, height: 80), in: size))
    }
}
