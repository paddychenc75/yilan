import AppKit
import Testing
@testable import Yilan

@Suite("双击标题栏（B1）")
struct TitleBarDoubleClickTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "yilan-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test("按系统设置的四种值")
    func actions() {
        #expect(TitleBarDoubleClick.action(defaults: defaults(["AppleActionOnDoubleClick": "Maximize"])) == .zoom)
        #expect(TitleBarDoubleClick.action(defaults: defaults(["AppleActionOnDoubleClick": "Fill"])) == .fill)
        #expect(TitleBarDoubleClick.action(defaults: defaults(["AppleActionOnDoubleClick": "Minimize"])) == .minimize)
        #expect(TitleBarDoubleClick.action(defaults: defaults(["AppleActionOnDoubleClick": "None"])) == .none)
    }

    @Test("没设过或不认识的值时是缩放")
    func fallback() {
        #expect(TitleBarDoubleClick.action(defaults: defaults([:])) == .zoom)
        #expect(TitleBarDoubleClick.action(defaults: defaults(["AppleActionOnDoubleClick": "Something"])) == .zoom)
    }

    @Test("判断是否已经铺满")
    func filled() {
        let target = NSRect(x: 0, y: 80, width: 1440, height: 795)
        #expect(TitleBarDoubleClick.isFilled(NSRect(x: 1, y: 80, width: 1439, height: 795), in: target))
        #expect(!TitleBarDoubleClick.isFilled(NSRect(x: 100, y: 100, width: 1280, height: 700), in: target))
    }
}
