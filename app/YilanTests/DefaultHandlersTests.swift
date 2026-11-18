import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Yilan

/// 默认打开方式（spec 19）：全部用假的系统接口，绝不改真实设置
@MainActor
@Suite("默认打开方式")
struct DefaultHandlersTests {
    static let me = AppRef(bundleID: "com.yilan.viewer", path: "/Applications/Yilan.app", name: "Yilan")
    static let meDebug = AppRef(bundleID: "com.yilan.viewer", path: "/tmp/build/Debug/Yilan.app", name: "Yilan")
    static let preview = AppRef(bundleID: "com.apple.Preview", path: "/System/Applications/Preview.app", name: "预览")
    static let quickTime = AppRef(bundleID: "com.apple.QuickTimePlayerX", path: "/System/Applications/QuickTime Player.app", name: "QuickTime Player")
    static let photoshop = AppRef(bundleID: "com.adobe.Photoshop", path: "/Applications/Adobe Photoshop.app", name: "Photoshop")
    static let movist = AppRef(bundleID: "com.movist.mac", path: "/Applications/Movist.app", name: "Movist")

    struct Env {
        let system: FakeHandlerSystem
        let store: UserDefaults
        let model: DefaultHandlers
    }

    /// 默认：图片和 RAW 由预览，视频由 QuickTime；`changes` 覆盖个别格式
    func make(_ changes: [HandlerFormat: AppRef] = [:], installed: [AppRef]? = nil, selfApp: AppRef = me) -> Env {
        var handlers: [String: AppRef] = [:]
        for f in HandlerFormat.allCases {
            handlers[f.typeIdentifier] = changes[f] ?? (f.group == .videos ? Self.quickTime : Self.preview)
        }
        let system = FakeHandlerSystem(handlers: handlers,
                                       installed: installed ?? [Self.me, Self.preview, Self.quickTime, Self.photoshop, Self.movist])
        let name = "yilan-test-handlers-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        let model = DefaultHandlers(system: system, store: store, selfApp: selfApp)
        model.noteSeconds = 0.05
        model.bannerSeconds = 0.05
        return Env(system: system, store: store, model: model)
    }

    @Test("创建和读取只读系统、不改任何设置（DF-10）")
    func noChangeOnCreate() {
        let env = make()
        env.model.refresh()
        #expect(env.system.calls.isEmpty)
        #expect(!env.model.anyOn)
        #expect(env.model.current[.jpeg] == Self.preview)
    }

    @Test("是不是一览只看 bundle id：Debug 版路径不同也算（E-06）")
    func bundleIDComparison() {
        let env = make([.jpeg: Self.me], selfApp: Self.meDebug)
        #expect(env.model.isYilan(.jpeg))
        #expect(!env.model.isYilan(.png))
        #expect(env.model.onCount(.images) == 1)
    }

    @Test("格式表：每行一个系统格式，奥林巴斯用 com.olympus.raw-image，分组 9 / 8 / 3")
    func formatTable() {
        #expect(HandlerFormat.orf.typeIdentifier == "com.olympus.raw-image")
        #expect(HandlerFormat.Group.images.formats.count == 9)
        #expect(HandlerFormat.Group.raw.formats.count == 8)
        #expect(HandlerFormat.Group.videos.formats.count == 3)
        #expect(Set(HandlerFormat.allCases.map(\.typeIdentifier)).count == HandlerFormat.allCases.count)
        // 系统认识的扩展名对得上（E-07）
        for (ext, f) in [("arw", HandlerFormat.arw), ("cr2", .cr2), ("cr3", .cr3), ("nef", .nef), ("raf", .raf),
                         ("rw2", .rw2), ("orf", .orf), ("dng", .dng), ("m4v", .m4v), ("mov", .mov), ("mp4", .mp4)] {
            #expect(UTType(filenameExtension: ext)?.identifier == f.typeIdentifier, "\(ext)")
        }
    }

    @Test("打开：先记下原来的应用，再设成一览；关掉：交给系统默认，记录删掉")
    func onThenRestore() async {
        let env = make([.png: Self.photoshop])
        await env.model.setSwitch(.png, on: true)
        #expect(env.model.isYilan(.png))
        #expect(env.model.previous[HandlerFormat.png.typeIdentifier] == Self.photoshop)
        #expect(env.model.notes[.png] == .justSet)
        #expect(env.system.calls.map(\.bundleID) == ["com.yilan.viewer"])

        // 关掉：一律交给系统默认（预览），不回到之前的 Photoshop
        await env.model.setSwitch(.png, on: false)
        #expect(env.model.current[.png] == Self.preview)
        #expect(env.model.previous[HandlerFormat.png.typeIdentifier] == nil)
        #expect(env.model.notes[.png] == .restored)
    }

    @Test("“预览”打不开 SVG：关掉 SVG 交给 Safari；自带应用都打不开时交给别的能打开的应用")
    func svgGoesToSafari() async {
        let safari = AppRef(bundleID: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
        let env = make([.svg: Self.me], installed: [Self.preview, Self.quickTime, safari, Self.photoshop, Self.me])
        env.system.cannotOpen = ["com.apple.Preview": [HandlerFormat.svg.typeIdentifier],
                                 "com.apple.QuickTimePlayerX": [HandlerFormat.svg.typeIdentifier]]
        await env.model.setSwitch(.svg, on: false)
        #expect(env.model.current[.svg] == safari)

        await env.model.setSwitch(.svg, on: true)
        env.system.cannotOpen["com.apple.Safari"] = [HandlerFormat.svg.typeIdentifier]
        await env.model.setSwitch(.svg, on: false)
        #expect(env.model.current[.svg] == Self.photoshop)
    }

    @Test("已经是一览的格式再打开不调用系统、不记录")
    func alreadyOn() async {
        let env = make([.jpeg: Self.meDebug])
        await env.model.setSwitch(.jpeg, on: true)
        #expect(env.system.calls.isEmpty)
        #expect(env.model.previous.isEmpty)
    }

    @Test("不知道原来是谁 → 图片还原成预览，视频还原成 QuickTime（D4、PD-19）")
    func restoreToSystemDefault() async {
        let env = make([.jpeg: Self.me, .m4v: Self.me])
        await env.model.setSwitch(.jpeg, on: false)
        await env.model.setSwitch(.m4v, on: false)
        #expect(env.model.current[.jpeg] == Self.preview)
        #expect(env.model.current[.m4v] == Self.quickTime)
    }

    @Test("记下的应用已经删掉 → 还原成系统默认")
    func previousAppDeleted() async {
        let env = make([.mp4: Self.movist])
        await env.model.setSwitch(.mp4, on: true)
        env.system.installed["com.movist.mac"] = nil
        await env.model.setSwitch(.mp4, on: false)
        #expect(env.model.current[.mp4] == Self.quickTime)
    }

    @Test("用户在系统确认框里拒绝（-128 包在 256 里）：等于取消，开关不变，不出警告也不出提示条")
    func declined() async {
        let env = make([.png: Self.photoshop])
        env.system.declines = [HandlerFormat.png.typeIdentifier]
        await env.model.setSwitch(.png, on: true)
        #expect(!env.model.isYilan(.png))
        #expect(env.model.notes[.png] == nil)
        #expect(env.model.banner == nil)
        #expect(!env.model.isBusy)
    }

    @Test("拒绝的错误怎么认")
    func declineErrors() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -128)])
        #expect(DefaultHandlers.isDeclined(wrapped))
        #expect(DefaultHandlers.isDeclined(NSError(domain: NSOSStatusErrorDomain, code: -128)))
        #expect(DefaultHandlers.isDeclined(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        #expect(!DefaultHandlers.isDeclined(NSError(domain: NSOSStatusErrorDomain, code: -10814)))
        #expect(!DefaultHandlers.isDeclined(NSError(domain: NSCocoaErrorDomain, code: 256)))
    }

    @Test("系统拒绝（其他错误）：开关不变，说明条")
    func failed() async {
        let env = make()
        env.system.failures = [HandlerFormat.svg.typeIdentifier]
        await env.model.setSwitch(.svg, on: true)
        #expect(!env.model.isYilan(.svg))
        #expect(env.model.notes[.svg] == .unchanged)
        #expect(env.model.banner?.kind == .warn)
    }

    @Test("组头：空或混合 → 全开，先说明次数，同意后才改（PD-17）")
    func groupNeedsConsent() async {
        let env = make([.jpeg: Self.me])
        env.model.requestGroup(.images)
        let plan = env.model.pendingPlan
        #expect(plan?.turnOn == true)
        #expect(plan?.formats.count == 8)            // 已经是一览的 JPEG 不算
        #expect(env.system.calls.isEmpty)            // 说明还没同意，什么都不改

        env.model.cancelPlan()
        #expect(env.model.pendingPlan == nil)
        #expect(env.system.calls.isEmpty)

        env.model.requestGroup(.images)
        await env.model.runPlan()
        #expect(env.model.onCount(.images) == 9)
        #expect(env.model.onCount(.raw) == 0)
        #expect(env.system.calls.count == 8)
        #expect(env.model.banner?.kind == .ok)
    }

    @Test("组头：全开 → 全关；都交给系统默认")
    func groupOff() async {
        let env = make([.mp4: Self.movist])
        env.model.requestGroup(.videos)
        await env.model.runPlan()
        #expect(env.model.onCount(.videos) == 3)
        env.model.requestGroup(.videos)
        #expect(env.model.pendingPlan?.turnOn == false)
        await env.model.runPlan()
        #expect(env.model.current[.mp4] == Self.quickTime)
        #expect(env.model.current[.mov] == Self.quickTime)
    }

    @Test("批量里拒绝一个就停下，剩下的不再弹框，说明改了几个（PD-21）")
    func batchStopsOnDecline() async {
        let env = make()
        env.system.declines = [HandlerFormat.webp.typeIdentifier]   // 图片里第 5 个
        env.model.requestAll(on: true)
        #expect(env.model.pendingPlan?.formats.count == 20)
        await env.model.runPlan()
        #expect(env.system.calls.count == 5)                          // 第 6 个起没有调用
        #expect(env.model.onCount(.images) == 4)
        #expect(env.model.notes[.webp] == .unchanged)
        #expect(env.model.notes[.gif] == nil)                          // 没轮到的不留「等待中」
        #expect(env.model.banner?.kind == .warn)
        #expect(env.model.banner?.text.contains("4") == true)
        #expect(env.model.banner?.text.contains("16") == true)
        #expect(!env.model.isBusy)
    }

    @Test("批量里系统拒绝的跳过，继续下一个")
    func batchContinuesOnFailure() async {
        let env = make()
        env.system.failures = [HandlerFormat.svg.typeIdentifier]
        env.model.requestGroup(.images)
        await env.model.runPlan()
        #expect(env.model.onCount(.images) == 8)
        #expect(env.model.banner?.kind == .warn)
    }

    @Test("全部关闭：都交给系统默认，记录清空")
    func restoreAll() async {
        let env = make([.png: Self.photoshop])
        env.model.requestAll(on: true)
        await env.model.runPlan()
        #expect(env.model.allOn)
        env.model.requestAll(on: false)
        await env.model.runPlan()
        #expect(!env.model.anyOn)
        #expect(env.model.current[.png] == Self.preview)
        #expect(env.model.banner?.text.contains("系统默认") == true)
        #expect(env.model.previous.isEmpty)
    }

    @Test("只差一个时组头不弹说明，直接改")
    func singleItemGroup() async {
        let env = make([.mp4: Self.me, .m4v: Self.me])
        env.model.requestGroup(.videos)
        #expect(env.model.pendingPlan == nil)
        for _ in 0..<50 where env.system.calls.isEmpty { await Task.yield() }
        #expect(env.system.calls.map(\.type) == [HandlerFormat.mov.typeIdentifier])
    }

    @Test("「停止」：当前这个处理完就停")
    func stopBatch() async {
        let env = make()
        env.model.requestGroup(.raw)
        env.model.stop()                 // 开始前按的停止不算（runPlan 会清掉）
        await env.model.runPlan()
        #expect(env.model.onCount(.raw) == 8)
    }

    @Test("记录存在设置里，换个实例还在")
    func previousPersists() async {
        let env = make([.png: Self.photoshop])
        await env.model.setSwitch(.png, on: true)
        let again = DefaultHandlers(system: env.system, store: env.store, selfApp: Self.me)
        #expect(again.previous[HandlerFormat.png.typeIdentifier] == Self.photoshop)
        // 记录只留作参考；关掉时一律交给系统默认
        #expect(again.restoreTarget(.png)?.app == Self.preview)
    }
}
