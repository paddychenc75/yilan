import AppKit
import SwiftUI

/// 批量操作（spec 第 6、7 节）：先放入口，具体实现在后面几步补上
extension BrowserModel {
    /// 正在批量移到废纸篓、复制或移动（spec X3-08）
    var batchRunning: Bool { false }

    var canBatchDelete: Bool { isMultiSelection && !batchRunning && pendingDelete == nil && mainWindowIsKey }

    /// 在空白处点右键（spec M5-01）
    func showGridBlankMenu() {}

    /// 把选中的文件拖出窗口（spec X8）
    func beginGridDrag(_ item: MediaItem, event: NSEvent, from view: NSView) {}

    /// 多选时按 ⌫（spec X3-01）
    func requestBatchDelete() {}

    /// 多选时按数字键（spec X7）
    func rateSelection(_ value: Int) {}
}
