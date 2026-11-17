import AppKit
import SwiftUI

/// 信息面板：开关、读取当前文件的信息、拷贝
extension BrowserModel {
    func toggleInfo() { setInfoVisible(!infoVisible) }

    func setInfoVisible(_ visible: Bool) {
        guard visible != infoVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) { infoVisible = visible }
        if visible { refreshInfo() } else { infoTask?.cancel() }
    }

    private static func cacheKey(_ item: MediaItem) -> String {
        "\(item.url.path)|\(item.modificationDate.timeIntervalSinceReferenceDate)|\(item.fileSize)"
    }

    /// 面板开着时，读当前文件的信息。读得快就直接换成新内容（不闪）；
    /// 超过 120 毫秒还没读完，先显示“文件”组的基本信息
    func refreshInfo() {
        infoTask?.cancel()
        guard infoVisible, let item = current else {
            if current == nil { info = nil }
            return
        }
        let key = Self.cacheKey(item)
        if let cached = metadataCache[key] {
            info = InfoContent.make(cached)
            return
        }
        infoTask = Task {
            let reader = Task.detached(priority: .userInitiated) { await MetadataReader.read(item) }
            let fallback = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, item == current, info?.title != item.name else { return }
                info = InfoContent.make(MetadataReader.basic(item))
            }
            let meta = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
            fallback.cancel()
            guard !Task.isCancelled, item == current else { return }
            if metadataCache.count > 300 { metadataCache.removeAll() }
            metadataCache[key] = meta
            info = InfoContent.make(meta)
        }
    }

    /// 文件变了（外部修改、删除）：忘掉它的缓存信息
    func forgetMetadata(for urls: Set<URL>) {
        let paths = Set(urls.map(\.path))
        metadataCache = metadataCache.filter { key, _ in
            !paths.contains(String(key.split(separator: "|", maxSplits: 1).first ?? ""))
        }
    }

    func copyInfo() {
        guard let info else { return }
        NSPasteboard.general.clearContents()
        var lines = info.copyText().components(separatedBy: "\n")
        // 第二行加上星级（spec R3-08）
        if let r = currentRating {
            let value = r > 0 ? String(localized: "\(r) 星", comment: "星级值") : String(localized: "未评星")
            lines.insert(String(localized: "评星：\(value)", comment: "拷贝信息里的星级行；%@ 是“4 星”或“未评星”"), at: min(1, lines.count))
        }
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showToast(symbol: "doc.on.doc", text: String(localized: "已拷贝"))
    }

    func copyCoordinates() {
        guard let text = info?.coordinates else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(symbol: "doc.on.doc", text: String(localized: "已拷贝"))
    }
}
