import CoreGraphics
import Testing
@testable import Yilan

@Suite("顶部栏收缩（spec E1-10）")
struct TopBarLayoutTests {
    /// 设计稿「给开发的说明」里量好的中文控件宽度（序号按带“· ★4”的最宽情况）
    let zh = TopBarWidths(segFull: 263, segSlim: 152, filterFull: 199, filterCount: 116, filterIcon: 63,
                          zoomFull: 132, zoomPercent: 68, counter: 102, tools: 102)

    private func step(_ width: CGFloat) -> Int {
        let tier = TopBarTier.choose(width: width, widths: zh, hasZoom: true)
        return TopBarTier.steps.firstIndex(of: tier)!
    }

    @Test("按设计稿的宽度算出的阈值和设计稿一致（±10）")
    func thresholds() {
        // 筛选按钮只写条件个数后，原来第一档（完整条件，1260）取消，其余阈值不变：1180 / 1050 / 940 / 890 / 730
        let design: [(CGFloat, Int)] = [(1180, 0), (1050, 1), (940, 2), (890, 3), (730, 4)]
        for (threshold, index) in design {
            #expect(step(threshold) <= index, "宽 \(threshold) 应该不超过第 \(index) 档")
            #expect(step(threshold - 10) >= index + 1, "宽 \(threshold - 10) 应该进入第 \(index + 1) 档")
        }
        #expect(step(1400) == 0)
        #expect(step(640) == 5)
    }

    @Test("从 1400 到 640 每一档都不重叠")
    func noOverlap() {
        for w in stride(from: CGFloat(1400), through: 640, by: -1) {
            let tier = TopBarTier.choose(width: w, widths: zh, hasZoom: true)
            if tier != TopBarTier.steps.last { #expect(tier.fits(width: w, widths: zh, hasZoom: true), "宽 \(w)") }
        }
    }

    @Test("英文更宽时提前收缩（PD-03）")
    func english() {
        var en = zh
        en.segFull = 300
        en.filterFull = 260
        en.filterCount = 130
        let zhTier = TopBarTier.choose(width: 1215, widths: zh, hasZoom: true)
        let enTier = TopBarTier.choose(width: 1215, widths: en, hasZoom: true)
        #expect(TopBarTier.steps.firstIndex(of: enTier)! > TopBarTier.steps.firstIndex(of: zhTier)!)
        #expect(enTier.fits(width: 1215, widths: en, hasZoom: true))
    }

    @Test("没有图片时不算缩放控件")
    func noZoom() {
        let tier = TopBarTier.choose(width: 1100, widths: zh, hasZoom: false)
        #expect(tier.filter == .count)
        #expect(tier.rightWidth(zh, hasZoom: false) == CGFloat(102 + 16 + 102 + 14))
    }
}

@Suite("缩放状态（spec E1）")
struct ZoomStateTests {
    @Test("菜单里打勾的规则由 ZoomState 决定")
    func states() {
        let fit = ZoomState(percent: 38, isFit: true, canZoomIn: true, canZoomOut: false)
        #expect(!fit.canZoomOut)
        let actual = ZoomState(percent: 100, isFit: false, canZoomIn: true, canZoomOut: true)
        #expect(actual.percent == 100 && !actual.isFit)
        #expect(ZoomPercentLabel.text(200).contains("200"))
    }
}

@Suite("设置：显示的页")
struct SettingsPanesTests {
    @Test("「缓存与性能」还没有选项：不在侧边栏里（F1-05），其余各页都在")
    func cacheHidden() {
        #expect(!SettingsView.shownPanes.contains(.cache))
        #expect(SettingsView.shownPanes == [.general, .browsing, .video, .formats, .shortcuts])
    }
}
