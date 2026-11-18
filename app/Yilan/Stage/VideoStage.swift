import AVFoundation
import Observation
import SwiftUI

/// 视频播放的接入点：切到视频时 prepare，切走时 stop（停止加载）
@MainActor
protocol VideoStageController: AnyObject {
    /// 切到这个视频：准备播放器；默认停在第一帧，设置里打开“自动播放”时直接播放
    func prepare(_ item: MediaItem)
    func play()
    func pause()
    /// 切走：暂停并停止加载（释放 AVPlayerItem）
    func stop()
    var isPlaying: Bool { get }
}

/// 播放控制里的纯计算，方便单独测试
enum VideoTransport {
    /// 快退 / 快进的步长（J / L）
    static let skipSeconds: Double = 5

    /// 跳转目标：限制在 0 到时长之间
    static func seekTarget(from current: Double, by delta: Double, duration: Double) -> Double {
        let target = current + delta
        guard duration.isFinite, duration > 0 else { return max(0, target) }
        return min(max(0, target), duration)
    }

    /// 进度条上某个位置（0…1）对应的时间
    static func time(atFraction fraction: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, fraction), 1) * duration
    }

    static func fraction(of time: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(0, time / duration), 1)
    }

    /// 已经播到结尾：再按播放时从头开始
    static func isAtEnd(_ time: Double, duration: Double) -> Bool {
        duration > 0 && time >= duration - 0.05
    }

    enum EndAction: Equatable { case restart, stop }

    /// 播到结尾后：设置里打开了“循环播放”就从头再播，否则停在最后一帧
    static func endAction(loop: Bool) -> EndAction { loop ? .restart : .stop }
}

/// 基于 AVPlayer 的播放器。整个窗口共用一个播放器和一个画面层，切换视频时只换 AVPlayerItem
@MainActor
@Observable
final class VideoPlayerController: VideoStageController {
    private(set) var item: MediaItem?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// 已缓冲到的位置（进度条上浅色的一段）
    private(set) var bufferedTime: Double = 0
    private(set) var isMuted = false
    var volume: Float = 1 {
        didSet {
            player.volume = volume
            if volume > 0, isMuted { setMuted(false) }
        }
    }
    /// 正在拖动进度条：这期间不让播放进度覆盖拖动位置
    private(set) var isScrubbing = false

    /// 画面层：由大图区挂在图片的位置上，跟着缩放、旋转一起变
    @ObservationIgnored let layer: AVPlayerLayer
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// 播放器打不开当前视频（格式不支持、文件损坏等）时通知外面显示出错卡片；第二个参数是系统给的错误说明
    @ObservationIgnored var onPlaybackFailed: (@MainActor (MediaItem, String?) -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var wasPlayingBeforeScrub = false
    @ObservationIgnored private let loopAtEnd: @MainActor () -> Bool
    @ObservationIgnored private let autoplay: @MainActor () -> Bool

    init(loopAtEnd: @escaping @MainActor () -> Bool, autoplay: @escaping @MainActor () -> Bool) {
        self.loopAtEnd = loopAtEnd
        self.autoplay = autoplay
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        // 视频不预加载整段：只有切到它时才开始加载，而且不在后台提前缓冲太多
        player.automaticallyWaitsToMinimizeStalling = true
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = nil
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var isActive: Bool { item != nil }

    // MARK: - VideoStageController

    func prepare(_ item: MediaItem) {
        guard item != self.item else { return }
        stop()
        self.item = item
        let playerItem = AVPlayerItem(url: item.url)
        // 只缓冲前面几秒，不把整段读进来
        playerItem.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: playerItem)
        player.isMuted = isMuted
        player.volume = volume
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
        // 播放中途出错
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated { self?.playbackFailed(item, message: message) }
        }
        // 打开时就失败：status 变成 .failed（KVO 回调可能在任意线程，回到主线程再处理）
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription
            Task { @MainActor in self?.playbackFailed(item, message: message) }
        }
        loadTask = Task { [weak self] in
            let seconds = try? await playerItem.asset.load(.duration).seconds
            guard let self, !Task.isCancelled, self.item == item else { return }
            if let seconds, seconds.isFinite { self.duration = seconds }
        }
        if autoplay() { play() }
    }

    func play() {
        guard item != nil else { return }
        if VideoTransport.isAtEnd(currentTime, duration: duration) {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        // 释放 AVPlayerItem：停止网络/磁盘读取和解码
        player.replaceCurrentItem(with: nil)
        item = nil
        isPlaying = false
        isScrubbing = false
        currentTime = 0
        duration = 0
        bufferedTime = 0
    }

    // MARK: - 控制

    func skip(by seconds: Double) {
        guard item != nil else { return }
        seek(to: VideoTransport.seekTarget(from: currentTime, by: seconds, duration: duration), precise: true)
    }

    func seek(to seconds: Double, precise: Bool) {
        currentTime = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    /// 拖动进度条开始：暂停，松手后恢复
    func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        player.pause()
    }

    func scrub(toFraction fraction: Double) {
        seek(to: VideoTransport.time(atFraction: fraction, duration: duration), precise: false)
    }

    func endScrub(atFraction fraction: Double) {
        seek(to: VideoTransport.time(atFraction: fraction, duration: duration), precise: true)
        isScrubbing = false
        if wasPlayingBeforeScrub { play() }
    }

    // MARK: - 播放进度

    private func tick() {
        guard let playerItem = player.currentItem else { return }
        if !isScrubbing {
            let t = player.currentTime().seconds
            if t.isFinite { currentTime = t }
        }
        if duration == 0, playerItem.duration.seconds.isFinite { duration = playerItem.duration.seconds }
        if let range = playerItem.loadedTimeRanges.last?.timeRangeValue {
            let end = range.end.seconds
            if end.isFinite { bufferedTime = end }
        }
        // 外部原因（例如耳机拔出）暂停时同步状态
        if !isScrubbing, player.timeControlStatus == .paused, isPlaying, player.rate == 0 { isPlaying = false }
    }

    private func playbackFailed(_ failed: MediaItem, message: String?) {
        // 已经切到别的视频：旧的错误不管
        guard failed == item else { return }
        stop()
        onPlaybackFailed?(failed, message)
    }

    private func didReachEnd() {
        switch VideoTransport.endAction(loop: loopAtEnd()) {
        case .restart:
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
            player.play()
            isPlaying = true
        case .stop:
            isPlaying = false
            currentTime = duration
        }
    }
}

/// 视频静帧上的大播放按钮（设计稿 .bigplay：78pt 圆形玻璃）
struct VideoPosterOverlay: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white)
                .offset(x: 3)
                .frame(width: 78, height: 78)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .systemGlass(Circle(), interactive: true)
        .help("播放（空格）")
        .accessibilityLabel("播放")
    }
}
