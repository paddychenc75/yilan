import CoreGraphics
import Foundation

/// 解码后的大图（不可变，可以跨线程传递）
final class DecodedImage: @unchecked Sendable {
    /// 静态图，或者动图的第一帧，或者视频的第一帧
    let image: CGImage
    /// 文件的原始像素尺寸（已按 EXIF 方向转正）
    let pixelSize: CGSize
    /// GIF 的全部帧和每帧时长（秒）；静态图为空
    let frames: [CGImage]
    let frameDurations: [Double]
    /// RAW 内嵌预览图（还没换成完整解码的版本）
    let isPreview: Bool
    /// 解码尺寸小于原图（为了适配屏幕做了缩小）
    let isDownsampled: Bool
    /// 视频时长（秒）
    let duration: Double?
    /// 状态行里格式后面的补充，例如 “36 帧”、“HEVC”
    let formatDetail: String?
    /// 相机预览图：系统解不了这张 RAW，显示的是相机存在文件里的 JPEG（spec C1-02）。这时 pixelSize 是预览图自己的尺寸
    let isCameraPreview: Bool
    /// 相机预览图状态下，系统读到的原片像素尺寸（读不到时 nil，spec C1-11）
    let originalPixelSize: CGSize?

    init(image: CGImage, pixelSize: CGSize, frames: [CGImage] = [], frameDurations: [Double] = [],
         isPreview: Bool = false, isDownsampled: Bool = false, duration: Double? = nil, formatDetail: String? = nil,
         isCameraPreview: Bool = false, originalPixelSize: CGSize? = nil) {
        self.image = image
        self.pixelSize = pixelSize
        self.frames = frames
        self.frameDurations = frameDurations
        self.isPreview = isPreview
        self.isDownsampled = isDownsampled
        self.duration = duration
        self.formatDetail = formatDetail
        self.isCameraPreview = isCameraPreview
        self.originalPixelSize = originalPixelSize
    }

    var isAnimated: Bool { frames.count > 1 }

    /// 占用内存估算（字节），用于 NSCache 的成本
    var memoryCost: Int {
        let one = image.bytesPerRow * image.height
        guard isAnimated else { return one }
        return frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }
}

/// 无法打开时给用户看的原因
struct DecodeFailure: Error, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// 文件本身坏了或格式不支持：换个时间再试也一样
        case corrupt
        /// 文件已被移走或删除
        case missing
        /// 读不了（没有权限、磁盘断开等），之后可能恢复
        case unreadable
        /// 视频能读到但播放器放不了
        case unplayable

        /// 要不要记在缓存里、不再重试
        var isRemembered: Bool { self == .corrupt }
    }

    /// 第一行说明，例如“文件已损坏，或者不是有效的 TIFF 图片。”
    let reason: String
    /// 等宽小字，例如“文件头无法识别 · 0 字节”
    let detail: String
    var kind: Kind = .corrupt
}
