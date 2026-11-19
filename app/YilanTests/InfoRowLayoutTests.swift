import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Yilan

/// 信息行让位规则（spec R2-05，2026-11-18 改定）
@Suite("信息行让位")
struct InfoRowLayoutTests {
    // 宽 1000：每边 (1000 − 110) / 2 − 16 = 429
    @Test("尺寸永远在右边：放得下时「尺寸 · 大小 · 格式」都显示")
    func allRight() {
        #expect(InfoRowLayout.decide(width: 1000, dims: 80, trailing: 150) == .init(showDims: true, showTrailing: true, side: 429))
    }

    @Test("右边放不下：先隐藏「大小 · 格式」，再隐藏尺寸")
    func giveWay() {
        #expect(InfoRowLayout.decide(width: 1000, dims: 80, trailing: 400) == .init(showDims: true, showTrailing: false, side: 429))
        #expect(InfoRowLayout.decide(width: 200, dims: 80, trailing: 150).showDims == false)
    }

    @Test("名称长短不影响右边（左右两半互不影响）")
    func nameIndependent() {
        #expect(InfoRowLayout.decide(width: 640, dims: 80, trailing: 120) == .init(showDims: true, showTrailing: true, side: 249))
    }

    @Test("没有尺寸（视频读不到时）只看「大小 · 格式」")
    func noDims() {
        #expect(InfoRowLayout.decide(width: 1000, dims: nil, trailing: 150).showTrailing)
    }

    @Test("名称和星之间至少 16")
    func gapToStars() {
        let width: CGFloat = 900
        let l = InfoRowLayout.decide(width: width, dims: nil, trailing: 0)
        #expect(width / 2 - InfoRowLayout.starsWidth / 2 - l.side == InfoRowLayout.gap)
    }

    @Test("星的总宽和规则里留的位置一致")
    func starsWidth() {
        #expect(InfoRowLayout.starsWidth == InfoRowStars.pitch * 5)
    }

    @Test("星的热区：上下伸出后整行至少 24 高，向下不碰缩略图")
    func hitArea() {
        #expect(16 + InfoRowStars.hitTop + InfoRowStars.hitBottom >= 24)
        // 信息行和缩略图栏间距 6，格子在 62 高的栏里上下各留 5，选中放大 1.12 → 上沿最多上移 2.9
        let thumbTop = 6 + 5 - 52 * 0.06
        #expect(InfoRowStars.hitBottom < thumbTop)
    }
}

/// F1-07「信息面板 5 星只画 4 颗」：五颗星是固定 5 个、固定尺寸，宽度够用，不会被挤掉
@Suite("信息面板的五颗星")
@MainActor
struct InfoPanelStarsTests {
    @Test("五颗星一共 92 宽（16 × 5 + 3 × 4），任何星级、能不能评都一样")
    func fiveStarsFit() {
        for rating in 0...5 {
            for enabled in [true, false] {
                let view = NSHostingView(rootView: StarRow(rating: rating, size: 16, spacing: 3, enabled: enabled) { _ in })
                #expect(view.fittingSize.width == 92)
            }
        }
    }
}
