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
        w.close()
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
        w.close()
    }

    @Test("系统每次都把标题栏改回 28 高：不无限循环，最后按钮在 28 高的标题栏里居中、完整可见、间距不变（F1-02）")
    func systemKeepsRevertingHeight() async throws {
        let w = makeWindow()
        let close = try #require(w.standardWindowButton(.closeButton))
        let titlebar = try #require(close.superview)
        let container = try #require(titlebar.superview)
        // 模拟系统：标题栏容器一被改成别的高度，立刻（在通知里）改回 28
        container.postsFrameChangedNotifications = true
        var reverts = 0
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: nil) { _ in
            MainActor.assumeIsolated {
                guard container.frame.height != 28 else { return }
                reverts += 1
                var f = container.frame
                f.size.height = 28
                f.origin.y = w.frame.height - 28
                container.frame = f
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let keeper = TrafficLightKeeper(window: w)
        // 限定时间内安静下来：之后不再有改动
        var last = -1
        for _ in 0..<100 where keeper.placements != last {
            last = keeper.placements
            await spin(5)
        }
        #expect(keeper.placements == last, "两秒内还没停下")
        #expect(keeper.yielded)
        #expect(reverts < 100)
        // 三个按钮都完整落在标题栏里面，垂直居中，间距 20
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(w.standardWindowButton)
        #expect(buttons.count == 3)
        for b in buttons {
            #expect(titlebar.bounds.contains(b.frame), "\(b.frame) 不在 \(titlebar.bounds) 里")
            #expect(abs(b.frame.midY - titlebar.bounds.height / 2) < 0.01)
        }
        #expect(buttons[1].frame.minX - buttons[0].frame.minX == 20)
        #expect(buttons[2].frame.minX - buttons[1].frame.minX == 20)
        w.close()
    }

    @Test("按钮的位置永远按标题栏的实际高度算，并且整个按钮在标题栏里面（F1-02）")
    func clampedToActualHeight() async throws {
        let w = makeWindow()
        WindowStyler.positionTrafficLights(w, insistHeight: false)
        let close = try #require(w.standardWindowButton(.closeButton))
        let titlebar = try #require(close.superview)
        #expect(titlebar.bounds.contains(close.frame))
        // 先按 56 摆好，再像系统那样只把高度改回 28：重新摆放后按钮回到 28 里面
        WindowStyler.positionTrafficLights(w)
        let container = try #require(titlebar.superview)
        var f = container.frame
        f.size.height = 28
        f.origin.y = w.frame.height - 28
        container.frame = f
        #expect(WindowStyler.trafficLightsNeedPlacing(w, insistHeight: false))
        WindowStyler.positionTrafficLights(w, insistHeight: false)
        #expect(titlebar.bounds.contains(close.frame))
        #expect(!WindowStyler.trafficLightsNeedPlacing(w, insistHeight: false))
        w.close()
    }

    @Test("窗口大小变化后仍在原位")
    func resize() async throws {
        let w = makeWindow()
        let keeper = TrafficLightKeeper(window: w)
        w.setFrame(NSRect(x: 100, y: 100, width: 700, height: 500), display: false)
        await spin()
        #expect(!WindowStyler.trafficLightsNeedPlacing(w))
        _ = keeper
        w.close()
    }

    @Test("不持有窗口：窗口关掉释放后，摆正的帮手什么也不做，也不留下计时")
    func doesNotRetainWindow() async {
        weak var weakWindow: NSWindow?
        var keeper: TrafficLightKeeper?
        do {
            let w = makeWindow()
            weakWindow = w
            keeper = TrafficLightKeeper(window: w)
            await spin()
            w.close()
        }
        await spin()
        #expect(weakWindow == nil)
        keeper?.place()
        keeper = nil
    }

    @Test("窗口不用标签页（系统设置「总是以标签页打开」不影响标题栏）")
    func noTabs() {
        let w = makeWindow()
        #expect(w.tabbingMode == .disallowed)
        w.close()
    }
}
