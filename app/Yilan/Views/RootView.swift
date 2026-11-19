import AppKit
import SwiftUI

/// 主窗口：深色舞台 + 环境光 + 大图 + 浮在上面的玻璃控件
struct RootView: View {
    @State private var model = BrowserModel.shared
    @State private var window: NSWindow?
    @State private var monitors = EventMonitors()
    /// 筛选面板打开时的左缘（打开期间固定）
    @State private var panelAnchor: CGFloat?
    @State private var panelSettled = false
    /// 正在拖入文件：遮罩上的说明
    @State private var drop: DropSummary?
    /// 顶部栏控件的实测宽度（中英文不同），决定收缩到哪一档
    @State private var barWidths = TopBarWidths()
    @State private var updater = UpdateChecker.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = StageLayout(size: size, fullScreen: model.isFullScreen, panelOpen: showsInfoPanel)
            ZStack {
                Theme.stage
                // 出错时没有可用的图片颜色：用设计稿“无法打开”画板的青绿环境光
                // 设置里关掉“环境光背景”时，看图只用纯黑舞台；欢迎、出错等卡片仍用设计稿的渐变
                if model.settings.ambientBackground || model.current == nil || model.failure != nil {
                    AmbientBackground(image: model.failure == nil ? model.ambient : nil,
                                      id: model.failure == nil ? model.ambientItemURL : nil)
                }
                // 编辑中：背景在环境光上再盖 32% 黑（设计稿 edit 02）
                if model.edit != nil {
                    Color.black.opacity(0.32).allowsHitTesting(false).transition(.opacity)
                }
                stage(layout)
                popupCatcher(size)
                if let session = model.edit {
                    editControls(session, layout: layout)
                } else {
                    stageControls(layout)
                }
                topBar(layout)
                cards(size)
                overlays(layout)
                updateSheet(size)
                // 筛选面板画在提示卡片、提示条上面（spec R5-06）
                if model.filterPanelOpen && model.hasOpenedFolder && topVisible {
                    let widths = effectiveBarWidths
                    let tier = TopBarTier.choose(width: size.width, widths: widths,
                                                 hasZoom: showsZoomControl && model.zoomState != nil)
                    filterPanel(size: size, tier: tier, widths: widths)
                        .offset(y: layout.fullScreen ? menuBarHeight : 0)
                }
                if let drop {
                    DropOverlay(summary: drop)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowAccessor {
            window = $0
            model.attach(window: $0)
        })
        .onAppear {
            monitors.install(model: model, window: { window })
            if ShotHooks.openSettings { SettingsWindow.shared.show() }
            if let path = ShotHooks.dropPath { drop = DropSummary.describe(URL(fileURLWithPath: path)) }
            ShotRunner.run(model: model)
        }
        .onDisappear { monitors.remove() }
        .onChange(of: model.chromeVisible) { _, visible in setTrafficLights(visible: visible) }
        // 全屏时红绿灯由系统跟着菜单栏一起显示，要先恢复成不透明
        .onChange(of: model.isFullScreen) { _, fullScreen in
            setTrafficLights(visible: fullScreen || model.chromeVisible)
        }
        // 改了自动隐藏或延迟：先把控件显示出来，按新设置重新计时
        .onChange(of: model.settings.autoHideControls) { model.noteMouseActivity() }
        .onChange(of: model.settings.hideDelay) { model.noteMouseActivity() }
        // SwiftUI 生命周期下，访达“打开方式”、拖到程序坞图标、`open -a` 的文件都走这里
        .onOpenURL { model.open($0) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(summary: $drop) { model.open($0) })
    }

    private var showsInfoPanel: Bool { model.infoVisible && model.current != nil && model.edit == nil }

    // MARK: - 编辑模式（spec 21）

    /// 窄窗口（< 800）：标题隐藏、缩放只留百分比、工具条去掉「比例」字样和「复原」
    private func editNarrow(_ size: CGSize) -> Bool { size.width < 800 }

    /// 编辑中图片区：上 76、下 92（窄窗 84）、左右 56（窄窗 40）
    private func editInsets(_ size: CGSize) -> NSEdgeInsets {
        let narrow = editNarrow(size)
        return NSEdgeInsets(top: 76, left: narrow ? 40 : 56, bottom: narrow ? 84 : 92, right: narrow ? 40 : 56)
    }

    /// 菜单、面板开着时：点别处关掉
    @ViewBuilder
    private func popupCatcher(_ size: CGSize) -> some View {
        if model.edit?.anyPopupOpen == true || model.rotationMenuOpen {
            Color.black.opacity(0.001)
                .frame(width: size.width, height: size.height)
                .onTapGesture {
                    model.edit?.closePopups()
                    model.rotationMenuOpen = false
                }
        }
    }

    /// 底部编辑工具条，占原缩略图栏的位置（距底 20）
    private func editControls(_ session: EditSession, layout: StageLayout) -> some View {
        EditToolbar(session: session, narrow: editNarrow(layout.size)) { model.rotate($0) }
            .padding(.bottom, 20)
            .frame(width: layout.size.width, height: layout.size.height, alignment: .bottom)
    }

    /// 编辑中的提示框：替换确认、保存失败
    @ViewBuilder
    private func editAlerts(_ size: CGSize) -> some View {
        if let session = model.edit {
            if session.confirmReplace {
                EditAlert(symbol: "photo", title: String(localized: "替换原图？"),
                          message: String(localized: "编辑后的图片会存成「\(session.item.name)」。\n原图移到废纸篓，按 ⌘Z 可以找回。",
                                          comment: "替换原图确认框；%@ 是原文件名"),
                          secondary: String(localized: "取消"), primary: String(localized: "替换"),
                          onSecondary: { session.confirmReplace = false }, onPrimary: { model.confirmReplace() })
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            } else if let failure = session.failure {
                EditAlert(symbol: "exclamationmark.triangle", symbolColor: Theme.yellow, title: String(localized: "没能保存"),
                          message: failure.message + "\n" + String(localized: "原图没有任何改动，编辑也还在。"),
                          secondary: String(localized: "存到其他位置…"), primary: String(localized: "好"),
                          onSecondary: { model.saveEditElsewhere() }, onPrimary: { session.failure = nil })
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 大图

    private func stage(_ layout: StageLayout) -> some View {
        let fs = layout.fullScreen
        // 信息面板浮在图片上：图片区和面板开关无关，开关面板时图片不移动、不缩放
        if model.edit != nil {
            return ImageStage(content: stageContent, insets: editInsets(layout.size), zoomCommand: model.zoomCommand,
                              rotation: model.edit?.turns ?? 0, videoLayer: nil,
                              onNavigate: { _ in }, onZoomChanged: { model.zoomState = $0 },
                              onNeedsFullResolution: { model.requestFullResolution() },
                              onDisplayChanged: { model.displayDidChange(maxPixel: $0) },
                              crop: model.edit.map { .init(editedSize: $0.editedSize, crop: $0.crop, ratio: $0.ratioValue) },
                              onCropChanged: { rect in model.edit?.crop = rect })
        }
        return ImageStage(
            content: stageContent,
            insets: NSEdgeInsets(top: fs ? 0 : Theme.imageInsetTop,
                                 left: layout.imageSideInset,
                                 bottom: fs ? 0 : bottomInset,
                                 right: layout.imageSideInset),
            zoomCommand: model.zoomCommand,
            rotation: model.edit?.turns ?? model.rotation,
            videoLayer: showsVideoLayer ? model.video.layer : nil,
            onNavigate: { model.step($0) },
            onZoomChanged: { model.zoomState = $0 },
            onNeedsFullResolution: { model.requestFullResolution() },
            onDisplayChanged: { model.displayDidChange(maxPixel: $0) },
            crop: model.edit.map { .init(editedSize: $0.editedSize, crop: $0.crop, ratio: $0.ratioValue) },
            onCropChanged: { rect in model.edit?.crop = rect }
        )
    }

    private var bottomInset: CGFloat {
        if isVideo { return videoBarBottom + Theme.videoBarHeight + 16 }   // 设计稿：视频时图片区再让出 58
        return model.stripVisible && model.current != nil ? Theme.imageInsetBottom : Theme.imageInsetBottomNoStrip
    }

    /// 当前是能播放的视频（出错的不算）
    private var isVideo: Bool { model.current?.kind == .video && model.failure == nil }

    private var videoBarBottom: CGFloat {
        model.stripVisible ? Theme.videoBarBottom : Theme.videoBarBottomNoStrip
    }

    /// 播放器画面盖在当前视频的静帧上
    private var showsVideoLayer: Bool {
        isVideo && model.video.item != nil && model.video.item == model.displayedItem
    }

    private var stageContent: ImageStageView.Content? {
        guard let item = model.displayedItem, model.failure == nil else { return nil }
        if let d = model.displayed {
            return .init(url: item.url, image: d.image, pixelSize: d.pixelSize, frames: d.frames,
                         frameDurations: d.frameDurations, allowsUpscale: item.format == .svg,
                         identity: ObjectIdentifier(d))
        }
        if let p = model.placeholder {
            return .init(url: item.url, image: p, pixelSize: CGSize(width: p.width, height: p.height),
                         frames: [], frameDurations: [], allowsUpscale: true, identity: ObjectIdentifier(p))
        }
        return nil
    }

    /// 大播放按钮：视频停着时显示，和其他控件一起自动隐藏
    private var showsVideoGlyph: Bool {
        isVideo && model.displayedItem == model.current && model.displayed != nil && !model.video.isPlaying
    }

    private func imageAreaCenterY(_ layout: StageLayout) -> CGFloat {
        if layout.fullScreen { return layout.size.height / 2 }
        return Theme.imageInsetTop + (layout.size.height - Theme.imageInsetTop - bottomInset) / 2
    }

    // MARK: - 控件显示规则

    /// 顶部一排：窗口里随自动隐藏；全屏时鼠标碰到顶边才出现
    private var topVisible: Bool {
        if model.edit != nil { return true }   // 编辑中顶部栏一直在
        return model.isFullScreen ? model.fullScreenTopRevealed : model.chromeVisible
    }

    /// 缩略图栏、视频控制条：全屏时鼠标进入底部 120 点才出现
    private var bottomVisible: Bool {
        model.isFullScreen ? model.fullScreenBottomRevealed : model.chromeVisible
    }

    /// 左右箭头：全屏时鼠标在动、或者上下控件出现时显示
    private var arrowsVisible: Bool {
        model.isFullScreen
            ? model.fullScreenArrowsVisible || model.fullScreenBottomRevealed || model.fullScreenTopRevealed
            : model.chromeVisible
    }

    /// 全屏时菜单栏的高度：标题栏控件放在菜单栏下面
    private var menuBarHeight: CGFloat {
        let h = NSApp.mainMenu?.menuBarHeight ?? 0
        return h > 0 ? h : 24
    }

    // MARK: - 顶部：标题栏、类型切换

    @ViewBuilder
    private func topBar(_ layout: StageLayout) -> some View {
        let size = layout.size
        let compact = size.width < Theme.compactWidth
        let visible = topVisible
        let zoom = showsZoomControl ? model.zoomState : nil
        let widths = effectiveBarWidths
        let tier = TopBarTier.choose(width: size.width, widths: widths, hasZoom: zoom != nil)
        let center = tier.centerWidth(widths)
        // 文件名最多到筛选组左边再留 14，长名字截断，不和中间重叠
        let titleMax = max(0, size.width / 2 - center / 2 - TopBarTier.gap - 86)
        let _ = ShotHooks.logTopBar(width: size.width, widths: widths, tier: tier)
        ZStack(alignment: .top) {
          if let session = model.edit {
            EditTopBar(session: session, zoom: model.zoomState, narrow: editNarrow(size),
                       titleMax: max(0, size.width - 560),
                       onZoom: { model.zoom($0) }, onCancel: { model.cancelEdit() },
                       onSave: { model.saveEdit() }, onReplace: { model.requestReplace() })
          } else {
            // 标题栏（高 56）：红绿灯是系统的，这里只放文件名和右侧控件
            HStack(spacing: 14) {
                Color.clear.frame(width: 52, height: 12)   // 红绿灯占位
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        (model.current.map { Text(verbatim: $0.name) } ?? Text("一览"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text2)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: titleMax, alignment: .leading)
                    .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    // 顶部缩放控件（spec E1）：[缩放] [序号] [工具组]
                    if let zoom, tier.zoom != .menu {
                        ZoomControl(state: zoom, percentOnly: tier.zoom == .percent) { model.zoom($0) }
                    }
                    if let i = model.currentIndex {
                        CounterPill(index: i, total: model.items.count,
                                    rating: !model.stripVisible || layout.fullScreen ? model.currentRating : nil)
                    }
                    // 欢迎界面不显示工具组（设计稿“首次启动 · 欢迎”）
                    if model.hasOpenedFolder {
                        toolGroup(zoomInMenu: zoom != nil && tier.zoom == .menu)
                    }
                }
                .onHover { model.setHovering("tools", $0) }
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: Theme.titleBarHeight)

            if model.hasOpenedFolder {
                centerGroup(tier: tier)
                    // 悬停要写在撑大尺寸的 padding / frame / position 之前：macOS 15 上，写在后面会让撑出来的整片空白都吃掉点击
                    .onHover { model.setHovering("filter", $0) }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: tier.leftAligned ? .leading : .center)
                    .padding(.leading, tier.leftAligned ? TopBarTier.leftEdge : 0)
            }
            // 浏览时转过：工具组下方 4pt 的「保存旋转」胶囊（spec ED-41）
            if model.showsSaveRotation, let item = model.current {
                SaveRotationChip(lossless: model.currentSupportsLosslessRotation, menuOpen: model.rotationMenuOpen,
                                 copyName: EditNaming.baseName(item.url.deletingPathExtension().lastPathComponent, attempt: 1)
                                    + "." + (item.format == .raw ? (model.settings.editRawFormat == .heif ? "heic" : "jpg") : item.url.pathExtension),
                                 onSave: { model.saveRotation() },
                                 onToggleMenu: { model.rotationMenuOpen.toggle() },
                                 onRotateOriginal: { model.saveRotation(toOriginal: true) },
                                 onSaveCopy: { model.saveRotation(toOriginal: false) })
                    .onHover { model.setHovering("rotationChip", $0) }
                    .padding(.top, Theme.titleBarHeight + 4)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
          }
            topBarMeasurer
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // 全屏：从菜单栏下面滑出来
        .offset(y: layout.fullScreen ? (visible ? menuBarHeight : -Theme.titleBarHeight) : 0)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    /// 更新说明表单：挂在窗口上，背景压暗 38%（spec U3）
    @ViewBuilder
    private func updateSheet(_ size: CGSize) -> some View {
        if let release = updater.sheetRelease {
            ZStack(alignment: .top) {
                Color.black.opacity(0.38)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                UpdateSheet(release: release, current: updater.current.display, language: LanguageSettings.shared.running,
                            maxHeight: min(620, size.height - 80),
                            onSkip: { updater.skip() }, onLater: { updater.later() }, onDownload: { updater.openDownload() })
                    .padding(.top, 40)
            }
            .frame(width: size.width, height: size.height)
            .transition(.opacity)
        }
    }

    /// 测量视图一直在量；没有序号、没有工具组时按 0 算
    private var effectiveBarWidths: TopBarWidths {
        var widths = barWidths
        if model.currentIndex == nil { widths.counter = 0 }
        if !model.hasOpenedFolder { widths.tools = 0 }
        return widths
    }

    /// 缩放控件只在有可显示的图片时出现（spec E1-07）
    private var showsZoomControl: Bool {
        model.current != nil && model.failure == nil && model.displayedItem == model.current
    }

    private func toolGroup(zoomInMenu: Bool) -> ToolGroup {
        ToolGroup(
            enabled: model.current != nil && model.failure == nil,
            infoSelected: showsInfoPanel,
            rotateSelected: model.rotation != 0,
            editUnsupported: model.editUnsupported,
            onEdit: { model.enterEdit() },
            onRotate: { model.rotate(-1) },
            onInfo: model.toggleInfo,
            onReveal: model.revealCurrentInFinder,
            onCopyPath: model.copyCurrentPath,
            onOpen: model.showOpenPanel,
            zoomState: model.zoomState,
            zoomInMenu: zoomInMenu,
            onZoom: { model.zoom($0) },
            updateVersion: updater.dotVisible ? updater.available?.version : nil,
            onUpdate: { updater.showNotes() }
        )
    }

    /// 中间一组：全部 / 图片 / 视频 + 筛选按钮（spec R5-01）
    private func centerGroup(tier: TopBarTier) -> some View {
        HStack(spacing: TopBarTier.groupSpacing) {
            FilterControl(selection: model.filter, counts: model.filteredCounts, compact: tier.segSlim) { model.setFilter($0) }
            FilterButton(filter: model.browseFilter, mode: tier.filter, open: model.filterPanelOpen) { model.toggleFilterPanel() }
                .disabled(model.allItems.isEmpty)
                .opacity(model.allItems.isEmpty ? 0.35 : 1)
        }
    }

    /// 筛选面板：从按钮下方 8 展开，左缘对齐按钮；窗口窄时往左挪，不出窗口（spec R5-06、E1-13）。
    @ViewBuilder
    private func filterPanel(size: CGSize, tier: TopBarTier, widths: TopBarWidths) -> some View {
        let center = tier.centerWidth(widths)
        let groupLeft = tier.leftAligned ? TopBarTier.leftEdge : size.width / 2 - center / 2
        let buttonLeft = groupLeft + (tier.segSlim ? widths.segSlim : widths.segFull) + TopBarTier.groupSpacing
        let computed = max(8, min(buttonLeft, size.width - FilterPanel.width - 8))
        // 打开期间位置不动：按钮上的摘要变长变短会让按钮挪动，面板仍留在打开时的位置（窗口变窄时仍不出界）
        let left = min(panelAnchor ?? computed, max(8, size.width - FilterPanel.width - 8))
        FilterPanel(filter: model.browseFilter, type: model.filter, facets: model.filterFacets,
                    loadingRatings: !model.ratingsLoaded && model.browseFilter.rating.isActive,
                    onRating: { model.setRatingCriterion($0) },
                    onComparison: { model.setRatingComparison($0) },
                    onToggleFormat: { model.toggleFormat($0) },
                    onClear: { model.clearBrowseFilter() })
            // 面板自己吃掉落在它身上的点击，不让下面“点面板外关闭”收到
            .onTapGesture {}
            .onHover { model.setHovering("filterPanel", $0) }
            .padding(.top, 10 + 36 + 8)
            .padding(.leading, left)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // 点面板外关闭（spec R5-07）。点击区就是这一整层自己：macOS 15 上，
            // 单独垫在下面的透明点击层会被这一层挡住，收不到点击
            .contentShape(Rectangle())
            .onTapGesture { model.closeFilterPanel() }
            // 面板出现后先等布局稳定；之后按钮因摘要变化而挪动时，面板留在原处
            .task { try? await Task.sleep(for: .milliseconds(400)); panelSettled = true }
            .onChange(of: computed) { old, _ in if panelSettled, panelAnchor == nil { panelAnchor = old } }
            .onDisappear { panelAnchor = nil; panelSettled = false }
            .transition(.opacity.combined(with: .offset(y: -6)))
    }

    /// 空结果卡片里的条件：类型（不是全部时）+ 摘要，例如“视频 · ≥5 星”
    private var filterConditionText: String {
        var parts: [String] = []
        switch model.filter {
        case .images: parts.append(String(localized: "图片"))
        case .videos: parts.append(String(localized: "视频"))
        case .all: break
        }
        return (parts + model.browseFilter.summaryParts).joined(separator: " · ")
    }

    /// 隐藏的测量视图：量出各控件每种样子的宽度（文字随语言变化），供 TopBarTier 选档
    private var topBarMeasurer: some View {
        let sample = model.zoomState ?? ZoomState(percent: 100, isFit: true, canZoomIn: true, canZoomOut: false)
        let total = max(model.items.count, 1)
        return ZStack {
            FilterControl(selection: model.filter, counts: model.filteredCounts, compact: false) { _ in }
                .fixedSize().measure { barWidths.segFull = $0 }
            FilterControl(selection: model.filter, counts: model.filteredCounts, compact: true) { _ in }
                .fixedSize().measure { barWidths.segSlim = $0 }
            FilterButton(filter: model.browseFilter, mode: .full, open: false) {}
                .measure { barWidths.filterFull = $0 }
            FilterButton(filter: model.browseFilter, mode: .count, open: false) {}
                .measure { barWidths.filterCount = $0 }
            FilterButton(filter: model.browseFilter, mode: .icon, open: false) {}
                .measure { barWidths.filterIcon = $0 }
            ZoomControl(state: sample, percentOnly: false) { _ in }
                .fixedSize().measure { barWidths.zoomFull = $0 }
            ZoomControl(state: sample, percentOnly: true) { _ in }
                .fixedSize().measure { barWidths.zoomPercent = $0 }
            // 序号按最宽的情况量（带“· ★4”），切换缩略图栏时顶部栏不跳
            CounterPill(index: total - 1, total: total, rating: 4)
                .fixedSize().measure { barWidths.counter = $0 }
            toolGroup(zoomInMenu: false)
                .fixedSize().measure { barWidths.tools = $0 }
        }
        .opacity(0)
        .frame(width: 0, height: 0, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 图片区里的控件：箭头、播放按钮、视频控制条、缩略图栏

    @ViewBuilder
    private func stageControls(_ layout: StageLayout) -> some View {
        let size = layout.size
        if model.current != nil {
            ZStack(alignment: .topLeading) {
                arrows(layout)
                    .opacity(arrowsVisible ? 1 : 0)
                    .allowsHitTesting(arrowsVisible)
                Group {
                    if showsVideoGlyph {
                        VideoPosterOverlay { model.video.play() }
                            .onHover { model.setHovering("bigplay", $0) }
                            .position(x: size.width / 2, y: imageAreaCenterY(layout))
                    }
                }
                .opacity(model.chromeVisible || layout.fullScreen ? 1 : 0)
                .allowsHitTesting(model.chromeVisible || layout.fullScreen)

                bottomControls(layout)
                    .frame(width: size.width, height: size.height)
                    .offset(y: layout.fullScreen && !bottomVisible ? 24 : 0)
                    .opacity(bottomVisible ? 1 : 0)
                    .allowsHitTesting(bottomVisible)

                starBar(layout)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// 按键评星的闪现胶囊（spec R3a）：只在按 0–5 后的约 1 秒出现，不能点；水平居中，底边按缩略图栏 / 视频控制条让开
    @ViewBuilder
    private func starBar(_ layout: StageLayout) -> some View {
        let visible = model.ratingFlash != nil && model.pendingDelete == nil
        StarBar(rating: model.ratingFlash?.value ?? model.currentRating ?? 0, enabled: true, flash: model.ratingFlash)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, StarBar.bottomOffset(stripVisible: model.stripVisible, fullScreen: layout.fullScreen))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: visible)
    }

    private func bottomControls(_ layout: StageLayout) -> some View {
        let fs = layout.fullScreen
        return ZStack(alignment: .bottom) {
            if isVideo {
                VideoControlBar(video: model.video, settings: model.settings)
                    .frame(width: min(Theme.videoBarWidth, layout.size.width - 64))
                    .onHover {
                        model.setHovering("vbar", $0)
                        model.setFullScreenDockHover($0)
                    }
                    .padding(.bottom, videoBarBottom)
                    .transition(.opacity)
            }
            if model.stripVisible {
                ThumbnailDock(
                    rating: model.currentRating,
                    canRate: model.canRateCurrent,
                    // 视频：信息行中间不放星
                    onRate: model.currentIsRatable ? { model.rateCurrent($0, fromKeyboard: false) } : nil,
                    items: model.items,
                    current: model.current,
                    meta: dockMeta,
                    width: fs ? min(Theme.dockFullScreenWidth, layout.size.width - 48)
                        : min(layout.size.width - 64, Theme.dockMaxWidth),
                    fresh: model.freshURLs,
                    ratings: model.ratings,
                    onSelect: { model.select($0) }
                )
                .onHover {
                    model.setHovering("dock", $0)
                    model.setFullScreenDockHover($0)
                }
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func arrows(_ layout: StageLayout) -> some View {
        let size = layout.size
        // 箭头高度固定按“图片”的画面区域算，不随视频播放条让出的空间变化，切换图片/视频时箭头不跳
        let photoBottom = model.stripVisible ? Theme.imageInsetBottom : Theme.imageInsetBottomNoStrip
        let y = layout.fullScreen ? size.height / 2
            : Theme.imageInsetTop + (size.height - Theme.imageInsetTop - photoBottom) / 2
        // 全屏时离边 24，窗口里离边 20。信息面板打开时右箭头不移动，留在原处被面板盖住：
        // 同时淡出并且不接收点击，免得透过玻璃面板隐约看到它（跟面板一起动画，见 setInfoVisible 里的 withAnimation）
        return ZStack {
            NavArrow(isNext: false, enabled: model.canGoPrevious) { model.previous() }
                .position(x: layout.leftArrowX, y: y)
            NavArrow(isNext: true, enabled: model.canGoNext) { model.next() }
                .position(x: layout.rightArrowX, y: y)
                .opacity(layout.panelOpen ? 0 : 1)
                .allowsHitTesting(!layout.panelOpen)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 不随自动隐藏的：提示条、信息面板、删除确认

    @ViewBuilder
    private func overlays(_ layout: StageLayout) -> some View {
        let size = layout.size
        let toastTop: CGFloat = layout.fullScreen ? (model.fullScreenTopRevealed ? menuBarHeight + 66 : 24) : 66
        ZStack(alignment: .top) {
            if showsInfoPanel {
                let top = layout.fullScreen ? (model.fullScreenTopRevealed ? menuBarHeight + InfoPanel.top : 16) : InfoPanel.top
                // 面板浮在上面，但不能盖住缩略图栏和视频控制条：最多到它们上沿再留 12；
                // 缩略图栏关掉、或全屏时底部控件没出现，可以到距底 16。放不下的内容在面板里滚动
                let chromeTop = StageLayout.bottomChromeTop(isVideo: isVideo, stripVisible: model.stripVisible,
                                                            shown: layout.fullScreen ? bottomVisible : true)
                InfoPanel(
                    item: model.current,
                    content: model.info,
                    maxHeight: max(160, size.height - top - StageLayout.panelBottomMargin(chromeTop: chromeTop)),
                    onClose: { model.setInfoVisible(false) },
                    onReveal: model.revealCurrentInFinder,
                    onCopy: model.copyInfo,
                    onCopyCoordinates: model.copyCoordinates,
                    rating: model.currentRating,
                    showsRating: model.currentIsRatable,
                    ratingLocation: model.current.map { model.ratingLocationDescription(for: $0) } ?? "",
                    canRate: model.canRateCurrent,
                    onRate: { model.rateCurrent($0, fromKeyboard: false) }
                )
                .onHover { model.setHovering("info", $0) }
                .padding(.top, top)
                .padding(.trailing, InfoPanel.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity.combined(with: .offset(x: 24)))
            }

            // 提示卡片（快捷键变化、.xmp 说明）：顶部栏下面，不压暗、不挡操作
            if let hint = model.hint {
                HintCardView(card: hint, onPrimary: {
                    if hint == .shortcutsChanged { SettingsWindow.shared.show(pane: .shortcuts) }
                    model.dismissHint()
                }, onClose: { model.dismissHint() })
                .onHover { model.setHovering("hint", $0) }
                .padding(.top, toastTop)
                .transition(.opacity.combined(with: .offset(y: -8)))
            }

            // 新版本提示（spec U2-01、U2-02）：一次只显示一个卡片，快捷键 / .xmp 卡片优先
            if updater.noticeVisible, model.hint == nil, let release = updater.available {
                UpdateNoticeCard(version: "v" + release.version, current: updater.current.display, narrow: size.width < 760,
                                 onOpen: { updater.showNotes() }, onClose: { updater.dismissNotice() })
                    .onHover { model.setHovering("update", $0) }
                    .padding(.horizontal, size.width < 760 ? 16 : 0)
                    .padding(.top, size.width < 760 ? (layout.fullScreen ? toastTop - 6 : 60) : toastTop)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
            if updater.checking {
                UpdateCheckingChip().padding(.top, toastTop).transition(.opacity)
            }

            // 提示条画在信息面板上面：窄窗口里居中的提示条可能和面板重叠，不能被盖住
            if let toast = model.toast, toast.bottom {
                // 编辑保存后的提示条：缩略图栏上方 16（设计稿 edit 08）
                EditToastView(toast: toast, maxWidth: size.width - 64) { model.performToastAction($0) }
                    .onHover { model.toastHovered = $0 }
                    .padding(.bottom, model.stripVisible && !layout.fullScreen ? Theme.imageInsetBottom + 16 : 40)
                    .frame(width: size.width, height: size.height, alignment: .bottom)
                    .transition(.opacity)
                    .id(toast.serial)
            } else if let toast = model.toast {
                ToastView(toast: toast) { model.performToastAction($0) }
                    .padding(.top, toastTop)
                    .transition(.opacity)
                    .id(toast.serial)
            }

            if model.isDecodingRaw {
                RawDecodingChip().padding(.top, toastTop + 4).transition(.opacity)
            }

            // 没有权限读文件夹等打开问题：常驻提示，下次打开时消失
            if let message = model.openError, model.toast == nil {
                ToastView(toast: Toast(symbol: "lock", text: message, serial: 0))
                    .padding(.top, 66)
                    .padding(.horizontal, 40)
            }

            editAlerts(size)

            if let pending = model.pendingDelete {
                DeleteConfirm(
                    name: pending.name,
                    dontAsk: $model.deleteDontAsk,
                    onCancel: model.cancelDelete,
                    onConfirm: model.confirmDelete
                )
                .frame(width: size.width, height: size.height)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.hint)
        .animation(.easeOut(duration: 0.2), value: model.isDecodingRaw)
    }

    private var subtitle: String {
        guard let folder = model.folderURL else { return model.hasOpenedFolder ? "" : String(localized: "欢迎", comment: "欢迎界面时标题栏的副标题") }
        return folder.lastPathComponent
    }

    private var dockMeta: DockMeta {
        guard let item = model.current else { return DockMeta(name: "", dimensions: nil, trailing: "", failed: false) }
        if model.failure != nil {
            return DockMeta(name: item.name, dimensions: nil, trailing: item.formatName, failed: true)
        }
        let decoded = model.displayedItem == item ? model.displayed : nil
        var dims: String?
        // 像素尺寸按惯例不加千位分隔符（4032 × 3024）
        if let s = decoded?.pixelSize, s.width > 0 { dims = "\(Int(s.width)) × \(Int(s.height))" }
        var parts: [String] = []
        if let d = decoded?.duration { parts.append(Formatting.duration(d)) }
        parts.append(Formatting.fileSize(item.fileSize))
        var format = item.formatName
        if let detail = decoded?.formatDetail { format += " · \(detail)" }
        parts.append(format)
        return DockMeta(name: item.name, dimensions: dims, trailing: parts.joined(separator: " · "), failed: false)
    }

    // MARK: - 卡片

    @ViewBuilder
    private func cards(_ size: CGSize) -> some View {
        if let failure = model.failure, let item = model.current {
            ErrorCard(name: item.name, failure: failure, hasNext: model.canGoNext,
                      onReveal: model.revealCurrentInFinder, onNext: model.next)
                .offset(y: -34)
                .onHover { model.setHovering("card", $0) }
        } else if model.hasOpenedFolder && model.allItems.isEmpty {
            EmptyFolderCard(onOpen: model.showOpenPanel)
        } else if model.showsEmptyFilterResult {
            EmptyFilterResultCard(condition: filterConditionText, onClear: model.clearBrowseFilter)
                .onHover { model.setHovering("card", $0) }
        } else if !model.hasOpenedFolder {
            WelcomeCard(
                recents: model.recents.existing(limit: 3),
                onOpen: model.showOpenPanel,
                onOpenRecent: { model.open($0.url) },
                onRemoveRecent: { model.recents.remove($0) }
            )
        }
    }

    // MARK: - 窗口

    private func setTrafficLights(visible: Bool) {
        guard let window else { return }
        let visible = visible || window.styleMask.contains(.fullScreen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.15 : 0.35
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}

/// 舞台布局规则（设计稿 08 · 信息面板）：信息面板在任何窗口宽度下都浮在图片上。
/// 图片、视频、缩略图栏、视频控制条都按整个窗口居中，开关面板时不移动；
/// 右箭头也不移动，面板打开时留在原处被面板盖住（隐藏且不能点）
struct StageLayout {
    let size: CGSize
    let fullScreen: Bool
    let panelOpen: Bool

    /// 箭头按钮直径
    nonisolated static let arrowSize: CGFloat = 44

    /// 箭头离窗口边：全屏 24，窗口里 20
    var edge: CGFloat { fullScreen ? 24 : 20 }
    /// 图片区左右边距：和面板无关
    var imageSideInset: CGFloat { fullScreen ? 0 : Theme.imageInsetSide }
    /// 面板左边的 x
    var panelLeft: CGFloat { size.width - InfoPanel.trailing - InfoPanel.width }
    /// 箭头中心的 x
    var leftArrowX: CGFloat { edge + Self.arrowSize / 2 }
    var rightArrowX: CGFloat { size.width - edge - Self.arrowSize / 2 }

    /// 底部控件（视频控制条或缩略图栏）上沿离窗口底边的距离；没有显示底部控件时是 0
    static func bottomChromeTop(isVideo: Bool, stripVisible: Bool, shown: Bool) -> CGFloat {
        guard shown else { return 0 }
        if isVideo {
            return (stripVisible ? Theme.videoBarBottom : Theme.videoBarBottomNoStrip) + Theme.videoBarHeight
        }
        return stripVisible ? Theme.imageInsetBottom : 0
    }

    /// 信息面板底边离窗口底边至少多少：在底部控件上面留 12；没有底部控件时距底 16
    static func panelBottomMargin(chromeTop: CGFloat) -> CGFloat {
        chromeTop > 0 ? chromeTop + 12 : 16
    }
}

/// 环境光背景：当前图片模糊后铺满窗口，再叠一层暗角（设计稿 .amb + .vig）
struct AmbientBackground: View {
    let image: CGImage?
    let id: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        // 设计稿 inset:-18%：比窗口大一圈，模糊边缘不露底
                        .frame(width: geo.size.width * 1.36, height: geo.size.height * 1.36)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .id(id)
                        .transition(.opacity)
                } else {
                    // 没有图片（出错、空文件夹、欢迎）时的环境光，用品牌色（设计稿“无法打开”画板）：
                    // 左上 brand-teal-deep 70%，右下 brand-sun 15% → 半径一半处 brand-teal 16%（一点暖色太阳光）。
                    // 透明度按亮度（0.2126R+0.7152G+0.0722B）算过：原来左上 indigo 亮度约 51×0.70≈36、
                    // 右下 plum 约 76×0.46≈35；现在 teal-deep 约 49×0.70≈34、sun 约 228×0.15≈34，
                    // 两团光和原来一样暗，卡片和文字可读性不变
                    ZStack {
                        RadialGradient(colors: [Theme.Brand.tealDeep.opacity(0.70), .clear],
                                       center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0,
                                       endRadius: max(geo.size.width, geo.size.height) * 0.6)
                        RadialGradient(stops: [.init(color: Theme.Brand.sun.opacity(0.15), location: 0),
                                               .init(color: Theme.Brand.teal.opacity(0.16), location: 0.5),
                                               .init(color: .clear, location: 1)],
                                       center: UnitPoint(x: 0.75, y: 0.7), startRadius: 0,
                                       endRadius: max(geo.size.width, geo.size.height) * 0.6)
                    }
                    .blur(radius: 40)
                    .brightness(-0.04)   // 设计稿 brightness(.8)，颜色本身很暗，约等于整体压暗一点
                    .transition(.opacity)
                }
                // 暗角：radial-gradient(120% 90% at 50% 45%, 透明 40%, 黑 50% 100%)；
                // 设计稿里没有图片的状态（出错、空文件夹、欢迎）不加暗角
                if image != nil {
                EllipticalGradient(
                    stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.5), location: 1)],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                )
                .frame(width: geo.size.width * 2.4, height: geo.size.height * 1.8)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.45)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.5), value: id)
        }
        .allowsHitTesting(false)
    }
}

/// 键盘和鼠标移动的事件监听
@MainActor
final class EventMonitors {
    private var tokens: [Any] = []

    func install(model: BrowserModel, window: @escaping @MainActor () -> NSWindow?) {
        remove()
        tokens.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 只处理主窗口里、没有弹出面板时的按键
            guard let w = window(), event.window === w, w.attachedSheet == nil else { return event }
            return model.handleKey(event) ? nil : event
        } as Any)
        tokens.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown]) { event in
            if let w = window(), event.window === w {
                model.noteMouseActivity()
                if model.isFullScreen, event.type == .mouseMoved || event.type == .leftMouseDragged {
                    let height = w.contentView?.bounds.height ?? w.frame.height
                    model.fullScreenMouseMoved(yFromTop: height - event.locationInWindow.y, height: height)
                }
            }
            return event
        } as Any)
    }

    func remove() {
        tokens.forEach { NSEvent.removeMonitor($0) }
        tokens.removeAll()
    }
}

/// 取得 SwiftUI 所在的 NSWindow，并按设计稿配置：透明标题栏、内容铺满、深色
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var keeper: TrafficLightKeeper?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { keeper = nil; return }
            WindowStyler.configure(window)
            onWindow?(window)
            // 系统在很多时候会把红绿灯放回默认位置（缩放、退出全屏、换屏幕、标题栏重新布局……），
            // 由它在这些时候都重新摆正
            keeper = TrafficLightKeeper(window: window)
            // 上次的位置可能在已经断开的显示器上：启动时（等系统恢复完窗口位置）和显示器变化时检查
            WindowPlacement.ensureOnScreen(window)
            DispatchQueue.main.async { [weak window] in
                MainActor.assumeIsolated { if let window { WindowPlacement.ensureOnScreen(window) } }
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated { if let window { WindowPlacement.ensureOnScreen(window) } }
            })
        }

        override func layout() {
            super.layout()
            keeper?.place()
        }
    }
}

@MainActor
enum WindowStyler {
    static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 5 / 255, green: 5 / 255, blue: 6 / 255, alpha: 1)
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 640, height: 440)
        window.isMovableByWindowBackground = false
        window.titlebarSeparatorStyle = .none
        // 系统设置里选了「总是以标签页打开」时，窗口会带标签栏，标题栏结构跟着变，红绿灯位置就不对了
        window.tabbingMode = .disallowed
    }

    /// 设计稿标题栏高 56，红绿灯（12pt，间距 8）距左 20、垂直居中。
    /// 系统默认标题栏只有约 28pt，这里把标题栏容器加高到 56，再把三个按钮摆到中线上
    /// left：第一个按钮（12pt）左边距；height：标题栏高，按钮在里面垂直居中
    static func positionTrafficLights(_ window: NSWindow, left: CGFloat = 20, height: CGFloat = 56) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return }
        var frame = container.frame
        if frame.height != height || frame.origin.y != window.frame.height - height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        for (button, origin) in buttonOrigins(window, titlebar: titlebar, left: left)
        where button.frame.origin != origin {
            button.setFrameOrigin(origin)
        }
    }

    /// 三个按钮应在的位置（标题栏坐标）
    private static func buttonOrigins(_ window: NSWindow, titlebar: NSView, left: CGFloat) -> [(NSButton, NSPoint)] {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        return buttons.enumerated().map { i, button in
            let size = button.frame.size
            return (button, NSPoint(x: left + CGFloat(i) * 20 - (size.width - 12) / 2,
                                    y: (titlebar.frame.height - size.height) / 2))
        }
    }

    /// 红绿灯不在设计的位置上（标题栏容器高度、位置或按钮位置不对）
    static func trafficLightsNeedPlacing(_ window: NSWindow, left: CGFloat = 20, height: CGFloat = 56) -> Bool {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview else { return false }
        if container.frame.height != height || container.frame.origin.y != window.frame.height - height { return true }
        return buttonOrigins(window, titlebar: titlebar, left: left).contains { $0.0.frame.origin != $0.1 }
    }
}

/// 让红绿灯一直待在设计的位置（spec F1-02）。
/// 系统会在很多时候把标题栏容器和三个按钮放回默认位置：缩放、结束拖拽调整大小、成为 / 失去主窗口和键窗口、
/// 退出全屏、换屏幕或缩放比例、标题栏自己重新布局等。这里在所有这些时候重新摆正，
/// 并直接盯着标题栏容器和按钮的 frame：被别人改了就在下一轮摆回来。
/// 摆正时只在位置真的不同时才设置 frame，自己引起的 frame 通知下一轮再看时已经一致，不会循环；
/// 万一系统和这里反复争（1 秒内超过 30 次），先停下，等下一次窗口事件再摆。全屏和进出全屏的过程中不摆
@MainActor
final class TrafficLightKeeper {
    private weak var window: NSWindow?
    private let left: CGFloat
    private let height: CGFloat
    /// 只在主线程改；deinit 里移除
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var watchedViews: [ObjectIdentifier] = []
    private var pending = false
    private var transitioning = false
    private var transitionSerial = 0
    private var corrections: [Date] = []
    /// 测试用：摆正（真的改了位置）的次数
    private(set) var placements = 0

    init(window: NSWindow, left: CGFloat = 20, height: CGFloat = 56) {
        self.window = window
        self.left = left
        self.height = height
        let center = NotificationCenter.default
        let events: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in events {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowEvent() }
            })
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginTransition() }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.transitioning = false
                    self?.windowEvent()
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowEvent() }
        })
        place()
        // 启动时系统还会再布局一次标题栏（恢复窗口位置、第一次显示），之后再补一次
        placeSoon()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 进出全屏的动画中不摆；万一没收到结束通知（进出全屏失败），3 秒后恢复
    private func beginTransition() {
        transitioning = true
        transitionSerial += 1
        let serial = transitionSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitioning, self.transitionSerial == serial else { return }
                self.transitioning = false
                self.windowEvent()
            }
        }
    }

    /// 窗口事件：重新开始计数，立即摆一次，下一轮再看一次（有的系统调整在通知之后才发生）
    private func windowEvent() {
        corrections.removeAll()
        place()
        placeSoon()
    }

    /// 下一轮再摆（合并多次请求）
    func placeSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.place()
            }
        }
    }

    func place() {
        guard let window, !transitioning, !window.styleMask.contains(.fullScreen) else { return }
        watchFrames(window)
        guard WindowStyler.trafficLightsNeedPlacing(window, left: left, height: height) else { return }
        let now = Date()
        corrections = corrections.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard corrections.count <= 30 else { return }
        WindowStyler.positionTrafficLights(window, left: left, height: height)
        placements += 1
    }

    /// 标题栏容器、标题栏和三个按钮的 frame 被改动时（系统重新布局）下一轮摆回来
    private func watchFrames(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton), let titlebar = close.superview,
              let container = titlebar.superview else { return }
        let views = [container, titlebar] + [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
        let ids = views.map(ObjectIdentifier.init)
        guard ids != watchedViews else { return }
        watchedViews = ids
        for view in views {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeSoon() }
            })
        }
    }
}

extension View {
    /// 量出视图的宽度（顶部栏收缩用）
    func measure(_ report: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
    }
}
