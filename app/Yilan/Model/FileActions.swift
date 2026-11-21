import AppKit

/// 针对文件的操作（spec 第 2 节）。右键菜单、「⋯」菜单、菜单栏里同名的项目都从这里出，
/// 文字、先后顺序、可用与否只写一份（spec M4-03）
enum FileAction: Hashable, Sendable {
    case reveal, copy, copyPath
    case rotateLeft, rotateRight, edit, toggleInfo
    case trash
    case open
}

/// 菜单里的一行
struct FileMenuItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case action(FileAction)
        case separator
    }

    var kind: Kind
    var title = ""
    /// 右边显示的快捷键（只是文字，不通过菜单注册，免得按一次执行两次）
    var shortcut: MenuShortcut? = nil
    var enabled = true

    static let separator = FileMenuItem(kind: .separator)

    var action: FileAction? {
        if case .action(let a) = kind { return a }
        return nil
    }
}

/// 菜单项右边显示的快捷键
struct MenuShortcut: Equatable, Sendable {
    var key: String
    var command = false
    var shift = false
    var option = false

    static let delete = MenuShortcut(key: "\u{8}")

    var modifierMask: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        return m
    }
}

/// 菜单出现在哪里
enum FileMenuContext: Equatable, Sendable {
    /// 画廊视图里对着当前这一张：大图上、缩略图栏里点右键（spec M1-02）
    case single
    /// 右上角「⋯」（spec M4-01）
    case more
}

extension BrowserModel {
    /// 这个场合的菜单清单
    func fileMenu(_ context: FileMenuContext) -> [FileMenuItem] {
        let hasFile = current != nil
        let item = { (action: FileAction, title: String, shortcut: MenuShortcut?, enabled: Bool) in
            FileMenuItem(kind: .action(action), title: title, shortcut: shortcut, enabled: enabled)
        }
        // 「⋯」菜单和 v0.3 一样不显示快捷键（spec M4-01）
        let keys = context != .more
        var items: [FileMenuItem] = [
            item(.reveal, String(localized: "在访达中显示"), keys ? MenuShortcut(key: "r", command: true, shift: true) : nil, hasFile),
            item(.copy, String(localized: "拷贝", comment: "菜单：把文件拷贝到剪贴板"), keys ? MenuShortcut(key: "c", command: true) : nil, hasFile),
            item(.copyPath, String(localized: "拷贝文件路径"), keys ? MenuShortcut(key: "c", command: true, option: true) : nil, hasFile),
            .separator,
        ]
        switch context {
        case .single:
            // 出错卡片上不能旋转和编辑（spec M1-06）；视频、GIF 可以旋转，不能编辑（spec M4-04）
            let canRotate = hasFile && failure == nil
            items += [
                item(.rotateLeft, String(localized: "向左旋转"), MenuShortcut(key: "r", shift: true), canRotate),
                item(.rotateRight, String(localized: "向右旋转"), MenuShortcut(key: "r"), canRotate),
            ]
            // 编辑功能关掉后整项消失（spec M4-05）
            if editEnabled {
                items.append(item(.edit, String(localized: "编辑"), MenuShortcut(key: "e"), canEditCurrent))
            }
            items += [
                item(.toggleInfo, infoVisible ? String(localized: "隐藏信息") : String(localized: "显示信息"), MenuShortcut(key: "i"), hasFile),
                .separator,
                item(.trash, String(localized: "移到废纸篓"), .delete, canDelete),
            ]
        case .more:
            items += [
                item(.trash, String(localized: "移到废纸篓"), nil, canDelete),
                .separator,
                item(.open, String(localized: "打开…"), nil, true),
            ]
        }
        return items
    }

    func perform(_ action: FileAction) {
        switch action {
        case .reveal: revealCurrentInFinder()
        case .copy: copyCurrentFile()
        case .copyPath: copyCurrentPath()
        case .rotateLeft: rotate(-1)
        case .rotateRight: rotate(1)
        case .edit: enterEdit()
        case .toggleInfo: toggleInfo()
        case .trash: requestDelete()
        case .open: showOpenPanel()
        }
    }

    // MARK: - 拷贝（spec M3）

    /// ⌘C、菜单「拷贝」：把当前文件作为文件放进剪贴板
    func copyCurrentFile() {
        guard let item = current else { return }
        copyFiles([item])
    }

    /// 把文件放进剪贴板：粘贴到访达得到文件，粘贴到文字框得到路径。只读，不带 .xmp 小文件（spec M3-01、M3-02）
    func copyFiles(_ items: [MediaItem], pasteboard: NSPasteboard = .general) {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existing.isEmpty else {
            showToast(symbol: "exclamationmark.triangle", text: String(localized: "无法拷贝：文件已经不在原处"), tone: .warning, duration: 3)
            return
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(existing.map { item -> NSPasteboardItem in
            let entry = NSPasteboardItem()
            entry.setString(item.url.absoluteString, forType: .fileURL)
            entry.setString(item.url.path, forType: .string)
            return entry
        })
        let missing = items.count - existing.count
        if existing.count == 1, missing == 0 {
            showToast(symbol: "doc.on.doc", text: String(localized: "已拷贝“\(existing[0].name)”", comment: "拷贝一个文件后的提示；%@ 是文件名"), duration: 2)
        } else if missing == 0 {
            showToast(symbol: "doc.on.doc", text: String(localized: "已拷贝 \(existing.count) 项，可以粘贴到访达或其他应用"), duration: 2)
        } else {
            showToast(symbol: "doc.on.doc", text: String(localized: "已拷贝 \(existing.count) 项，另有 \(missing) 项已经不在原处"), duration: 3)
        }
    }

    /// 键盘焦点在文字输入框里（编辑的尺寸输入框、设置里的搜索框）：这时 ⌘C、⌘A 是文字的拷贝和全选（spec K-21）
    var textFieldHasFocus: Bool { NSApp.keyWindow?.firstResponder is NSText }

    /// 菜单栏「编辑 › 拷贝」（spec MB-02）：主窗口在前且焦点不在文字上时拷贝文件，否则交给文字
    func copyFromMenu() {
        if mainWindowIsKey, !textFieldHasFocus, edit == nil {
            copyCurrentFile()
        } else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
    }

    func selectAllFromMenu() {
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }

    /// 「拷贝」菜单项现在作用于文件（否则是文字的拷贝，交给系统判断）
    var copyActsOnFiles: Bool { mainWindowIsKey && !textFieldHasFocus && edit == nil }

    /// 能不能弹右键菜单（spec M1-05、M1-08）：有当前文件，没有在编辑，没有确认框和更新说明
    var canShowContextMenu: Bool {
        current != nil && edit == nil && pendingDelete == nil && UpdateChecker.shared.sheetRelease == nil
    }
}
