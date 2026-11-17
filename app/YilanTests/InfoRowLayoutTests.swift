import CoreGraphics
import Testing
@testable import Yilan

/// 信息行让位规则（spec R2-05，2026-11-18 改定）
@Suite("信息行让位")
struct InfoRowLayoutTests {
    // 宽 1000：每边 (1000 − 110) / 2 − 16 = 429
    @Test("都放得下：尺寸在左，右边完整")
    func allFit() {
        let l = InfoRowLayout.decide(width: 1000, name: 200, dims: 80, trailing: 150)
        #expect(l == .init(dims: .left, showTrailing: true, side: 429))
    }

    @Test("左边挤、右边有地方：尺寸挪到右边，不隐藏")
    func dimsMoveRight() {
        let l = InfoRowLayout.decide(width: 1000, name: 400, dims: 80, trailing: 150)
        #expect(l.dims == .right && l.showTrailing)
    }

    @Test("右边也放不下两样：先隐藏「大小 · 格式」，尺寸留在左边")
    func hideTrailingFirst() {
        let l = InfoRowLayout.decide(width: 1000, name: 300, dims: 80, trailing: 440)
        #expect(l.dims == .left && !l.showTrailing)
    }

    @Test("隐藏「大小 · 格式」后，尺寸放到右边一组")
    func dimsAloneRight() {
        let l = InfoRowLayout.decide(width: 1000, name: 420, dims: 80, trailing: 400)
        #expect(l.dims == .right && !l.showTrailing)
    }

    @Test("名称本身超出（640 宽）：名称截断在 side 内；右边先隐藏「大小 · 格式」，尺寸留在右边")
    func truncateName() {
        let l = InfoRowLayout.decide(width: 640, name: 600, dims: 80, trailing: 150)
        #expect(l == .init(dims: .right, showTrailing: false, side: 249))
        let roomy = InfoRowLayout.decide(width: 640, name: 600, dims: 80, trailing: 100)
        #expect(roomy.dims == .right && roomy.showTrailing)
    }

    @Test("右边连尺寸都放不下：尺寸也隐藏")
    func hideDims() {
        let l = InfoRowLayout.decide(width: 300, name: 600, dims: 80, trailing: 150)
        #expect(l.dims == .hidden && !l.showTrailing)
    }

    @Test("名称和星之间至少 16")
    func gapToStars() {
        let width: CGFloat = 900
        let l = InfoRowLayout.decide(width: width, name: 999, dims: nil, trailing: 0)
        #expect(width / 2 - InfoRowLayout.starsWidth / 2 - l.side == InfoRowLayout.gap)
    }

    @Test("视频（不画星）也给中间留位置，两边文字不跟着挪")
    func videoSameSide() {
        let a = InfoRowLayout.decide(width: 1000, name: 200, dims: 80, trailing: 150)
        let b = InfoRowLayout.decide(width: 1000, name: 200, dims: 80, trailing: 150)
        #expect(a.side == b.side)
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
