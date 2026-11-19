import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 缩略图磁盘缓存的文件名：由 路径 + 修改时间 + 文件大小 算出，任何一个变了就重新生成
enum ThumbnailCacheKey {
    /// 生成规则的版本号，改动缩略图尺寸或格式时加 1，旧缓存自动失效
    static let version = 2

    static func make(path: String, modificationDate: Date, fileSize: Int64) -> String {
        // 修改时间取到毫秒，避免浮点误差导致同一文件算出不同的键
        let mtime = Int64((modificationDate.timeIntervalSince1970 * 1000).rounded())
        let raw = "v\(version)|\(path)|\(mtime)|\(fileSize)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func make(for item: MediaItem) -> String {
        make(path: item.url.standardizedFileURL.path, modificationDate: item.modificationDate, fileSize: item.fileSize)
    }
}

/// 一张缩略图（不可变）
final class Thumbnail: @unchecked Sendable {
    let image: CGImage?
    /// 视频时长（秒）
    let duration: Double?
    /// 文件无法读取
    var failed: Bool { image == nil }

    init(image: CGImage?, duration: Double?) {
        self.image = image
        self.duration = duration
    }
}

/// 缩略图生成和磁盘缓存。位置：~/Library/Caches/com.yilan.viewer/thumbs
enum ThumbnailGenerator {
    /// 缩略图长边像素：76 × 52 的格子在 2x 屏幕、选中放大 1.12 倍时仍然清晰
    static let maxPixel = 320

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("com.yilan.viewer/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func cacheURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(ThumbnailCacheKey.make(for: item) + ".jpg")
    }

    /// 先读磁盘缓存，没有再生成并写入
    static func thumbnail(for item: MediaItem) async -> Thumbnail {
        let url = cacheURL(for: item)
        if let cached = readCache(url) {
            touch(url)
            return cached
        }
        if Task.isCancelled { return Thumbnail(image: nil, duration: nil) }
        let made = await generate(item)
        if let image = made.image { writeCache(url, image: image, duration: made.duration) }
        return made
    }

    static func generate(_ item: MediaItem) async -> Thumbnail {
        guard item.fileSize > 0 else { return Thumbnail(image: nil, duration: nil) }
        switch item.format {
        case .video:
            return await videoThumbnail(item)
        case .svg:
            let image = try? ImageDecoder.decodeSVG(item, maxPixel: maxPixel).image
            return Thumbnail(image: image, duration: nil)
        case .standard, .raw, .gif:
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else { return Thumbnail(image: nil, duration: nil) }
            // 有内嵌缩略图且足够大就直接用（RAW、相机 JPEG 都有），否则从原图缩小
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            // 内嵌缩略图太小（比如 160 × 120）时，改用完整图缩小，保证清晰
            if let i = image, max(i.width, i.height) < 200, item.format != .raw {
                var always = options
                always[kCGImageSourceCreateThumbnailFromImageAlways] = true
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, always as CFDictionary) ?? i
            }
            return Thumbnail(image: image, duration: nil)
        }
    }

    /// 视频缩略图取哪一秒：时长的 40%，最多 6 秒。第 0 秒常常是黑帧、淡入或还没对好焦的画面
    /// （有的视频开头只有一片几乎没有细节的画面，缩成 76 × 52 就是一块灰），取靠后一点更有代表性
    static func videoFrameTime(duration: Double?) -> CMTime {
        guard let duration, duration.isFinite, duration > 0 else { return .zero }
        return CMTime(seconds: min(duration * 0.4, 6), preferredTimescale: 600)
    }

    static func videoThumbnail(_ item: MediaItem) async -> Thumbnail {
        let asset = AVURLAsset(url: item.url)
        let duration = try? await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let seconds = duration.map(\.seconds).flatMap { $0.isFinite ? $0 : nil }
        // 取帧失败（时间点解码不出来）时退回第 0 秒
        var image = try? await generator.image(at: videoFrameTime(duration: seconds)).image
        if image == nil { image = try? await generator.image(at: .zero).image }
        return Thumbnail(image: image, duration: seconds)
    }

    // MARK: - 磁盘缓存清理

    /// 磁盘缓存的上限：超过后从最久没用的开始删
    static let diskLimit: Int64 = 1024 * 1024 * 1024
    /// 超过这么久没用过的缓存直接删
    static let maxAge: TimeInterval = 90 * 24 * 3600

    /// 用到一个缓存时把它的修改时间更新为现在（一天内只更新一次），清理时按修改时间判断新旧
    static func touch(_ url: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > 24 * 3600 else { return }
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    /// 清理磁盘缓存：先删 maxAge 之前的，剩下的总大小超过 limit 时从最旧的开始删。返回删掉的文件数
    @discardableResult
    static func prune(directory: URL = directory, limit: Int64 = diskLimit, maxAge: TimeInterval = maxAge, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        var entries: [(url: URL, date: Date, size: Int64)] = []
        var removed = 0
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let date = v.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maxAge {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
                continue
            }
            entries.append((url, date, Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return removed }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > limit {
            if (try? fm.removeItem(at: entry.url)) != nil {
                removed += 1
                total -= entry.size
            }
        }
        return removed
    }

    // MARK: - 磁盘缓存（JPEG；视频时长写在 TIFF ImageDescription 里，一个文件搞定）

    private static let durationPrefix = "yilan-duration="

    static func readCache(_ url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var duration: Double?
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            // 写进 JPEG 的 TIFF ImageDescription，ImageIO 读回来时会放在 IPTC 的 Caption/Abstract 里，
            // 两处都要找（只找 TIFF 的话，从磁盘缓存读回的视频缩略图会丢掉时长角标）
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            let desc = (tiff?[kCGImagePropertyTIFFImageDescription] as? String)
                ?? (iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String)
            if let desc, desc.hasPrefix(durationPrefix) {
                duration = Double(desc.dropFirst(durationPrefix.count))
            }
        }
        return Thumbnail(image: image, duration: duration)
    }

    static func writeCache(_ url: URL, image: CGImage, duration: Double?) {
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        if let duration {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: "\(durationPrefix)\(duration)"]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            // 先写临时文件再改名，避免读到写了一半的缓存
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: tmp, to: url) }
        }
        try? FileManager.default.removeItem(at: tmp)
    }
}

/// 限制同时生成的缩略图数量，滚动上千张时不会把 CPU 占满
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

/// 主线程上的缩略图内存缓存，缩略图格子可以同步读取，避免闪一下占位格。
/// 按路径存，同时记下生成时文件的修改时间和大小：文件在原地被改写（保存旋转、替换原图、撤销）后，
/// 旧的缩略图不会再被当成新的用（F2-02）
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// 文件的哪个版本：路径相同、修改时间或大小不同就是另一个版本
    struct Version: Hashable {
        let modificationDate: Date
        let fileSize: Int64
        init(_ item: MediaItem) {
            modificationDate = item.modificationDate
            fileSize = item.fileSize
        }
    }

    private final class Entry {
        let thumb: Thumbnail
        let version: Version
        init(_ thumb: Thumbnail, _ version: Version) {
            self.thumb = thumb
            self.version = version
        }
    }

    private let memory = NSCache<NSURL, Entry>()
    private var inFlight: [URL: (version: Version, task: Task<Thumbnail?, Never>)] = [:]
    private let limiter = AsyncLimiter(limit: max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    init() {
        memory.countLimit = 3000   // 320px 的缩略图约 0.3 MB，3000 张约 1 GB 上限，实际由系统按需回收
        memory.totalCostLimit = 400 * 1024 * 1024
    }

    /// 内存里这个文件、这个版本的缩略图
    func cached(_ item: MediaItem) -> Thumbnail? {
        guard let entry = memory.object(forKey: item.url as NSURL), entry.version == Version(item) else { return nil }
        return entry.thumb
    }

    /// 这些文件变了：内存里的缩略图删掉（磁盘缓存按修改时间、大小区分，变了自然用不上）
    func forget(_ urls: Set<URL>) {
        for url in urls { memory.removeObject(forKey: url as NSURL) }
    }

    /// 内存紧张：清空内存缓存（磁盘缓存还在，需要时很快能读回来）
    func trimMemory() {
        memory.removeAllObjects()
    }

    /// 取缩略图；调用方被取消（格子滚出可见区域）时返回 nil，还没开始的生成也随之取消
    func thumbnail(for item: MediaItem) async -> Thumbnail? {
        if let hit = cached(item) { return hit }
        let version = Version(item)
        let task: Task<Thumbnail?, Never>
        // 正在生成的是同一个版本才合用；文件改过了就重新生成
        if let running = inFlight[item.url], running.version == version {
            task = running.task
        } else {
            let limiter = self.limiter
            task = Task.detached(priority: .utility) {
                await limiter.acquire()
                if Task.isCancelled {
                    await limiter.release()
                    return nil
                }
                let result = await ThumbnailGenerator.thumbnail(for: item)
                await limiter.release()
                return Task.isCancelled && result.failed ? nil : result
            }
            inFlight[item.url] = (version, task)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight[item.url]?.task == task { inFlight[item.url] = nil }
        guard let result else { return nil }
        let cost = result.image.map { $0.bytesPerRow * $0.height } ?? 1
        memory.setObject(Entry(result, version), forKey: item.url as NSURL, cost: cost)
        return result
    }
}
