import AppKit
import SwiftUI

/// 新版本提示卡片（设计稿 1.7）：宽 470，两行 + 按钮 + ×；窗口窄于 760 时收成一行
struct UpdateNoticeCard: View {
    let version: String
    let current: String
    let narrow: Bool
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: narrow ? 10 : 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: narrow ? 18 : 18, weight: .medium))
                .foregroundStyle(Theme.Brand.jade)
                .frame(width: narrow ? 26 : 34, height: narrow ? 26 : 34)
                .background {
                    if !narrow { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.12)) }
                }
            if narrow {
                Text("有新版本 \(version)", comment: "新版本提示；%@ 是版本号，例如 v0.3.1")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onOpen) { Text("更新说明") }.buttonStyle(AccentButtonStyle(height: 28, fontSize: 12))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("有新版本 \(version)", comment: "新版本提示；%@ 是版本号，例如 v0.3.1")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("你正在使用 \(current)", comment: "新版本提示；%@ 是当前版本号")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onOpen) { Text("查看更新说明") }.buttonStyle(AccentButtonStyle(height: 28, fontSize: 12))
            }
        }
        .padding(EdgeInsets(top: narrow ? 7 : 12, leading: narrow ? 10 : 14, bottom: narrow ? 7 : 12, trailing: narrow ? 40 : 44))
        .frame(width: narrow ? nil : 470)
        .frame(maxWidth: narrow ? 520 : nil)
        .thickGlass(RoundedRectangle(cornerRadius: narrow ? 22 : 22, style: .continuous))
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 11)
            .accessibilityLabel(Text("关闭"))
        }
    }
}

/// 更新说明表单（设计稿 1.7）：宽 540，圆角 26，距窗口顶 40；背景压暗 38%
struct UpdateSheet: View {
    let release: ReleaseInfo
    let current: String
    let language: AppLanguage
    let maxHeight: CGFloat
    let onSkip: () -> Void
    let onLater: () -> Void
    let onDownload: () -> Void
    /// 正文实际高度：短的说明表单高 540，长的最高 620 在表单里滚动（设计稿 1.7）
    @State private var notesHeight: CGFloat = 0
    private static let chrome: CGFloat = 160   // 头部 + 页脚

    var body: some View {
        let version = "v" + release.version
        let bodyMax = max(120, maxHeight - Self.chrome)
        let bodyHeight = min(max(notesHeight + 20, 540 - Self.chrome), bodyMax)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("一览 \(version) 现已发布", comment: "更新说明标题；%@ 是版本号")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        VersionChip(text: current)
                        Text(verbatim: "→").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        VersionChip(text: version)
                        if let date = release.published {
                            Text("\(UpdateDateText.day(date)) 发布", comment: "更新说明：发布日期；%@ 是日期")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 26, leading: 28, bottom: 18, trailing: 28))

            ScrollView(.vertical) {
                ReleaseNotesView(text: ReleaseNotes.section(of: release.notes, language: language))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { notesHeight = $0 }
            }
            .frame(height: bodyHeight)
            .scrollIndicators(.automatic)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 26)
                }
            }

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 10) {
                Button(action: onSkip) { Text("跳过这个版本").font(.system(size: 13)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text2)
                Spacer()
                Button(action: onLater) { Text("稍后") }.buttonStyle(GlassCapsuleButtonStyle())
                Button(action: onDownload) { Text("前往下载") }.buttonStyle(AccentButtonStyle(height: 32, fontSize: 13))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 14, leading: 26, bottom: 16, trailing: 26))
        }
        .frame(width: 540)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct VersionChip: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(Theme.mono(11.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
    }
}

/// 简化 Markdown 渲染：标题、列表、段落、行内格式；链接只放行 http / https，用浏览器打开
struct ReleaseNotesView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReleaseNotes.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(ReleaseNotes.inline(t))
                        .font(.system(size: level <= 2 ? 16 : 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                case .bullet(let t):
                    listRow(marker: "•", t)
                case .ordered(let n, let t):
                    listRow(marker: "\(n).", t)
                case .paragraph(let t):
                    Text(ReleaseNotes.inline(t)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.link)
        .environment(\.openURL, OpenURLAction { url in
            if ReleaseNotes.isAllowedLink(url) { NSWorkspace.shared.open(url) }
            return .handled
        })
        .textSelection(.enabled)
    }

    private func listRow(marker: String, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker).font(.system(size: 13)).foregroundStyle(Theme.text2)
            Text(ReleaseNotes.inline(t)).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 6)
    }
}

/// 手动检查时的小条（设计稿 .chip，带转圈）
struct UpdateCheckingChip: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(.white)
            Text("正在检查更新…").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 34)
        .regularGlass(Capsule())
    }
}
