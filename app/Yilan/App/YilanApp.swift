import AppKit
import OSLog
import SwiftUI

enum Log {
    static let app = Logger(subsystem: "com.yilan.viewer", category: "app")
}

@main
struct YilanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 命令行参数里的文件路径默认会被 AppKit 当作“打开文件”事件，这时 SwiftUI 不创建主窗口；
        // 关掉这个行为，改由 applicationDidFinishLaunching 自己读参数
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        // 要在显示任何文字之前：系统语言不是中文也不是英文时改用英文
        LanguageSettings.applyFallbackAtLaunch()
    }

    var body: some Scene {
        Window("一览", id: "main") {
            RootView()
                .frame(minWidth: 640, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
        // 单窗口场景默认会“记住”上次被关掉，导致下次启动没有窗口；每次启动都打开主窗口
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands { AppCommands() }

        // 设置（⌘,）：设计稿 05 · 设置

    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 访达“打开方式”、拖到程序坞图标、`open -a` 打开的文件
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        BrowserModel.shared.open(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.shared.saveRecentCover()
        UpdateChecker.shared.stopPeriodicChecks()
        // 保存旋转留着撤销用的原文件副本：退出后用不上了（F2-03）
        RotationBackupStore.removeAll()
    }

    /// 还有没写完的星级时先等一等（最多 3 秒，spec S-20）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 批量操作进行中：等这一批做完再退（spec X3-08）
        if BrowserModel.shared.batchRunning {
            BrowserModel.shared.terminateAfterBatch = true
            return .terminateLater
        }
        guard BrowserModel.shared.pendingRatingWrites > 0 else { return .terminateNow }
        Task { @MainActor in
            await BrowserModel.shared.flushRatingWrites()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Perf.mark("didFinishLaunching")
        MemoryPressureMonitor.start()
        // 缩略图磁盘缓存：后台清理太旧的、超出上限的
        Task.detached(priority: .background) {
            ThumbnailGenerator.prune()
            // 上次没正常退出时留下的保存旋转副本
            RotationBackupStore.removeStale()
        }
        // 调试用：命令行参数里的路径（`Yilan.app/Contents/MacOS/Yilan /path/to/file`）
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first, FileManager.default.fileExists(atPath: path), !BrowserModel.shared.hasOpenedFolder {
            BrowserModel.shared.open(URL(fileURLWithPath: path))
        }
        // 从 v0.2 升级后第一次启动：说明快捷键变化（spec K-10）
        BrowserModel.shared.showUpgradeNoticeIfNeeded()
        // 更新检查：启动约 3 秒后在后台（spec U1-01，距上次自动检查不到 1 小时就不联网）；跑测试和截图时不联网
        let updater = UpdateChecker.shared
        updater.toast = { symbol, text, warning in
            BrowserModel.shared.showToast(symbol: symbol, text: text, tone: warning ? .warning : .normal, duration: 4)
        }
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTests && ShotHooks.update == nil && !CommandLine.arguments.contains(where: { $0.hasPrefix("--shot-") }) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                // 这次启动已经有快捷键变化提示：新版本提醒顺延到下次启动（spec U2-03）
                await updater.launchCheck(deferNotice: BrowserModel.shared.upgradeNoticeShown)
                // 一直开着时每 6 小时在后台再查一次，只出 ⋯ 上的小点（F2-01）
                updater.startPeriodicChecks()
            }
        }
        // 访达“打开方式”的文件在这之前已经送到；稍等一下再决定要不要打开上次的文件夹
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            BrowserModel.shared.reopenLastFolderIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 菜单栏：文件 / 显示 / 前往（设计稿 05 系统界面）
struct AppCommands: Commands {
    private var model: BrowserModel { BrowserModel.shared }
    private var updater: UpdateChecker { UpdateChecker.shared }

    var body: some Commands {
        // 设置窗口由 AppKit 承载（见 SettingsWindow），菜单项自己接
        // 一览菜单：有新版本时第一项（spec U2-04）、关于下面的“检查更新…”（spec U6-01）
        CommandGroup(before: .appInfo) {
            if let release = updater.available, updater.dotVisible || updater.noticeVisible {
                Button(String(localized: "有新版本 v\(release.version)…", comment: "菜单：有新版本；%@ 是版本号")) { updater.showNotes() }
                Divider()
            }
        }
        CommandGroup(after: .appInfo) {
            if UpdateChecker.isAvailable {
                Button("检查更新…") { Task { await updater.checkNow() } }
                    .disabled(updater.checking)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("打开…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("打开最近使用") {
                let recents = model.recents.existing()
                ForEach(recents) { folder in
                    Button(folder.name) { model.open(folder.url) }
                }
                if !recents.isEmpty { Divider() }
                Button("清除菜单") { model.recents.clear() }
                    .disabled(recents.isEmpty)
            }
            // 评星（spec MN-02）：快捷键 1–5、0。评星功能关掉后整个子菜单不出现（spec T2-03）
            if model.ratingEnabled {
            Divider()
            Menu("评星") {
                ForEach(1...5, id: \.self) { n in
                    Button(String(localized: "\(n) 星", comment: "文件 › 评星 子菜单")) { model.rateCurrent(n, fromKeyboard: false) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
                }
                Divider()
                Button("清除星级") { model.rateCurrent(0, fromKeyboard: false) }
                    .keyboardShortcut("0", modifiers: [])
            }
            .disabled(!model.currentIsRatable || !model.mainWindowIsKey || model.pendingDelete != nil || model.isEditing || model.batchRunning)
            }
        }
        CommandGroup(after: .newItem) {
            Divider()
            // 图标视图里作用于选中的文件，多选时文字带数量，没有选中时置灰（spec MB-05）
            Button("在访达中显示") { model.perform(.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isGrid && model.selectionCount == 0)
            Button(model.menuTitle(.copyPath)) { model.perform(.copyPath) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.isGrid && model.selectionCount == 0)
            Divider()
            Button("向右旋转") { model.rotate(1) }
                .keyboardShortcut("r", modifiers: [])
                .disabled(model.current == nil || model.isGrid)
            Button("向左旋转") { model.rotate(-1) }
                .keyboardShortcut("r", modifiers: [.shift])
                .disabled(model.current == nil || model.isGrid)
            // 编辑：裁切、旋转、调整尺寸（spec ED-03）；编辑功能关掉后不出现（spec T2-12）
            if model.editEnabled {
                Button("编辑") { model.enterEdit() }
                    .keyboardShortcut("e", modifiers: [])
                    .disabled(!model.canEditCurrent || model.isEditing || !model.mainWindowIsKey || model.isGrid)
                // 导出为 JPEG（spec C6-03）：一直有；不是 RAW、出错卡片、多选、正在编辑、正在导出时置灰。简洁模式里没有（spec C6-12）
                Button("导出为 JPEG") { model.exportCurrentAsJPEG() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportCurrent || !model.mainWindowIsKey)
            }
            // 复制到 / 移动到文件夹（spec R9-01）：当前文件或选中的文件。简洁模式里没有
            if model.transferEnabled {
                Divider()
                Button("复制到文件夹…") { model.perform(.copyTo) }
                    .disabled(!model.canTransfer)
                Button("移动到文件夹…") { model.perform(.moveTo) }
                    .disabled(!model.canTransfer)
            }
            Divider()
            // 只在主窗口在前时可用：设置窗口的输入框里按 ⌫ 是删字
            Button(model.menuTitle(.trash)) { model.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.isMultiSelection ? !model.canBatchDelete : !model.canDelete)
        }
        // 编辑 › 撤销“移到废纸篓”（⌘Z）。设置窗口在前时交给输入框自己撤销
        CommandGroup(replacing: .undoRedo) {
            Button(model.canUndo && model.mainWindowIsKey ? model.undoMenuTitle : String(localized: "撤销")) { model.undoFromMenu() }
                .keyboardShortcut("z")
                .disabled(model.mainWindowIsKey && (!model.canUndo || model.isEditing))
            Button("重做") { model.redoFromMenu() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.mainWindowIsKey)
        }
        // 编辑 › 拷贝、全选（spec MB-01、MB-02）：换掉系统默认的剪切 / 拷贝 / 粘贴 / 删除 / 全选一组。
        // 焦点在文字输入框里时照样是文字的拷贝和全选
        CommandGroup(replacing: .pasteboard) {
            Button(model.copyActsOnFiles ? model.menuTitle(.copy) : String(localized: "拷贝", comment: "菜单：把文件拷贝到剪贴板")) { model.copyFromMenu() }
                .keyboardShortcut("c")
                .disabled(model.copyActsOnFiles && model.selectionCount == 0)
            Divider()
            // 画廊视图里全选和取消全选置灰（spec MB-02）；焦点在文字上时交给文字
            Button("全选") { model.selectAllFromMenu() }
                .keyboardShortcut("a")
                .disabled(model.copyActsOnFiles && (!model.isGrid || model.items.isEmpty))
            Button("取消全选") { model.deselectAllInGrid() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!model.copyActsOnFiles || !model.isGrid || model.grid.selection.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            // 简洁模式：只保留看图（spec 第 8 节）。正在编辑时不能打开
            Toggle("简洁模式", isOn: Binding(get: { model.simpleMode }, set: { model.setSimpleMode($0) }))
                .disabled(model.isEditing && !model.simpleMode)
            Divider()
            // 两种视图：当前的打勾，G 只标在另一项上（spec MB-03）
            viewToggle("画廊视图", .gallery)
            viewToggle("图标视图", .grid)
            Divider()
            filterToggle("全部", .all, key: "1")
            filterToggle("只看图片", .images, key: "2")
            filterToggle("只看视频", .videos, key: "3")
            Divider()
            // 筛选（spec F-10）；筛选功能关掉后不出现（spec T2-09）
            if model.filterEnabled {
                Button("筛选…") { model.toggleFilterPanel() }
                    .keyboardShortcut("f")
                    .disabled(!model.hasOpenedFolder || model.allItems.isEmpty || model.isEditing)
                Button("清除筛选") { model.clearBrowseFilter() }
                    .disabled(!model.browseFilter.isActive || model.isEditing)
                Divider()
            }
            // 数字键让给评星：⌘9 适应窗口、⌘0 实际大小、Z 切换（spec 4.2）
            // 图标视图里没有缩放图片这回事（spec MB-04）：这几项置灰，放大 / 缩小改成调缩略图大小
            Button("适应窗口") { model.zoom(.fit) }.keyboardShortcut("9").disabled(model.isGrid)
            Button("实际大小") { model.zoom(.actualSize) }.keyboardShortcut("0").disabled(model.isGrid)
            Button("切换适应窗口 / 实际大小") { model.zoom(.toggle) }.keyboardShortcut("z", modifiers: []).disabled(model.isGrid)
            Button(model.isGrid ? "放大缩略图" : "放大") { if model.isGrid { model.stepGridSize(larger: true) } else { model.zoom(.zoomIn) } }
                .keyboardShortcut("+")
                .disabled(model.isGrid && model.gridSize == GridSize.allCases.last)
            Button(model.isGrid ? "缩小缩略图" : "缩小") { if model.isGrid { model.stepGridSize(larger: false) } else { model.zoom(.zoomOut) } }
                .keyboardShortcut("-")
                .disabled(model.isGrid && model.gridSize == GridSize.allCases.first)
            Divider()
            Toggle("缩略图栏", isOn: Binding(
                get: { model.stripVisible },
                set: { visible in withAnimation(.easeInOut(duration: 0.25)) { model.stripVisible = visible } }
            ))
            .keyboardShortcut("t", modifiers: [])
            .disabled(model.isGrid)
            Toggle("信息面板", isOn: Binding(
                get: { model.infoVisible },
                set: { model.setInfoVisible($0) }
            ))
            .keyboardShortcut("i", modifiers: [])
            .disabled((model.current == nil && !(model.isGrid && model.hasOpenedFolder)) || !model.mainWindowIsKey || model.isEditing)
            Divider()
            Button(model.isFullScreen ? "退出全屏幕" : "进入全屏幕") { model.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!model.mainWindowIsKey || model.pendingDelete != nil)
            Divider()
        }
        CommandMenu("前往") {
            // 编辑中不切图（spec ED-08）
            Group {
                // 图标视图里上一个 / 下一个是 ←、→；没有选中时置灰（spec MB-06）
                Button("上一个") { model.goPrevious() }.keyboardShortcut(model.isGrid ? .leftArrow : .upArrow, modifiers: [])
                    .disabled(model.isGrid && model.grid.selection.isEmpty)
                Button("下一个") { model.goNext() }.keyboardShortcut(model.isGrid ? .rightArrow : .downArrow, modifiers: [])
                    .disabled(model.isGrid && model.grid.selection.isEmpty)
                Button("第一个") { model.goEdge(first: true) }.keyboardShortcut(.home, modifiers: [])
                Button("最后一个") { model.goEdge(first: false) }.keyboardShortcut(.end, modifiers: [])
            }
            .disabled(model.isEditing)
        }
    }

    /// 带勾选标记的类型菜单项（设计稿“菜单 · 显示”）
    @ViewBuilder
    private func viewToggle(_ title: LocalizedStringKey, _ mode: ViewMode) -> some View {
        let toggle = Toggle(title, isOn: Binding(get: { model.viewMode == mode }, set: { _ in model.setViewMode(mode) }))
            .disabled(!model.canSwitchView || !model.mainWindowIsKey)
        if model.viewMode == mode { toggle } else { toggle.keyboardShortcut("g", modifiers: []) }
    }

    private func filterToggle(_ title: LocalizedStringKey, _ filter: MediaFilter, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.filter == filter },
            set: { _ in model.setFilter(filter) }
        ))
        .keyboardShortcut(key)
        .disabled((model.filteredCounts[filter] ?? 0) == 0 || model.isEditing)
    }
}
