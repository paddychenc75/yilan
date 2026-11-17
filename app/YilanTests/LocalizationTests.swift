import Foundation
import Testing
@testable import Yilan

/// 字符串目录的源文件（和测试同一个仓库）
private func catalog(_ name: String) throws -> [String: Any] {
    // scripts/run-tests.sh 把字符串目录也镜像到 /tmp（避开读桌面时等系统授权）
    let dir = ProcessInfo.processInfo.environment["YILAN_RESOURCES_DIR"].map(URL.init(fileURLWithPath:))
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Yilan/Resources")
    let url = dir.appendingPathComponent("\(name).xcstrings")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return try #require(json)
}

/// 一条翻译里所有要显示的文字（普通、单复数、多个数量的替换）
private func values(_ localization: [String: Any]) -> [String] {
    var result: [String] = []
    if let unit = localization["stringUnit"] as? [String: Any] { result.append(unit["value"] as? String ?? "") }
    if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] {
        result += plural.values.compactMap { $0 as? [String: Any] }.flatMap(values)
    }
    if let substitutions = localization["substitutions"] as? [String: Any] {
        result += substitutions.values.compactMap { $0 as? [String: Any] }.flatMap(values)
    }
    return result
}

/// 格式占位符（%@、%lld、%1$lld 等），按种类数个数，用来对比中英文的参数是否一致
private func placeholders(_ text: String) -> [String] {
    let pattern = /%(?:\d+\$)?(lld|ld|d|@|lf|f)/
    return text.matches(of: pattern).map { String($0.output.1) }.sorted()
}

@Suite("界面文字")
struct LocalizationTests {
    @Test("字符串目录里每一条都有英文翻译", arguments: ["Localizable", "InfoPlist"])
    func everyKeyHasEnglish(_ name: String) throws {
        let root = try catalog(name)
        #expect(root["sourceLanguage"] as? String == "zh-Hans")
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            if entry["shouldTranslate"] as? Bool == false { continue }   // 语言名称等不翻译的
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let texts = en.map(values) ?? []
            #expect(!texts.isEmpty, "缺少英文：\(key)")
            #expect(!texts.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "英文是空的：\(key)")
            // 没有单复数变化的条目：参数个数和种类要和中文一致
            if let unit = en?["stringUnit"] as? [String: Any], en?["substitutions"] == nil, let value = unit["value"] as? String {
                #expect(unit["state"] as? String == "translated", "英文还没确认：\(key)")
                #expect(placeholders(value) == placeholders(key), "参数和中文不一致：\(key)")
            }
        }
    }

    @Test("程序里带了简体中文和英文")
    func bundleLocalizations() throws {
        #expect(Bundle.main.developmentLocalization == "zh-Hans")
        #expect(Set(Bundle.main.localizations).isSuperset(of: ["zh-Hans", "en"]))
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let en = try #require(Bundle(path: path))
        #expect(en.localizedString(forKey: "通用", value: nil, table: nil) == "General")
        #expect(en.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist") == "Yilan")
    }

    @Test("英文的单复数和数字格式")
    func englishPlurals() {
        let en = Locale(identifier: "en_US")
        #expect(DropSummary.countText(images: 1, videos: 0, locale: en) == "1 file: 1 photo")
        #expect(DropSummary.countText(images: 1, videos: 1, locale: en) == "2 files: 1 photo, 1 video")
        #expect(DropSummary.countText(images: 0, videos: 3, locale: en) == "3 files: 3 videos")
        #expect(DropSummary.countText(images: 1000, videos: 0, locale: en) == "1,000 files: 1,000 photos")
        #expect(DropSummary.countText(images: 2, videos: 1, inParentFolder: true, locale: en) == "3 files in its folder: 2 photos, 1 video")
        #expect(DropSummary.countText(images: 0, videos: 0, locale: en) == "No photos or videos in this folder")
    }

    @Test("中文的数量也按地区格式化")
    func chineseNumbers() {
        #expect(DropSummary.countText(images: 1000, videos: 0, locale: Locale(identifier: "zh-Hans")) == "共 1,000 个文件：1,000 张图片")
    }

    @Test("大小、时长、数量跟着地区格式化")
    func formatting() {
        let en = Locale(identifier: "en_US")
        #expect(Formatting.fileSize(3_900_000, locale: en) == "3.9 MB")
        #expect(Formatting.fileSize(0, locale: en) == "0 bytes")
        #expect(Formatting.duration(42.4, locale: en) == "0:42")
        #expect(Formatting.duration(4083, locale: en) == "1:08:03")
        #expect(Formatting.count(1000, locale: en) == "1,000")
        #expect(Formatting.count(1000, locale: Locale(identifier: "de_DE")) == "1.000")
    }
}

/// 每个测试用一份独立的 UserDefaults，不碰真实设置
private func freshDefaults() -> (defaults: UserDefaults, name: String) {
    let name = "yilan-lang-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

@Suite("界面语言设置")
@MainActor
struct LanguageSettingsTests {
    @Test("跟随系统：系统语言是中文或英文就用它，否则用英文")
    func resolveSystem() {
        #expect(AppLanguage.resolve(systemPreferred: ["zh-Hans-CN", "en-CN"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve(systemPreferred: ["en-GB", "zh-Hans"]) == .english)
        #expect(AppLanguage.resolve(systemPreferred: ["zh-Hant-TW"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve(systemPreferred: ["fr-FR", "zh-Hans"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve(systemPreferred: ["ja-JP", "fr-FR"]) == .english)
        #expect(AppLanguage.resolve(systemPreferred: []) == .english)
        #expect(AppLanguage.english.resolved(systemPreferred: ["zh-Hans"]) == .english)
        #expect(AppLanguage.system.resolved(systemPreferred: ["de"]) == .english)
    }

    @Test("系统语言里没有中文和英文时才需要改成英文")
    func fallback() {
        #expect(AppLanguage.needsFallback(systemPreferred: ["ja-JP", "fr-FR"]))
        #expect(!AppLanguage.needsFallback(systemPreferred: ["ja-JP", "en-US"]))
        #expect(!AppLanguage.needsFallback(systemPreferred: ["zh-Hant-HK"]))
    }

    @Test("选具体语言时写 AppleLanguages，跟随系统时删掉")
    func storesAppleLanguages() {
        // 只看这份存储自己写了什么（object(forKey:) 会读到系统全局的 AppleLanguages）
        let (defaults, name) = freshDefaults()
        let stored = { defaults.persistentDomain(forName: name) ?? [:] }
        let settings = LanguageSettings(defaults: defaults, running: .simplifiedChinese, systemPreferred: { ["zh-Hans"] })
        #expect(settings.choice == .system)
        settings.choice = .english
        #expect(stored()["AppleLanguages"] as? [String] == ["en"])
        #expect(LanguageSettings(defaults: defaults, running: .english).choice == .english)
        settings.choice = .simplifiedChinese
        #expect(stored()["AppleLanguages"] as? [String] == ["zh-Hans"])
        settings.choice = .system
        #expect(stored()["AppleLanguages"] == nil)
        #expect(stored()[LanguageSettings.Key.choice] == nil)
        #expect(LanguageSettings.storedChoice(in: defaults) == .system)
    }

    @Test("新选择和正在用的语言不一样时才提示重新打开")
    func needsRelaunch() {
        let settings = LanguageSettings(defaults: freshDefaults().defaults, running: .simplifiedChinese, systemPreferred: { ["zh-Hans-CN"] })
        #expect(!settings.needsRelaunch)
        settings.choice = .english
        #expect(settings.needsRelaunch)
        settings.choice = .simplifiedChinese
        #expect(!settings.needsRelaunch)   // 和跟随系统的结果一样
        let japanese = LanguageSettings(defaults: freshDefaults().defaults, running: .english, systemPreferred: { ["ja-JP"] })
        #expect(!japanese.needsRelaunch)   // 跟随系统 → 英文，正是现在的语言
        japanese.choice = .simplifiedChinese
        #expect(japanese.needsRelaunch)
    }

    @Test("重新打开时去掉 -AppleLanguages 参数，其他参数保留")
    func relaunchArguments() {
        #expect(LanguageSettings.relaunchArguments(["-AppleLanguages", "(en)", "--defaults-suite=shot", "/tmp/a.jpg"])
                == ["--defaults-suite=shot", "/tmp/a.jpg"])
        #expect(LanguageSettings.relaunchArguments([]) == [])
    }
}
