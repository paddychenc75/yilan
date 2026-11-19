import AppKit
import Testing
@testable import Yilan

/// 左上角红绿灯（spec F1-02）：被系统挪回默认位置后自动摆正，自己摆正不会引起循环
@Suite("红绿灯位置")
@MainActor
struct TrafficLightTests {
    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        WindowStyler.configure(w)
        return w
    }

    /// 让主线程跑几轮（处理 async 摆正）
    private func spin(_ times: Int = 5) async {
        for _ in 0..<times { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("创建后就在设计的位置：标题栏 56 高，第一个按钮距左 20、垂直居中")
    func initialPlacement() async throws {
        let w = makeWindow()
        let keeper = TrafficLightKeeper(window: w)
        await spin()
        #expect(!WindowStyler.trafficLightsNeedPlacing(w))
        let close = try #require(w.standardWindowButton(.closeButton))
        let titlebar = try #require(close.superview)
        #expect(titlebar.superview?.frame.height == 56)
        #expect(close.frame.midY == titlebar.frame.height / 2)
        #expect(close.frame.minX + (close.frame.width - 12) / 2 == 20)
        _ = keeper
    }

    @Test("按钮或标题栏容器被挪回默认位置：下一轮自动摆回来，而且不会来回循环")
    func restoresAfterSystemMove() async throws {
        let w = makeWindow()
        let keeper = TrafficLightKeeper(window: w)
        await spin()
        let close = try #require(w.standardWindowButton(.closeButton))
        let container = try #require(close.superview?.superview)
        // 模拟系统重新布局：按钮回到左上角，标题栏回到默认高度
        close.setFrameOrigin(NSPoint(x: 7, y: 3))
        var frame = container.frame
        frame.size.height = 28
        frame.origin.y = w.frame.height - 28
        container.frame = frame
        #expect(WindowStyler.trafficLightsNeedPlacing(w))
        await spin()
        #expect(!WindowStyler.trafficLightsNeedPlacing(w))
        // 摆正后不再继续改动（自己引起的 frame 通知能收敛）
        let count = keeper.placements
        await spin(10)
        #expect(keeper.placements == count)
    }

    @Test("窗口大小变化后仍在原位")
    func resize() async throws {
        let w = makeWindow()
        let keeper = TrafficLightKeeper(window: w)
        w.setFrame(NSRect(x: 100, y: 100, width: 700, height: 500), display: false)
        await spin()
        #expect(!WindowStyler.trafficLightsNeedPlacing(w))
        _ = keeper
    }

    @Test("窗口不用标签页（系统设置「总是以标签页打开」不影响标题栏）")
    func noTabs() {
        #expect(makeWindow().tabbingMode == .disallowed)
    }
}
