import CoreGraphics
import Foundation

/// 编辑模式的几何计算（技术方案 13.2）。全部是纯函数，单元测试直接调用

/// 整数像素尺寸
struct PixelSize: Equatable, Hashable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        width = max(1, Int(size.width.rounded()))
        height = max(1, Int(size.height.rounded()))
    }

    var swapped: PixelSize { PixelSize(width: height, height: width) }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// 整数像素矩形（左上原点，y 向下）
struct PixelRect: Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(size: PixelSize) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    var size: PixelSize { PixelSize(width: width, height: height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func covers(_ size: PixelSize) -> Bool { x == 0 && y == 0 && width == size.width && height == size.height }
}

// MARK: - EXIF 方向

/// EXIF 方向（1–8）。用作用在“以图片中心为原点、y 向下”的坐标上的 2×2 整数矩阵表示：
/// 存储的像素经过这个矩阵变换后就是应该显示的样子
struct ExifOrientation: Equatable, Sendable {
    let a: Int, b: Int, c: Int, d: Int   // (x, y) → (a·x + b·y, c·x + d·y)

    private static let table: [Int: ExifOrientation] = [
        1: .init(a: 1, b: 0, c: 0, d: 1),     // 正常
        2: .init(a: -1, b: 0, c: 0, d: 1),    // 水平翻转
        3: .init(a: -1, b: 0, c: 0, d: -1),   // 转 180°
        4: .init(a: 1, b: 0, c: 0, d: -1),    // 垂直翻转
        5: .init(a: 0, b: 1, c: 1, d: 0),     // 水平翻转后顺时针转 270°
        6: .init(a: 0, b: -1, c: 1, d: 0),    // 顺时针转 90°
        7: .init(a: 0, b: -1, c: -1, d: 0),   // 水平翻转后顺时针转 90°
        8: .init(a: 0, b: 1, c: -1, d: 0),    // 顺时针转 270°
    ]

    /// 方向值（1–8）
    var value: Int { Self.table.first { $0.value == self }?.key ?? 1 }

    static func from(_ value: Int) -> ExifOrientation { table[value] ?? table[1]! }

    /// 先做 other，再做 self
    func after(_ other: ExifOrientation) -> ExifOrientation {
        ExifOrientation(a: a * other.a + b * other.c, b: a * other.b + b * other.d,
                        c: c * other.a + d * other.c, d: c * other.b + d * other.d)
    }

    /// 原方向 value 的图片再顺时针转 quarterTurns 个 90° 之后的方向值
    static func rotating(_ value: Int, quarterTurns: Int) -> Int {
        var result = from(value)
        let turns = ((quarterTurns % 4) + 4) % 4
        for _ in 0..<turns { result = from(6).after(result) }
        return result.value
    }
}

// MARK: - 比例

/// 裁切比例（spec ED-13）
enum CropRatio: String, CaseIterable, Sendable {
    case free, original, square, r4x3, r3x2, r16x9

    /// 长边 / 短边；自由时 nil。original 需要图片尺寸
    func longOverShort(image: PixelSize) -> Double? {
        switch self {
        case .free: nil
        case .original: Double(max(image.width, image.height)) / Double(max(1, min(image.width, image.height)))
        case .square: 1
        case .r4x3: 4.0 / 3.0
        case .r3x2: 3.0 / 2.0
        case .r16x9: 16.0 / 9.0
        }
    }

    /// 能不能横竖互换（spec ED-16）：自由、1:1、正方形原图不能
    func canSwap(image: PixelSize) -> Bool {
        guard let r = longOverShort(image: image) else { return false }
        return abs(r - 1) > 0.0001
    }

    /// 宽 / 高；portrait 表示竖着用
    func widthOverHeight(image: PixelSize, portrait: Bool) -> Double? {
        guard let r = longOverShort(image: image) else { return nil }
        return portrait ? 1 / r : r
    }

    /// 菜单右侧和按钮上写的比例文字，例如 4:3；原始比例按图片尺寸约分，约不干净时写 1.64:1
    static func label(for size: PixelSize) -> String {
        let g = gcd(size.width, size.height)
        let w = size.width / max(g, 1), h = size.height / max(g, 1)
        if w <= 50 && h <= 50 { return "\(w):\(h)" }
        let r = Double(size.width) / Double(max(1, size.height))
        return r >= 1 ? String(format: "%.2f:1", r) : String(format: "1:%.2f", 1 / r)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

// MARK: - 裁切框

/// 裁切框的把手
enum CropHandle: Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

enum CropMath {
    /// 拖动把手：start 是开始拖动时的框，(dx, dy) 是从开始到现在移动的像素数。
    /// ratio：要保持的宽 / 高（自由时 nil）；minSide：框的最小边长（像素）
    static func drag(_ handle: CropHandle, start: PixelRect, dx: Double, dy: Double,
                     bounds: PixelSize, ratio: Double?, minSide: Int) -> PixelRect {
        let W = Double(bounds.width), H = Double(bounds.height)
        let minS = Double(max(1, min(minSide, bounds.width, bounds.height)))
        var l = Double(start.x), t = Double(start.y)
        var r = l + Double(start.width), b = t + Double(start.height)

        if handle == .move {
            let x = min(max(l + dx, 0), W - Double(start.width))
            let y = min(max(t + dy, 0), H - Double(start.height))
            return PixelRect(x: Int(x.rounded()), y: Int(y.rounded()), width: start.width, height: start.height)
        }

        guard let ratio, ratio > 0 else {
            // 自由比例：各边独立移动
            if handle.movesLeft { l = min(max(l + dx, 0), r - minS) }
            if handle.movesRight { r = max(min(r + dx, W), l + minS) }
            if handle.movesTop { t = min(max(t + dy, 0), b - minS) }
            if handle.movesBottom { b = max(min(b + dy, H), t + minS) }
            return clamp(round(l: l, t: t, w: r - l, h: b - t, ratio: nil), bounds: bounds)
        }

        // 最小框：短边不小于 minS
        let minW = ratio >= 1 ? minS * ratio : minS
        if handle.isCorner {
            // 锚点是对角
            let ax = handle.movesLeft ? r : l
            let ay = handle.movesTop ? b : t
            let w = handle.movesLeft ? r - (l + dx) : (r + dx) - l
            let h = handle.movesTop ? b - (t + dy) : (b + dy) - t
            // 哪个方向变得多就听哪个
            let dw = abs(w - Double(start.width)), dh = abs(h - Double(start.height)) * ratio
            var newW = dw >= dh ? w : h * ratio
            let maxW = handle.movesLeft ? ax : W - ax
            let maxH = handle.movesTop ? ay : H - ay
            newW = min(newW, maxW, maxH * ratio)
            newW = max(newW, min(minW, maxW, maxH * ratio))
            let newH = newW / ratio
            let x = handle.movesLeft ? ax - newW : ax
            let y = handle.movesTop ? ay - newH : ay
            return clamp(round(l: x, t: y, w: newW, h: newH, ratio: ratio), bounds: bounds)
        }
        if handle == .left || handle == .right {
            let ax = handle == .left ? r : l
            var newW = handle == .left ? r - (l + dx) : (r + dx) - l
            let cy = (t + b) / 2
            let maxW = handle == .left ? ax : W - ax
            let maxH = 2 * min(cy, H - cy)
            newW = min(newW, maxW, maxH * ratio)
            newW = max(newW, min(minW, maxW, maxH * ratio))
            let newH = newW / ratio
            return clamp(round(l: handle == .left ? ax - newW : ax, t: cy - newH / 2, w: newW, h: newH, ratio: ratio), bounds: bounds)
        }
        // 上下边：宽跟着按比例变，以竖直中线为轴
        let ay = handle == .top ? b : t
        var newH = handle == .top ? b - (t + dy) : (b + dy) - t
        let cx = (l + r) / 2
        let maxH = handle == .top ? ay : H - ay
        let maxW = 2 * min(cx, W - cx)
        newH = min(newH, maxH, maxW / ratio)
        newH = max(newH, min(minW / ratio, maxH, maxW / ratio))
        let newW = newH * ratio
        return clamp(round(l: cx - newW / 2, t: handle == .top ? ay - newH : ay, w: newW, h: newH, ratio: ratio), bounds: bounds)
    }

    /// 选定比例：当前框里能放下的最大该比例框，中心不变（spec ED-14）
    static func fit(_ rect: PixelRect, ratio: Double, bounds: PixelSize) -> PixelRect {
        let w = Double(rect.width), h = Double(rect.height)
        let cx = Double(rect.x) + w / 2, cy = Double(rect.y) + h / 2
        let (nw, nh) = w / h > ratio ? (h * ratio, h) : (w, w / ratio)
        return clamp(round(l: cx - nw / 2, t: cy - nh / 2, w: nw, h: nh, ratio: ratio), bounds: bounds)
    }

    /// 横竖互换（spec ED-16）：以中心为准宽高对调，放不下时等比缩小到图内。ratio 是互换后的宽 / 高
    static func swap(_ rect: PixelRect, ratio: Double, bounds: PixelSize) -> PixelRect {
        var w = Double(rect.height), h = w / ratio
        let k = min(1, Double(bounds.width) / w, Double(bounds.height) / h)
        w *= k
        h = w / ratio
        let cx = Double(rect.x) + Double(rect.width) / 2, cy = Double(rect.y) + Double(rect.height) / 2
        return clamp(round(l: cx - w / 2, t: cy - h / 2, w: w, h: h, ratio: ratio), bounds: bounds)
    }

    /// 图片顺时针（clockwise）或逆时针转 90° 后，框跟着转。size 是转之前的图片尺寸
    static func rotate(_ rect: PixelRect, clockwise: Bool, in size: PixelSize) -> PixelRect {
        clockwise
            ? PixelRect(x: size.height - rect.y - rect.height, y: rect.x, width: rect.height, height: rect.width)
            : PixelRect(x: rect.y, y: size.width - rect.x - rect.width, width: rect.height, height: rect.width)
    }

    /// 取整：有比例时高按宽算，保证误差不超过 1 像素
    private static func round(l: Double, t: Double, w: Double, h: Double, ratio: Double?) -> PixelRect {
        let iw = max(1, Int(w.rounded()))
        let ih = max(1, ratio.map { Int((Double(iw) / $0).rounded()) } ?? Int(h.rounded()))
        return PixelRect(x: Int(l.rounded()), y: Int(t.rounded()), width: iw, height: ih)
    }

    /// 放回图内（取整可能多出 1 像素）
    static func clamp(_ rect: PixelRect, bounds: PixelSize) -> PixelRect {
        var r = rect
        r.width = min(max(1, r.width), bounds.width)
        r.height = min(max(1, r.height), bounds.height)
        r.x = min(max(0, r.x), bounds.width - r.width)
        r.y = min(max(0, r.y), bounds.height - r.height)
        return r
    }
}

// MARK: - 调整尺寸

/// 调整尺寸（spec ED-20 ~ ED-25）：scale ∈ (0, 1]，以裁切后的尺寸为基准
enum ResizeMath {
    /// 输出尺寸：每边至少 1 像素
    static func output(crop: PixelSize, scale: Double) -> PixelSize {
        let s = min(max(scale, 0), 1)
        return PixelSize(width: max(1, Int((Double(crop.width) * s).rounded())),
                         height: max(1, Int((Double(crop.height) * s).rounded())))
    }

    /// 缩放按钮上的百分比（四舍五入，至少 1）
    static func percent(_ scale: Double) -> Int { max(1, min(100, Int((scale * 100).rounded()))) }

    /// 输入宽（或高）像素 → 缩放比例；超过裁切尺寸或不是正数时 nil（不接受）
    static func scale(forWidth value: Int, crop: PixelSize) -> Double? {
        guard value >= 1, value <= crop.width else { return nil }
        return value == crop.width ? 1 : Double(value) / Double(crop.width)
    }

    static func scale(forHeight value: Int, crop: PixelSize) -> Double? {
        guard value >= 1, value <= crop.height else { return nil }
        return value == crop.height ? 1 : Double(value) / Double(crop.height)
    }

    /// 输入百分比 → 缩放比例；1–100 之外 nil
    static func scale(forPercent value: Int) -> Double? {
        guard (1...100).contains(value) else { return nil }
        return Double(value) / 100
    }

    /// 只保留数字（非数字字符不接受，spec ED-23）
    static func digits(_ text: String) -> String { String(text.filter(\.isASCIIDigit).prefix(6)) }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
