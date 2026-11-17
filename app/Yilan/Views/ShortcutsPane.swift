import SwiftUI

/// 设置 › 快捷键（设计稿 08 · 设置 · 快捷键）：按 浏览 / 查看 / 文件 / 视频 分组，右边是键帽
struct ShortcutsPane: View {
    /// 键帽上的内容：文字，或者 SF Symbol（方向键、删除键）
    enum Key: Hashable {
        case text(String)
        case symbol(String, label: String)
    }

    struct Shortcut: Identifiable {
        let action: LocalizedStringResource
        /// 外层之间用“/”隔开，内层是并排的几个键帽
        let keys: [[Key]]
        /// 键帽之间的分隔：“/”是二选一，“–”是范围（1–5）
        var separator = "/"
        var id: String { action.key }
    }

    struct Section: Identifiable {
        let title: LocalizedStringResource
        let rows: [Shortcut]
        var id: String { title.key }
    }

    static let sections: [Section] = [
        Section(title: "评星", rows: [
            Shortcut(action: "设置星级", keys: [[.text("1")], [.text("5")]], separator: "–"),
            Shortcut(action: "清除星级", keys: [[.text("0")]]),
        ]),
        Section(title: "浏览", rows: [
            Shortcut(action: "上一个 / 下一个", keys: [[
                .symbol("arrow.left", label: "←"), .symbol("arrow.right", label: "→"),
                .symbol("arrow.up", label: "↑"), .symbol("arrow.down", label: "↓"),
            ]]),
            Shortcut(action: "第一个 / 最后一个", keys: [[.text("Home")], [.text("End")]]),
            Shortcut(action: "全部 / 只看图片 / 只看视频", keys: [[.text("⌘1"), .text("⌘2"), .text("⌘3")]]),
            Shortcut(action: "显示或隐藏缩略图栏", keys: [[.text("T")]]),
        ]),
        Section(title: "查看", rows: [
            Shortcut(action: "适应窗口 / 实际大小", keys: [[.text("⌘9")], [.text("⌘0")]]),
            Shortcut(action: "适应窗口 ↔ 实际大小（切换）", keys: [[.text("Z")]]),
            Shortcut(action: "放大 / 缩小", keys: [[.text("⌘+"), .text("⌘−")]]),
            Shortcut(action: "进入 / 退出全屏", keys: [[.text("F")], [.text("Esc")]]),
            Shortcut(action: "显示或隐藏信息面板", keys: [[.text("I")]]),
            Shortcut(action: "向右 / 向左旋转", keys: [[.text("R")], [.text("⇧R")]]),
        ]),
        Section(title: "文件", rows: [
            Shortcut(action: "移到废纸篓", keys: [[.symbol("delete.left", label: "⌫")]]),
            Shortcut(action: "撤销上一次评星 / 删除", keys: [[.text("⌘Z")]]),
            Shortcut(action: "打开…", keys: [[.text("⌘O")]]),
        ]),
        Section(title: "视频", rows: [
            Shortcut(action: "播放 / 暂停", keys: [[.text(String(localized: "空格", comment: "快捷键列表里的空格键"))]]),
            Shortcut(action: "快退 / 快进 5 秒", keys: [[.text("J")], [.text("L")]]),
            Shortcut(action: "静音", keys: [[.text("M")]]),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 4)
                    SettingsGroup {
                        ForEach(section.rows) { row in
                            HStack(spacing: 12) {
                                Text(row.action)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                KeyCaps(keys: row.keys, separator: row.separator)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .frame(minHeight: 31)
                        }
                    }
                }
            }
        }
    }
}

/// 一组键帽（设计稿 .kcs：间距 4，“/”白 44% 11pt）
struct KeyCaps: View {
    let keys: [[ShortcutsPane.Key]]
    var separator = "/"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Text(verbatim: separator).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                ForEach(group, id: \.self) { KeyCap(key: $0) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys.map { $0.map(\.spoken).joined(separator: " ") }.joined(separator: " / ")))
    }
}

/// 一个键帽（设计稿 .kc：最小宽 22，高 22，左右 6，圆角 6，白 10% 底，白 8% 边，500 12pt）
struct KeyCap: View {
    let key: ShortcutsPane.Key

    var body: some View {
        Group {
            switch key {
            case .text(let text):
                Text(verbatim: text).font(.system(size: 12, weight: .medium))
            case .symbol(let name, _):
                Image(systemName: name).font(.system(size: 10.5, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(minWidth: 22, minHeight: 22, maxHeight: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private extension ShortcutsPane.Key {
    var spoken: String {
        switch self {
        case .text(let text): text
        case .symbol(_, let label): label
        }
    }
}
