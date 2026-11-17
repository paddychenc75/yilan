import Foundation

/// 更新说明的取段和简化 Markdown（spec U3-02 ~ U3-04）
enum ReleaseNotes {
    /// 按界面语言取「## 中文」或「## English」段，不要「## 安装 / Install」段。
    /// 三个段落要齐全且顺序是 中文、English、安装（和 scripts/check-release-notes.sh 一致），否则原样返回全文
    static func section(of body: String, language: AppLanguage) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func index(_ heading: String) -> Int? {
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == heading }
        }
        guard let zh = index("## 中文"), let en = index("## English"), let install = index("## 安装 / Install"),
              zh < en, en < install else { return body }
        let range = language == .english ? (en + 1)..<install : (zh + 1)..<en
        return lines[range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一块内容
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(String)
        case ordered(Int, String)
        case paragraph(String)
    }

    /// 按行拆成块：标题、无序 / 有序列表、段落（相邻的普通行合成一段）。其他写法（表格、HTML、图片）当普通文字
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { flush(); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                out.append(.heading(level: m.1.count, text: String(m.2)))
            } else if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flush()
                out.append(.bullet(String(m.1)))
            } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flush()
                out.append(.ordered(Int(m.1) ?? 1, String(m.2)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// 行内格式（粗体、斜体、行内代码、链接）；图片语法不加载，原样当文字
    static func inline(_ text: String) -> AttributedString {
        let escaped = text.replacingOccurrences(of: "![", with: "\\![")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: escaped, options: options)) ?? AttributedString(text)
    }

    /// 只放行 http / https 链接（spec U3-05）
    static func isAllowedLink(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }
}
