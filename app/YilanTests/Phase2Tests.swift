import Foundation
import Testing
@testable import Yilan

/// 每个测试用一份独立的 UserDefaults，不碰真实设置
private func freshDefaults() -> UserDefaults {
    let name = "yilan-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func tempFolder(_ files: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yilan-p2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in files { try Data([0]).write(to: dir.appendingPathComponent(name)) }
    return dir
}

@Suite("设置")
@MainActor
struct AppSettingsTests {
    @Test("默认值：不循环、不自动播放、记住类型、到头停住")
    func defaults() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.loopVideo == false)
        #expect(s.autoplayVideo == false)
        #expect(s.startFilter == .last)
        #expect(s.wrapAround == false)
        #expect(s.reopenLastFolder == true)
        #expect(s.autoHideControls == false)
        #expect(s.hideDelay == 2)
        #expect(s.ambientBackground == true)
        #expect(s.scrollZooms == false)
        #expect(s.initialFilter() == .all)
    }

    @Test("修改后写入存储，重新读取还在")
    func persists() {
        let d = freshDefaults()
        let s = AppSettings(defaults: d)
        s.loopVideo = true
        s.autoplayVideo = true
        s.wrapAround = true
        s.hideDelay = 5
        s.ambientBackground = false
        s.reopenLastFolder = false
        let again = AppSettings(defaults: d)
        #expect(again.loopVideo && again.autoplayVideo && again.wrapAround)
        #expect(again.hideDelay == 5)
        #expect(!again.ambientBackground && !again.reopenLastFolder)
    }

    @Test("默认显示：上次的选择，或固定一种")
    func startFilter() {
        let d = freshDefaults()
        let s = AppSettings(defaults: d)
        s.saveFilter(.videos)
        #expect(AppSettings(defaults: d).initialFilter() == .videos)
        s.startFilter = .all
        #expect(AppSettings(defaults: d).initialFilter() == .all)
        s.startFilter = .images
        #expect(AppSettings(defaults: d).initialFilter() == .images)
    }

    @Test("旧版的“记住上次的类型”关闭时，迁移成“全部”")
    func migratesRememberFilter() {
        let d = freshDefaults()
        d.set(false, forKey: AppSettings.Key.rememberFilter)
        #expect(AppSettings(defaults: d).startFilter == .all)
    }

    @Test("隐藏延迟限制在 1–10 秒")
    func clampsDelay() {
        let d = freshDefaults()
        d.set(60.0, forKey: AppSettings.Key.hideDelay)
        #expect(AppSettings(defaults: d).hideDelay == 10)
    }

    @Test("滚轮：默认切换，按住 ⌃ 缩放；选了缩放后反过来")
    func scroll() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(!s.scrollShouldZoom(modifierPressed: false))
        #expect(s.scrollShouldZoom(modifierPressed: true))
        s.scrollZooms = true
        #expect(s.scrollShouldZoom(modifierPressed: false))
        #expect(!s.scrollShouldZoom(modifierPressed: true))
    }
}

@Suite("上下切换")
struct NavigationTests {
    @Test("到头停住")
    func stops() {
        #expect(Navigation.target(from: 0, delta: 1, count: 3, wrap: false) == 1)
        #expect(Navigation.target(from: 2, delta: 1, count: 3, wrap: false) == nil)
        #expect(Navigation.target(from: 0, delta: -1, count: 3, wrap: false) == nil)
        #expect(Navigation.target(from: 0, delta: 1, count: 0, wrap: true) == nil)
    }

    @Test("循环到第一个 / 最后一个")
    func wraps() {
        #expect(Navigation.target(from: 2, delta: 1, count: 3, wrap: true) == 0)
        #expect(Navigation.target(from: 0, delta: -1, count: 3, wrap: true) == 2)
        // 只有一个文件时不算“循环”
        #expect(Navigation.target(from: 0, delta: 1, count: 1, wrap: true) == nil)
    }
}

@Suite("最近打开")
@MainActor
struct RecentFoldersTests {
    @Test("同一个文件夹只留一条并移到最前，最多 10 条")
    func dedupeOrderLimit() {
        let r = RecentFolders(defaults: freshDefaults())
        for i in 0..<12 { r.record(folder: URL(fileURLWithPath: "/tmp/f\(i)"), cover: nil, itemCount: i) }
        #expect(r.folders.count == RecentFolders.limit)
        #expect(r.folders.first?.path == "/tmp/f11")
        r.record(folder: URL(fileURLWithPath: "/tmp/f5"), cover: nil, itemCount: 99)
        #expect(r.folders.first?.path == "/tmp/f5")
        #expect(r.folders.first?.itemCount == 99)
        #expect(r.folders.filter { $0.path == "/tmp/f5" }.count == 1)
    }

    @Test("保存后重新读取；更新封面不改顺序；移除和清空")
    func persistence() {
        let d = freshDefaults()
        let r = RecentFolders(defaults: d)
        r.record(folder: URL(fileURLWithPath: "/tmp/a"), cover: nil, itemCount: 1)
        r.record(folder: URL(fileURLWithPath: "/tmp/b"), cover: nil, itemCount: 2)
        r.updateCover(folder: URL(fileURLWithPath: "/tmp/a"), cover: URL(fileURLWithPath: "/tmp/a/x.jpg"))
        let again = RecentFolders(defaults: d)
        #expect(again.folders.map(\.path) == ["/tmp/b", "/tmp/a"])
        #expect(again.folders.last?.coverPath == "/tmp/a/x.jpg")
        again.remove(again.folders[0])
        #expect(RecentFolders(defaults: d).folders.map(\.path) == ["/tmp/a"])
        again.clear()
        #expect(RecentFolders(defaults: d).folders.isEmpty)
    }

    @Test("被删掉的文件夹不显示（在后台检查后）")
    func existingOnly() async throws {
        let r = RecentFolders(defaults: freshDefaults())
        let real = try tempFolder([])
        r.record(folder: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)"), cover: nil, itemCount: 0)
        r.record(folder: real, cover: nil, itemCount: 0)
        await r.refreshAvailability()
        #expect(r.existing().map(\.path) == [real.standardizedFileURL.path])
        // 检查完之后文件夹被删：下次检查后不再显示
        try FileManager.default.removeItem(at: real)
        await r.refreshAvailability()
        #expect(r.existing().isEmpty)
    }

    @Test("没挂载的卷上的文件夹：不访问磁盘直接算不在")
    func unmountedVolume() {
        let d = freshDefaults()
        let path = "/Volumes/yilan-not-mounted-\(UUID().uuidString)/Photos"
        let r = RecentFolders(defaults: d)
        r.record(folder: URL(fileURLWithPath: path), cover: nil, itemCount: 3)
        r.record(folder: URL(fileURLWithPath: "/tmp"), cover: nil, itemCount: 0)
        #expect(RecentFolders.isOnUnmountedVolume(path, mounted: RecentFolders.mountedVolumeRoots()))
        #expect(!RecentFolders.isOnUnmountedVolume("/Users/x/Pictures", mounted: []))
        #expect(!RecentFolders.isOnUnmountedVolume("/Volumes/yilan-x/a", mounted: ["/Volumes/yilan-x"]))
        // 下次启动（新实例，还没在后台检查过）：立刻就能排除，不用等检查
        let next = RecentFolders(defaults: d)
        #expect(next.existing().map(\.path) == ["/tmp"])
    }
}

@Suite("拖入说明")
struct DropSummaryTests {
    @Test("数量文案（中文）")
    func countText() {
        let zh = Locale(identifier: "zh-Hans")
        #expect(DropSummary.countText(images: 112, videos: 16, locale: zh) == "共 128 个文件：112 张图片，16 个视频")
        #expect(DropSummary.countText(images: 3, videos: 0, locale: zh) == "共 3 个文件：3 张图片")
        #expect(DropSummary.countText(images: 0, videos: 0, locale: zh) == "这个文件夹里没有图片或视频")
        #expect(DropSummary.countText(images: 0, videos: 0, inParentFolder: true, locale: zh) == "所在文件夹里没有其他图片或视频")
    }

    @Test("拖入文件夹、文件、不支持的文件")
    func describe() throws {
        let dir = try tempFolder(["a.jpg", "b.png", "c.mov", "notes.txt"])
        let folder = DropSummary.describe(dir)
        #expect(folder.acceptable)
        // 文案跟着当前界面语言走，这里只比较数量是否算对
        #expect(folder.detail == DropSummary.countText(images: 2, videos: 1))
        let file = DropSummary.describe(dir.appendingPathComponent("a.jpg"))
        #expect(file.acceptable)
        #expect(file.detail == DropSummary.countText(images: 2, videos: 1, inParentFolder: true))
        #expect(DropSummary.describe(dir.appendingPathComponent("notes.txt")).acceptable == false)
    }
}

@Suite("视频控制")
struct VideoTransportTests {
    @Test("快进快退限制在 0 到时长之间")
    func seek() {
        #expect(VideoTransport.seekTarget(from: 3, by: -5, duration: 60) == 0)
        #expect(VideoTransport.seekTarget(from: 58, by: 5, duration: 60) == 60)
        #expect(VideoTransport.seekTarget(from: 10, by: 5, duration: 60) == 15)
    }

    @Test("进度条位置和时间互换")
    func fraction() {
        #expect(VideoTransport.time(atFraction: 0.5, duration: 80) == 40)
        #expect(VideoTransport.time(atFraction: 1.4, duration: 80) == 80)
        #expect(VideoTransport.fraction(of: 20, duration: 80) == 0.25)
        #expect(VideoTransport.fraction(of: 20, duration: 0) == 0)
    }

    @Test("播到结尾和结尾动作")
    func end() {
        #expect(VideoTransport.isAtEnd(59.97, duration: 60))
        #expect(!VideoTransport.isAtEnd(59, duration: 60))
        #expect(VideoTransport.endAction(loop: true) == .restart)
        #expect(VideoTransport.endAction(loop: false) == .stop)
    }

    @Test("时间显示：向下取整")
    func clock() {
        let en = Locale(identifier: "en_US")
        #expect(Formatting.clock(0, locale: en) == "0:00")
        #expect(Formatting.clock(27.9, locale: en) == "0:27")
        #expect(Formatting.clock(68, locale: en) == "1:08")
        #expect(Formatting.clock(3725, locale: en) == "1:02:05")
        #expect(Formatting.clock(.nan, locale: en) == "0:00")
    }
}

@Suite("视频播放器")
@MainActor
struct VideoPlayerControllerTests {
    @Test("准备后读出时长；切走后释放播放项")
    func prepareAndStop() async throws {
        let url = MetaFixtures.sample.appendingPathComponent("trail.mp4")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let item = MediaItem(url: url, format: SupportedFormats.format(forExtension: "mp4")!,
                             fileSize: 1, modificationDate: Date())
        let video = VideoPlayerController(loopAtEnd: { false }, autoplay: { false })
        video.prepare(item)
        #expect(video.isActive)
        #expect(video.player.currentItem != nil)
        for _ in 0..<60 where video.duration <= 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(video.duration > 0)
        #expect(video.isPlaying == false)   // 默认停在第一帧
        video.stop()
        #expect(!video.isActive)
        #expect(video.player.currentItem == nil)
    }
}
