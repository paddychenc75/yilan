import SwiftUI

/// 批量删除确认框（设计稿 36、37，spec X3-02、X3-03）：叠放的前三张缩略图加红色数量。
/// 没有「不再询问」：一次删多张始终确认
struct BatchDeleteConfirm: View {
    let request: BatchDeleteRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 8) {
                stack
                Text(verbatim: request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineSpacing(14 * 0.4)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                Text(verbatim: request.message)
                    .font(.system(size: 12))
                    .lineSpacing(12 * 0.55)
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: onCancel) { Text("取消") }
                        .buttonStyle(AlertButtonStyle(destructive: false))
                        .keyboardShortcut(.cancelAction)
                    Button(action: onConfirm) { Text("移到废纸篓") }
                        .buttonStyle(AlertButtonStyle(destructive: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
            .frame(width: 300)
            .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    /// 三张叠放（设计稿 .stack）：68 × 46，白边，后两张各歪一点；右上角红色数量
    private var stack: some View {
        let shown = request.preview
        return ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.url) { index, item in
                StackThumbnail(item: item)
                    .rotationEffect(.degrees(index == 0 ? 0 : index == 1 ? 7 : -9))
                    .offset(x: index == 0 ? 0 : index == 1 ? 12 : -12, y: index == 0 ? 0 : 2.5)
            }
        }
        .frame(width: 96, height: 64)
        .overlay(alignment: .topTrailing) {
            Text(verbatim: Formatting.count(request.count))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20)
                .frame(height: 20)
                .background(Capsule().fill(Theme.danger))
                .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .offset(x: 4, y: -2)
        }
    }
}

/// 确认框里叠放的一张小缩略图
private struct StackThumbnail: View {
    let item: MediaItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(red: 28 / 255, green: 29 / 255, blue: 33 / 255)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 68, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.85), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 7, y: 6)
        .task(id: item.url) {
            image = ThumbnailStore.shared.cached(item)?.image
            if image == nil { image = await ThumbnailStore.shared.thumbnail(for: item)?.image }
        }
    }
}

/// 批量操作的进度条（设计稿 40，spec X3-07）：顶部栏下面，转圈、文字、进度、数字和「停止」
struct BatchProgressBar: View {
    let progress: BatchProgress
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 16, height: 16)
            Text(verbatim: progress.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(.white)
                    .frame(width: 110 * CGFloat(progress.done) / CGFloat(max(progress.total, 1)))
            }
            .frame(width: 110, height: 3)
            .animation(.linear(duration: 0.15), value: progress.done)
            Text(verbatim: "\(Formatting.count(progress.done)) / \(Formatting.count(progress.total))")
                .font(Theme.mono(11, .regular))
                .foregroundStyle(Theme.text2)
                .fixedSize()
            Button(action: onStop) {
                Text("停止")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(progress.stopping)
            .opacity(progress.stopping ? 0.45 : 1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 36)
        .regularGlass(Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// 批量操作结束后的提示框（设计稿 41、46，spec X3-12、X3-17）：列出没成功的文件和原因
struct BatchReportAlert: View {
    let report: BatchReport
    let onAction: () -> Void
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.yellow)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                Text(verbatim: report.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if let message = report.message {
                    Text(verbatim: message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(report.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                        HStack(spacing: 12) {
                            Text(verbatim: row.item.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.reason)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                    }
                    if report.more > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        Text("还有 \(report.more) 个", comment: "提示框里没列出来的文件数；%lld 是数量")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.22)))
                .padding(.top, 8)
                HStack(spacing: 10) {
                    Button(action: onAction) { Text(verbatim: report.actionTitle) }
                        .buttonStyle(AlertButtonStyle(destructive: false))
                    Button(action: onDone) { Text("好") }
                        .buttonStyle(AlertButtonStyle(destructive: false, prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 12)
                // Esc 也等于「好」
                Button("", action: onDone).keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0)
            }
            .padding(EdgeInsets(top: 22, leading: 20, bottom: 18, trailing: 20))
            .frame(width: 340)
            .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
