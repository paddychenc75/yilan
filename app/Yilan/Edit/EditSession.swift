import Foundation
import Observation
import UniformTypeIdentifiers

/// 编辑模式里的状态（spec 21）：裁切框、旋转、比例、缩小、面板开关、保存中。
/// 只保存在内存里，Esc 放弃时整个丢掉
@MainActor
@Observable
final class EditSession {
    let item: MediaItem
    /// 原图按 EXIF 方向转正后的尺寸
    let imageSize: PixelSize
    /// 进入编辑时的旋转（浏览时转过的，spec ED-03）
    let startTurns: Int

    /// 顺时针 90° 的个数（0–3）
    private(set) var turns: Int
    /// 转完之后的图上的裁切框
    var crop: PixelRect
    private(set) var ratio: CropRatio = .free
    /// 固定比例竖着用
    private(set) var portrait = false
    /// 缩小比例（0, 1]，以裁切后的尺寸为基准
    var scale: Double = 1

    // 菜单、面板
    var ratioMenuOpen = false
    var saveMenuOpen = false
    var resizeOpen = false
    var confirmReplace = false
    var saving = false
    var failure: EditSaveError?

    /// 原图的类型、透明通道、方向（后台读出后填上）
    var source: EditWriter.SourceInfo?
    /// RAW 存成 JPEG 还是 HEIF（spec ED-33）
    var rawChoice: RawExportFormat

    init(item: MediaItem, imageSize: PixelSize, turns: Int, rawChoice: RawExportFormat) {
        self.item = item
        self.imageSize = imageSize
        let t = ((turns % 4) + 4) % 4
        startTurns = t
        self.turns = t
        crop = PixelRect(size: t % 2 == 1 ? imageSize.swapped : imageSize)
        self.rawChoice = rawChoice
    }

    // MARK: - 派生

    var editedSize: PixelSize { turns % 2 == 1 ? imageSize.swapped : imageSize }
    var outputSize: PixelSize { ResizeMath.output(crop: crop.size, scale: scale) }
    /// 当前要保持的宽 / 高（自由时 nil）
    var ratioValue: Double? { ratio.widthOverHeight(image: editedSize, portrait: portrait) }
    var canSwap: Bool { ratio.canSwap(image: editedSize) }
    var isDirty: Bool { turns != startTurns || !crop.covers(editedSize) || scale < 1 || ratio != .free }
    var anyPopupOpen: Bool { ratioMenuOpen || saveMenuOpen || resizeOpen }

    var plan: EditPlan {
        EditPlan(source: item.url, imageSize: imageSize, quarterTurns: turns, crop: crop, output: outputSize)
    }

    var target: EditTarget {
        EditTarget.decide(for: item, sourceType: source?.typeIdentifier ?? Self.guessType(item.url),
                          hasAlpha: source?.hasAlpha ?? false, rawChoice: rawChoice)
    }

    /// 还没读出原图类型时按扩展名猜
    static func guessType(_ url: URL) -> String? { UTType(filenameExtension: url.pathExtension.lowercased())?.identifier }

    // MARK: - 操作

    func closePopups() {
        ratioMenuOpen = false
        saveMenuOpen = false
        resizeOpen = false
    }

    /// 旋转（spec ED-19）：裁切框跟着转，固定比例的横竖跟着换
    func rotate(clockwise: Bool) {
        let before = editedSize
        crop = CropMath.rotate(crop, clockwise: clockwise, in: before)
        turns = ((turns + (clockwise ? 1 : -1)) % 4 + 4) % 4
        if ratio.canSwap(image: editedSize) { portrait.toggle() }
    }

    /// 选比例（spec ED-14）：方向跟当前框一致
    func setRatio(_ r: CropRatio) {
        ratio = r
        ratioMenuOpen = false
        guard r != .free else { return }
        portrait = r.canSwap(image: editedSize) && crop.height > crop.width
        if let value = ratioValue { crop = CropMath.fit(crop, ratio: value, bounds: editedSize) }
    }

    /// 横竖互换（spec ED-16）
    func swapOrientation() {
        guard canSwap else { return }
        ratioMenuOpen = false
        portrait.toggle()
        if let value = ratioValue { crop = CropMath.swap(crop, ratio: value, bounds: editedSize) }
    }

    /// 复原（spec ED-26）
    func reset() {
        turns = startTurns
        ratio = .free
        portrait = false
        scale = 1
        crop = PixelRect(size: editedSize)
        closePopups()
    }
}
