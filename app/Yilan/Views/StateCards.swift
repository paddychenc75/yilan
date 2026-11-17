import SwiftUI

/// “无法打开”卡片（设计稿 04 状态界面 · 无法打开）
struct ErrorCard: View {
    let name: String
    let failure: DecodeFailure
    let hasNext: Bool
    let onReveal: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.yellow.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.yellow)
                }
            Text("无法打开“\(name)”")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Text("\(failure.reason)\n其他文件不受影响，可以继续浏览。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            if !failure.detail.isEmpty {
                Text(failure.detail)
                    .font(Theme.mono(11.5, .regular))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)))
                    .padding(.top, 2)
            }
            HStack(spacing: 10) {
                Button(action: onReveal) {
                    Label("在访达中显示", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                if hasNext {
                    Button("下一个", action: onNext)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 30, leading: 32, bottom: 26, trailing: 32))
        .frame(width: 400)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// 空文件夹（设计稿 04 状态界面 · 空文件夹）
struct EmptyFolderCard: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            StackedPhotosIcon().padding(.bottom, 6)
            Text("这个文件夹里没有图片或视频")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 6)
            Text("一览可以打开 JPEG、PNG、HEIF、RAW、WebP、GIF、SVG、TIFF、MP4、MOV。\n也可以把其他文件夹拖到这里。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button(action: onOpen) {
                Label("打开其他文件夹…", systemImage: "folder")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 30, leading: 32, bottom: 26, trailing: 32))
        .frame(width: 440)
        .thickGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// 三张叠起来的照片图标（空文件夹卡片上的插图）
struct StackedPhotosIcon: View {
    var body: some View {
        ZStack {
            card(opacity: 0.05, stroke: 0.3).rotationEffect(.degrees(-10)).offset(x: -12, y: 4)
            card(opacity: 0.05, stroke: 0.3).rotationEffect(.degrees(8)).offset(x: 10, y: -2)
            card(opacity: 0.12, stroke: 0.6)
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 84, height: 64)
    }

    private func card(opacity: Double, stroke: Double) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(opacity))
            .strokeBorder(.white.opacity(stroke), lineWidth: 1.5)
    }
}

/// 顶部提示条（设计稿 .toast），例如“只看视频 · 4 个”
struct ToastView: View {
    let toast: Toast
    var onAction: ((ToastAction) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(toast.tone == .warning ? Theme.yellow : .white)
            Text(verbatim: toast.text).font(.system(size: 12, weight: .medium))
            if let detail = toast.detail {
                // 设计稿：圆点白 44%，补充说明白 68%；可以点的是蓝色链接（#64B5FF，600 字重）
                Text(verbatim: "·").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                if let action = toast.action {
                    Button { onAction?(action) } label: {
                        Text(verbatim: detail)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.link)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                } else {
                    Text(verbatim: detail).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                }
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .regularGlass(Capsule())
    }
}

/// RAW 解码中提示（设计稿 .chip）。系统 API 不提供解码进度，所以只显示转圈
struct RawDecodingChip: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small).tint(.white)
            Text("RAW · 正在解码高清版本").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 34)
        .regularGlass(Capsule())
    }
}

