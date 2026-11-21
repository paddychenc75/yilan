import AppKit
import SwiftUI

/// 批量操作（spec 第 6、7 节）：先放入口，具体实现在后面几步补上
extension BrowserModel {
    /// 正在批量移到废纸篓、复制或移动（spec X3-08）
    var batchRunning: Bool { false }

    /// 多选时按 ⌫（spec X3-01）
    func requestBatchDelete() {}

    /// 多选时按数字键（spec X7）
    func rateSelection(_ value: Int) {}
}
