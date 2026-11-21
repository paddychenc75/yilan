import SwiftUI

/// 功能开关（spec 第 8 节）：评星、筛选、编辑各自能关掉。
/// 界面、按键、菜单都读这里的三个属性，不直接读设置，方便核对有没有漏掉的入口
extension BrowserModel {
    var ratingEnabled: Bool { settings.featureRating }
    var filterEnabled: Bool { settings.featureFilter }
    var editEnabled: Bool { settings.featureEdit }

    /// 界面上能不能看到星（信息行、角标、计数、信息面板）
    var showsRatingUI: Bool { ratingEnabled }

    /// 开关拨动后的收尾。只清一览自己的状态，不碰用户文件（spec T3-01）
    func featureSwitchChanged(_ feature: Feature, enabled: Bool) {
        switch feature {
        case .rating:
            if enabled {
                // 重新打开：星级可能在关闭期间被别的软件改过，全部重读
                resetRatings()
                if hasOpenedFolder { loadRatings() }
            } else {
                // spec T2-07：评星记录作废，之后 ⌘Z 不会改动任何星级
                undoHistory.removeAll {
                    switch $0 {
                    case .rating, .ratingBatch: true
                    default: false
                    }
                }
                ratingLoadTask?.cancel()
                flashTask?.cancel()
                ratingFlash = nil
                if case .sidecarCreated = hint { dismissHint() }
                hintQueue.removeAll { if case .sidecarCreated = $0 { true } else { false } }
                // spec T2-04：正在生效的星级条件清掉，格式条件保留
                if browseFilter.rating.isActive {
                    var f = browseFilter
                    f.rating = RatingCriterion()
                    setBrowseFilter(f)
                }
            }
        case .filter:
            guard !enabled else { return }
            // spec T2-10：条件全部清除、面板关闭、暂留清除
            filterPanelOpen = false
            if browseFilter.isActive { clearBrowseFilter() }
            stickyURL = nil
        case .edit:
            guard !enabled else { return }
            // spec T2-14：编辑记录作废，带「撤销」的提示条立即消失
            undoHistory.removeAll { if case .edit = $0 { true } else { false } }
            if toast?.action == .undoEdit { hideToast() }
            rotationMenuOpen = false
        }
    }

    /// 「全部关闭」「全部打开」（spec T4-01）。正在编辑时不能全部关闭（spec T2-15）
    func setAllFeatures(_ enabled: Bool) {
        guard enabled || edit == nil else { return }
        for feature in Feature.allCases { settings.setEnabled(feature, enabled) }
    }

    var allFeaturesOff: Bool { !ratingEnabled && !filterEnabled && !editEnabled }
    var allFeaturesOn: Bool { ratingEnabled && filterEnabled && editEnabled }
}
