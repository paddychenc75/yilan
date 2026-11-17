import Foundation

/// 星级保存方式（设置 › 浏览 › 星级保存到哪里）
enum RatingStorageMode: String, CaseIterable, Sendable {
    /// JPEG、PNG、HEIC、TIFF 写进文件内部（默认）；其他类型仍用 .xmp 小文件
    case embedded
    /// 一律使用旁边的 .xmp 小文件，不改动图片本身
    case sidecar
}

/// 一个文件读出来的星级（spec R4）
struct RatingInfo: Sendable, Equatable {
    /// 界面显示的星级：0 = 未评星，1–5
    var value: Int
    /// 文件内部 xmp:Rating 的原始值（没读或没有时为 nil；RAW 有小文件时不读内部）
    var embedded: Int?
    /// 读到星级的 .xmp 小文件（存在时）
    var sidecarURL: URL?
    /// 小文件里 xmp:Rating 的原始值
    var sidecar: Int?

    static let unrated = RatingInfo(value: 0)
}

enum RatingValue {
    /// XMP 里的 Rating 文字 → 整数原始值（包括 0、-1）；小数、乱码返回 nil
    static func parse(_ text: String?) -> Int? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let i = Int(t) { return i }
        // 有的软件写成 "4.0"
        if let d = Double(t), d.rounded() == d, abs(d) < 100 { return Int(d) }
        return nil
    }

    /// 原始值 → 界面星级：1–5 原样，其他（0、-1“排除”、超范围）都是未评星（spec R4-03）
    static func display(_ raw: Int?) -> Int {
        guard let raw, (1...5).contains(raw) else { return 0 }
        return raw
    }
}

/// 写星级出错的原因（界面据此选提示文字，spec S-14、S-15）
enum RatingWriteError: Error, Equatable, Sendable {
    /// 只读磁盘、写保护、没有权限
    case notWritable
    case diskFull
    /// 文件在排队期间被删除、移走或改名
    case vanished
    /// 这个文件不能无损写入内部（自检不合格、XMP 太大等）；调用方改用小文件
    case unsupported(String)
    case other(String)
}
