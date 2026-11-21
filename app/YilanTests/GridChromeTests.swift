import Foundation
import Testing
@testable import Yilan

@Suite("图标视图：信息条、顶部栏、升级提示")
struct GridChromeTests {
    @Test("信息条变窄时让位顺序：尺寸 → 大小和格式 → 星；滑块始终在（spec V1-13）")
    func barGivesWay() {
        func plan(_ width: CGFloat) -> GridBarLayout {
            GridBarLayout.decide(width: width, left: 120, stars: true, dims: 80, trailing: 90)
        }
        let wide = plan(860)
        #expect(wide.showDims && wide.showTrailing && wide.showStars)
        var seen: [String] = []
        for width in stride(from: CGFloat(860), through: 200, by: -10) {
            let p = plan(width)
            let state = "\(p.showDims)\(p.showTrailing)\(p.showStars)"
            if seen.last != state { seen.append(state) }
            // 尺寸在的时候其余一定都在；星在的时候不要求别的
            if p.showDims { #expect(p.showTrailing) }
        }
        #expect(seen == ["truetruetrue", "falsetruetrue", "falsefalsetrue", "falsefalsefalse"])
    }

    @Test("没有星（视频、多选）时不为它留位置")
    func barWithoutStars() {
        let p = GridBarLayout.decide(width: 420, left: 120, stars: false, dims: nil, trailing: 90)
        #expect(!p.showStars && p.showTrailing && !p.showDims)
    }

    @Test("顶部栏：有视图切换时中间一组靠左的位置往右让（spec TB-03）")
    func leftEdge() {
        var w = TopBarWidths()
        #expect(TopBarTier.leftEdge(w) == TopBarTier.leftEdge)
        w.viewSwitch = 72
        let edge: CGFloat = TopBarTier.leftEdge(w)
        #expect(edge == 170, "\(edge)")
    }

    @Test("计数很长放不下时多一档：只显示数量部分（spec TB-04）")
    func counterShort() {
        var w = TopBarWidths(segFull: 263, segSlim: 152, filterFull: 199, filterCount: 116, filterIcon: 63,
                             zoomFull: 132, zoomPercent: 68, counter: 270, tools: 70)
        w.viewSwitch = 40
        w.counterShort = 64
        let narrow = TopBarTier.choose(width: 640, widths: w, hasZoom: false)
        #expect(narrow.counterShort && narrow.leftAligned)
        #expect(narrow.fits(width: 640, widths: w, hasZoom: false))
        let wide = TopBarTier.choose(width: 1280, widths: w, hasZoom: false)
        #expect(!wide.counterShort)
    }

    @Test("「0.5 的新变化」只在从低于 0.5 的版本升级后出现一次；全新安装不出现（spec T5-01）")
    @MainActor
    func whatsNew() {
        #expect(AppSettings.showsWhatsNew05(previous: "0.3.2", current: "0.5.0", upgradedFromV02: false))
        #expect(AppSettings.showsWhatsNew05(previous: "0.4.9", current: "0.5.1", upgradedFromV02: false))
        #expect(!AppSettings.showsWhatsNew05(previous: "0.5.0", current: "0.5.1", upgradedFromV02: false))
        #expect(!AppSettings.showsWhatsNew05(previous: nil, current: "0.5.0", upgradedFromV02: false))     // 全新安装
        #expect(AppSettings.showsWhatsNew05(previous: nil, current: "0.5.0", upgradedFromV02: true))       // 从 0.2 来
        #expect(!AppSettings.showsWhatsNew05(previous: "0.3.2", current: "0.3.2", upgradedFromV02: false)) // 还没到 0.5
        #expect(AppSettings.showsWhatsNew05(previous: "0.3.2", current: "0.10.0", upgradedFromV02: false))
    }

    @Test("汇总文字：只有一种类型时只写那一种（spec V1-11）")
    func summary() {
        func item(_ name: String, _ format: MediaFormat, _ size: Int64) -> MediaItem {
            MediaItem(url: URL(fileURLWithPath: "/tmp/\(name)"), format: format, fileSize: size, modificationDate: .now)
        }
        let photos = GridSummary([item("a.jpg", .standard, 1000), item("b.arw", .raw, 2000)])
        #expect(photos.count == 2 && photos.images == 2 && photos.videos == 0 && photos.bytes == 3000)
        #expect(!photos.composition.contains("·"))
        let mixed = GridSummary([item("a.jpg", .standard, 1), item("c.mov", .video, 1)])
        #expect(mixed.composition.contains("·"))
    }
}
