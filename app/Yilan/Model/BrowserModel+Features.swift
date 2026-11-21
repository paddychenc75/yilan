import SwiftUI

/// 简洁模式（spec 第 8 节）：一个开关，打开后只保留和看图有关的功能（视图、筛选、照片信息、缩放、旋转、视频），评星、编辑、复制 / 移动到文件夹一起消失。
/// 界面、按键、菜单都读这里的几个属性，不直接读设置，方便核对有没有漏掉的入口。
/// 内部仍按三项功能分开收尾（各自要清的状态不一样），但用户只能一起开、一起关：只有两种状态，不存在别的组合
extension BrowserModel {
    var ratingEnabled: Bool { settings.featureRating }
    var filterEnabled: Bool { settings.featureFilter }
    var editEnabled: Bool { settings.featureEdit }

    var simpleMode: Bool { settings.simpleMode }
    /// 复制到 / 移动到文件夹：简洁模式里没有
    var transferEnabled: Bool { !settings.simpleMode }

    /// 打开或关闭简洁模式。正在编辑时不能打开：不然没保存的改动会丢（spec T2-15）
    func setSimpleMode(_ on: Bool) {
        guard on != settings.simpleMode, !on || edit == nil else { return }
        settings.simpleMode = on
        // 筛选属于「看」，不跟着关（评星关掉时，正在生效的星级条件会被清掉，格式条件保留）
        for feature in Feature.allCases where feature != .filter { settings.setEnabled(feature, !on) }
    }

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

}
