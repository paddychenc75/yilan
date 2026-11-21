import SwiftUI

/// 设置 › 功能（设计稿 81–84，spec T1、T4）：评星、筛选、编辑各一个开关，上面一行「全部关闭 / 全部打开」
struct FeaturesPane: View {
    @Bindable var settings: AppSettings
    @State private var model = BrowserModel.shared

    private var editing: Bool { model.edit != nil }
    private var allOff: Bool { !settings.featureRating && !settings.featureFilter && !settings.featureEdit }
    private var allOn: Bool { settings.featureRating && settings.featureFilter && settings.featureEdit }

    var body: some View {
        Text("用不到的功能可以关掉。关掉后它会彻底消失：没有按钮，没有菜单项，快捷键也不响应。不会删除任何东西，已有的星级和文件保持原样，随时可以再打开。")
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(Theme.text2)
            .fixedSize(horizontal: false, vertical: true)
        SettingsGroup {
            SettingsRow("一次全部设置", note: "全部关闭后只看图：保留浏览、缩放、旋转显示和视频播放。") {
                HStack(spacing: 8) {
                    Button("全部关闭") { model.setAllFeatures(false) }
                        .buttonStyle(GrayButtonStyle(height: 26, fontSize: 12, enabled: !allOff && !editing))
                        .disabled(allOff || editing)
                    Button("全部打开") { model.setAllFeatures(true) }
                        .buttonStyle(GrayButtonStyle(height: 26, fontSize: 12, enabled: !allOn))
                        .disabled(allOn)
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("功能")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 4)
            SettingsGroup {
                row("star", Color(hex: 0xC8A24A), "评星", "数字键 1–5 和 0、缩略图栏里的五颗星、缩略图上的星标、按星级筛选", $settings.featureRating)
                row("line.3.horizontal.decrease", Color(hex: 0x5E5CE6), "筛选", "顶部的“筛选”按钮和面板（⌘F）。“全部 / 图片 / 视频”不受影响", $settings.featureFilter)
                // 正在编辑时不能关（spec T2-15）：不然没保存的改动会丢
                row("square.and.pencil", Color(hex: 0x34A853), "编辑", "裁切、调整尺寸、保存旋转（E）。用 R / ⇧R 旋转显示不受影响", $settings.featureEdit,
                    disabled: editing)
            }
        }
        if editing {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).padding(.top, 1)
                Text("有一张图片正在编辑。先保存或取消编辑，才能关闭“编辑”或全部关闭。")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.previewTag)
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.yellow.opacity(0.12)))
        }
        Text("改动立即生效，不用重新打开一览。")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 4)
    }

    private func row(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ note: LocalizedStringKey,
                     _ isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.white)
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(isOn: isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }
}
