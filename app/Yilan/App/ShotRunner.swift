import AppKit

/// 按截图参数（见 ShotHooks）在启动后摆出要截的状态。Release 版里什么都不做
@MainActor
enum ShotRunner {
    static func run(model: BrowserModel) {
        #if DEBUG
        guard ShotHooks.openInfo || ShotHooks.deleteState != nil || ShotHooks.fullScreenState != nil || ShotHooks.dumpMenus
                || ShotHooks.windowSize != nil || ShotHooks.anyRatingShot
        else { return }
        Task { @MainActor in
            // 等文件夹打开、当前文件显示出来（最多 5 秒）
            for _ in 0..<50 where model.current == nil || model.displayed == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let size = ShotHooks.windowSize, let window = model.window {
                window.setContentSize(size)
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ShotHooks.fullScreenState != nil, let window = model.window, !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(1.2))
            }
            if ShotHooks.stripHidden { model.stripVisible = false }
            if ShotHooks.openInfo { model.setInfoVisible(true) }
            // 评星截图：只对 /tmp 下的测试副本写盘
            if let n = ShotHooks.rating, let item = model.current, isTemporary(item.url) {
                for _ in 0..<50 where !model.ratingsLoaded { try? await Task.sleep(for: .milliseconds(100)) }
                model.rateCurrent(n, fromKeyboard: true)
            }
            if ShotHooks.seedRatings, let first = model.current, isTemporary(first.url) {
                for _ in 0..<50 where !model.ratingsLoaded { try? await Task.sleep(for: .milliseconds(100)) }
                let pattern = [5, 4, 0, 3, 4, 2, 0, 5, 4, 3]
                for (i, item) in model.allItems.enumerated() {
                    model.setRating(pattern[i % pattern.count], for: item, old: model.ratings[item.url] ?? 0, recordUndo: false)
                }
                await model.ratingWriter.waitUntilIdle()
            }
            if let spec = ShotHooks.filterSpec {
                var f = BrowseFilter()
                for token in spec.split(separator: ",") {
                    if token.hasPrefix("t:"), let t = MediaFilter(rawValue: String(token.dropFirst(2))) { model.setFilter(t) }
                    if token == "ru" { f.rating.mode = .unrated }
                    if token.hasPrefix("r"), let n = Int(token.dropFirst()) { f.rating.mode = .atLeast(n) }
                    if token.hasPrefix("f:") {
                        f.format.selected = Set(token.dropFirst(2).split(separator: "+").compactMap { FormatGroup(rawValue: String($0)) })
                    }
                }
                model.setBrowseFilter(f)
            }
            if ShotHooks.filterPanel { model.filterPanelOpen = true }
            if ShotHooks.showStars { model.flash(nil) }
            switch ShotHooks.hint {
            case "shortcuts": model.enqueueHint(.shortcutsChanged)
            case "xmp": model.enqueueHint(.sidecarCreated("DSC_0812.xmp"))
            default: break
            }
            switch ShotHooks.deleteState {
            case "confirm":
                model.settings.confirmBeforeDelete = true
                model.requestDelete()
            case "after":
                // 真的会移到废纸篓：只对 /tmp 下的测试副本生效
                if let item = model.current, isTemporary(item.url) {
                    await model.performDelete(item)
                }
            default:
                break
            }
            if ShotHooks.dumpMenus {
                try? await Task.sleep(for: .milliseconds(300))
                if let menu = NSApp.mainMenu { print(describe(menu, depth: 0), terminator: "") }
                fflush(stdout)
            }
        }
        #endif
    }

    private static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }

    private static func describe(_ menu: NSMenu, depth: Int) -> String {
        var out = ""
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem {
                out += "\(pad)---\n"
                continue
            }
            var key = item.keyEquivalent
            if key == "\u{8}" || key == "\u{7F}" { key = "⌫" }
            let mods = item.keyEquivalentModifierMask
            var prefix = ""
            if !key.isEmpty {
                if mods.contains(.control) { prefix += "⌃" }
                if mods.contains(.option) { prefix += "⌥" }
                if mods.contains(.shift) { prefix += "⇧" }
                if mods.contains(.command) { prefix += "⌘" }
            }
            let shortcut = key.isEmpty ? "" : "  [\(prefix)\(key)]"
            out += "\(pad)\(item.title)\(shortcut)\(item.isEnabled ? "" : "  (disabled)")\n"
            if let sub = item.submenu { out += describe(sub, depth: depth + 1) }
        }
        return out
    }
}
