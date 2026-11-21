import AppKit
import SwiftUI

/// 把 FileMenuItem 清单变成系统菜单并弹出来（spec M1、M2）
@MainActor
enum ContextMenuPresenter {
    /// 在鼠标位置弹出；upward 为 true 时菜单的左下角对着鼠标（缩略图栏里往上弹，spec M2-01）
    static func show(_ items: [FileMenuItem], upward: Bool = false, perform: @escaping @MainActor (FileAction) -> Void) {
        let menu = make(items, perform: perform)
        var point = NSEvent.mouseLocation
        if upward { point.y += menu.size.height }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// 不针对文件的菜单（图标视图空白处，spec M5-01）：可以打勾
    struct Entry {
        var title = ""
        var shortcut: MenuShortcut? = nil
        var checked = false
        var enabled = true
        var run: (@MainActor () -> Void)? = nil
        static let separator = Entry()
    }

    static func show(entries: [Entry]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            guard let run = entry.run else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: entry.shortcut?.key ?? "")
            item.keyEquivalentModifierMask = entry.shortcut?.modifierMask ?? []
            let target = MenuTarget(run)
            item.target = target
            item.representedObject = target
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func make(_ items: [FileMenuItem], perform: @escaping @MainActor (FileAction) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items {
            guard let action = entry.action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: entry.shortcut?.key ?? "")
            // 只在这个菜单开着的时候有效，不会注册成全局快捷键
            item.keyEquivalentModifierMask = entry.shortcut?.modifierMask ?? []
            let target = MenuTarget { perform(action) }
            item.target = target
            item.representedObject = target   // 让菜单项拿住它
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor
private final class MenuTarget: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

/// 这次鼠标按下算不算「右键」：右键、Control + 左键（触控板双指点按系统会报成右键）
@MainActor
enum ContextClick {
    static func matches(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        if event.type == .rightMouseDown { return true }
        return event.type == .leftMouseDown && event.modifierFlags.contains(.control)
    }
}

/// 只接右键的透明层（技术方案 3.5）：别的鼠标事件一律穿过去，不影响点按、悬停和滚动。
/// 盖在一个 SwiftUI 视图上，让它能响应右键（缩略图栏里的每个缩略图）
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onRightClick = onRightClick }

    final class CatcherView: NSView {
        var onRightClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            ContextClick.matches(NSApp.currentEvent) ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { onRightClick?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightClick?() } else { super.mouseDown(with: event) }
        }
    }
}

extension View {
    /// 右键（或 Control + 点按）时调用
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(onRightClick: action))
    }
}
