import AppKit
import OSLog
import QuartzCore

/// 性能测量：冷启动到第一张大图、切换延迟。
/// 始终打 os_signpost（Instruments 里看 “com.yilan.viewer / perf”）；
/// 启动参数带 `--perf` 时在标准输出打印数字，带 `--perf-switches=N` 时自动连续切换 N 次后打印统计并退出。
/// 自动切换的其他参数：`--perf-interval=毫秒`（两次切换的间隔，默认 250）、
/// `--perf-step=K`（每次往后跳 K 张，默认 1；跳过预加载范围可以量“没预加载到”的切换）。
/// `--perf-decode-size=像素`：固定大图解码尺寸（不随窗口所在的屏幕变化，前后对比时用同一个尺寸）。
/// 结束时按扩展名分组打印中位数和最差值，并打印“第一次切换 → 最后一张上屏”的总耗时。
/// 可重复运行的脚本见 scripts/perf-switch.sh
@MainActor
enum Perf {
    private static let signposter = OSSignposter(subsystem: "com.yilan.viewer", category: "perf")
    static let enabled = CommandLine.arguments.contains { $0 == "--perf" || $0.hasPrefix("--perf-switches=") }
    static let autoSwitches: Int = CommandLine.arguments
        .first { $0.hasPrefix("--perf-switches=") }
        .flatMap { Int($0.split(separator: "=").last ?? "") } ?? 0
    /// 自动切换的间隔（毫秒），默认 250
    static let switchIntervalMs: Int = CommandLine.arguments
        .first { $0.hasPrefix("--perf-interval=") }
        .flatMap { Int($0.split(separator: "=").last ?? "") } ?? 250
    /// 固定的大图解码尺寸（长边像素）；nil 表示按屏幕
    static let forcedDecodeSize: Int? = CommandLine.arguments
        .first { $0.hasPrefix("--perf-decode-size=") }
        .flatMap { Int($0.split(separator: "=").last ?? "") }
    /// 每次自动切换往后跳几张，默认 1（相当于按一次 →）
    static let switchStep: Int = CommandLine.arguments
        .first { $0.hasPrefix("--perf-step=") }
        .flatMap { Int($0.split(separator: "=").last ?? "") } ?? 1

    private static var pending: (url: URL, start: CFTimeInterval, state: OSSignpostIntervalState)?
    /// 数据已经解码好、等待贴到画面上的文件
    private static var readyURL: URL?
    private static var firstImageLogged = false
    private static var latencies: [Double] = []
    /// 每次切换的 (扩展名, 毫秒)，结束时分组统计
    private static var samples: [(ext: String, ms: Double)] = []
    /// 自动切换：第一次切换的时间、最后一次切换的目标、它上屏的时间
    private static var burstStart: CFTimeInterval?
    private static var lastTarget: URL?
    private static var lastShownAt: CFTimeInterval?
    /// 最近一次选中的文件和时间（RAW 预览 / 完整解码各自计时用）
    private static var selected: (url: URL, start: CFTimeInterval)?

    /// 进程启动到现在的毫秒数（用内核记录的进程启动时间）
    static func msSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
    }

    /// 输出到标准输出并立即刷新（重定向到文件时 print 会被缓冲）
    static func out(_ line: String) {
        print(line)
        fflush(stdout)
    }

    static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        if enabled { out(String(format: "[perf] %@ at %.0f ms since launch", "\(name)", msSinceProcessStart())) }
    }

    /// 开始切换到某个文件
    static func beginSwitch(to url: URL) {
        if let p = pending { signposter.endInterval("switch", p.state, "abandoned") }
        pending = (url, CACurrentMediaTime(), signposter.beginInterval("switch", id: signposter.makeSignpostID()))
        readyURL = nil
        selected = (url, CACurrentMediaTime())
    }

    /// 大图数据准备好（缓存命中或解码完成）
    static func shown(_ url: URL, isPreview: Bool) {
        readyURL = url
        if enabled, let sel = selected, sel.url == url {
            out(String(format: "[perf] %@ %@ ready: %.0f ms after select", url.lastPathComponent,
                       isPreview ? "preview" : "full", (CACurrentMediaTime() - sel.start) * 1000))
        }
    }

    /// 大图区真正换上了这张图（图层内容已设置，下一帧上屏）
    static func displayed(_ url: URL) {
        guard url == readyURL else { return }   // 缩略图占位不算
        readyURL = nil
        if !firstImageLogged {
            firstImageLogged = true
            let ms = msSinceProcessStart()
            signposter.emitEvent("first image")
            if enabled { out(String(format: "[perf] first image on stage: %.0f ms since process start", ms)) }
            pending = nil
            if autoSwitches > 0 { runAutoSwitches() }
            return
        }
        guard let p = pending, p.url == url else { return }
        let ms = (CACurrentMediaTime() - p.start) * 1000
        signposter.endInterval("switch", p.state)
        pending = nil
        latencies.append(ms)
        samples.append((url.pathExtension.lowercased(), ms))
        if url == lastTarget { lastShownAt = CACurrentMediaTime() }
        if enabled { out(String(format: "[perf] switch → %@: %.1f ms", url.lastPathComponent, ms)) }
    }

    /// 自动连续切换（按 → 的效果），结束后打印统计并退出
    private static func runAutoSwitches() {
        Task { @MainActor in
            let model = BrowserModel.shared
            try? await Task.sleep(for: .milliseconds(800))   // 先让前后预加载跑起来
            out("[perf] decode size: \(forcedDecodeSize ?? model.screenMaxPixel ?? 0) px")
            burstStart = CACurrentMediaTime()
            for n in 0..<autoSwitches {
                if switchStep == 1 {
                    model.next()
                } else if let i = model.currentIndex, !model.items.isEmpty {
                    model.select((i + switchStep) % model.items.count)
                }
                if n == autoSwitches - 1 { lastTarget = model.current?.url }
                try? await Task.sleep(for: .milliseconds(switchIntervalMs))
            }
            // 等最后一张上屏（最多 10 秒）
            for _ in 0..<200 where lastShownAt == nil { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(300))
            report("all", latencies)
            for ext in Set(samples.map(\.ext)).sorted() {
                report(ext, samples.filter { $0.ext == ext }.map(\.ms))
            }
            if let start = burstStart, let end = lastShownAt {
                out(String(format: "[perf] burst: %d switches, first switch → last image on stage: %.0f ms",
                           autoSwitches, (end - start) * 1000))
            }
            NSApp.terminate(nil)
        }
    }

    private static func report(_ label: String, _ values: [Double]) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { out("[perf] \(label): no switch measured"); return }
        let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        let line = label == "all" ? "switches" : "  \(label)"
        out(String(format: "[perf] %@=%d  median=%.1f ms  p95=%.1f ms  max=%.1f ms  over100ms=%d",
                   line, sorted.count, p(0.5), p(0.95), sorted.last!, sorted.filter { $0 > 100 }.count))
    }
}
