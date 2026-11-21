import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Yilan

/// v0.5 测试的公共工具
enum T5 {
    static func suite() -> (defaults: UserDefaults, name: String) {
        let name = "yilan-v05-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return (d, name)
    }

    @MainActor
    static func settings() -> AppSettings { AppSettings(defaults: suite().defaults) }

    /// 在临时目录的样例副本上建一个模型
    @MainActor
    static func model(_ folder: URL, initial: Int? = 0, settings: AppSettings? = nil) throws -> BrowserModel {
        let model = BrowserModel(settings: settings ?? self.settings(), recents: RecentFolders(defaults: suite().defaults))
        let items = try FolderScanner.scan(folder: folder)
        model.apply(FolderScanner.Result(folder: folder, items: items, initialIndex: items.isEmpty ? nil : initial,
                                         sidecars: SidecarIndex.scan(folder: folder, media: items)))
        return model
    }

    static func key(_ keyCode: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                      isARepeat: false, keyCode: keyCode))
    }

    /// 等到条件成立（最多 5 秒）
    @MainActor
    @discardableResult
    static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// 文件夹里每个文件的内容摘要和修改时间：用来断言「没被动过」
    static func snapshot(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let mtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "@\(mtime)"
        }
        return result
    }

    static let digitKeyCodes: [Int: UInt16] = [0: 29, 1: 18, 2: 19, 3: 20, 4: 21, 5: 23]
}
