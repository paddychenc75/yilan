import AppKit
import Foundation
import Observation

/// 界面语言（设置 · 通用 · 语言）：跟随系统 / 简体中文 / English。
/// 以后加语言：在字符串目录里加翻译，再在这里加一个 case、在 project.yml 的 CFBundleLocalizations 里加上
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 一览带的界面语言（和 CFBundleLocalizations 一致）
    static let supported: [AppLanguage] = [.simplifiedChinese, .english]

    /// 系统语言不是中文也不是英文时用的语言
    static let fallback: AppLanguage = .english

    /// 菜单里显示的名字：语言名称用它自己的写法（中文界面里也写 English），不翻译
    var title: LocalizedStringResource {
        switch self {
        case .system: "跟随系统"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    /// 实际使用的界面语言（不会是 .system）
    func resolved(systemPreferred: [String]) -> AppLanguage {
        self == .system ? Self.resolve(systemPreferred: systemPreferred) : self
    }

    /// 跟随系统：按系统首选语言的顺序，第一个中文或英文就是界面语言；都不是时用英文。
    /// 繁体中文等其他中文也用简体中文（一览目前只有简体中文翻译）
    static func resolve(systemPreferred: [String]) -> AppLanguage {
        for identifier in systemPreferred {
            switch Locale.Language(identifier: identifier).languageCode?.identifier {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return fallback
    }

    /// 系统首选语言里一个一览带的语言都没有（这时系统会退回开发语言，要改成 fallback）
    static func needsFallback(systemPreferred: [String]) -> Bool {
        !systemPreferred.contains { ["zh", "en"].contains(Locale.Language(identifier: $0).languageCode?.identifier) }
    }
}

/// 语言设置的读写。选了具体语言时在一览自己的 UserDefaults 里写 AppleLanguages，
/// 跟随系统时删掉它；系统在下次启动时按它选界面语言，所以改完要重新打开一览才生效。
/// 截图和测试用 `--defaults-suite=` 换的独立存储里写 AppleLanguages 不会改变界面语言，只用来验证逻辑
@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings(defaults: AppDefaults.store)

    enum Key {
        /// 设置里的选择：system / zh-Hans / en
        static let choice = "appLanguage"
        /// 系统读取的界面语言列表
        static let appleLanguages = "AppleLanguages"
    }

    /// 设置里的选择；改动立刻写进 UserDefaults
    var choice: AppLanguage {
        didSet { save() }
    }

    /// 这次启动实际在用的界面语言
    let running: AppLanguage

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemPreferred: () -> [String]

    init(defaults: UserDefaults,
         running: AppLanguage? = nil,
         systemPreferred: @escaping () -> [String] = LanguageSettings.systemPreferredLanguages) {
        self.defaults = defaults
        self.systemPreferred = systemPreferred
        choice = Self.storedChoice(in: defaults)
        self.running = running ?? Self.runningLanguage()
    }

    /// 改了之后要重新打开才能变成新语言（新选择对应的语言和现在用的不一样）
    var needsRelaunch: Bool {
        choice.resolved(systemPreferred: systemPreferred()) != running
    }

    private func save() {
        switch choice {
        case .system:
            defaults.removeObject(forKey: Key.choice)
            defaults.removeObject(forKey: Key.appleLanguages)
        case .simplifiedChinese, .english:
            defaults.set(choice.rawValue, forKey: Key.choice)
            defaults.set([choice.rawValue], forKey: Key.appleLanguages)
        }
    }

    static func storedChoice(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: Key.choice).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// 现在界面用的语言（系统按 AppleLanguages 从一览带的语言里选出来的）
    static func runningLanguage(bundle: Bundle = .main) -> AppLanguage {
        bundle.preferredLocalizations.first.flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    /// “系统”的首选语言：启动参数 `-AppleLanguages` 优先（截图时用来模拟系统语言），
    /// 否则是系统设置里的语言列表（不受一览自己写的 AppleLanguages 影响）
    nonisolated static func systemPreferredLanguages() -> [String] {
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Key.appleLanguages]
        if let list = argument as? [String], !list.isEmpty { return list }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[Key.appleLanguages]
        if let list = global as? [String], !list.isEmpty { return list }
        return Locale.preferredLanguages
    }

    /// 启动时调用（在读取任何界面文字之前）：跟随系统、而系统语言既不是中文也不是英文时，
    /// 系统默认会退回开发语言（简体中文）；这里改成英文
    static func applyFallbackAtLaunch(defaults: UserDefaults = AppDefaults.store) {
        guard storedChoice(in: defaults) == .system else { return }
        let preferred = systemPreferredLanguages()
        guard AppLanguage.needsFallback(systemPreferred: preferred) else { return }
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[Key.appleLanguages] = [AppLanguage.fallback.rawValue] + preferred
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    // MARK: - 重新打开

    /// 重新打开时带上的启动参数：去掉 `-AppleLanguages (…)`，让新的语言设置生效
    nonisolated static func relaunchArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if argument == "-\(Key.appleLanguages)" { skipNext = true; continue }
            result.append(argument)
        }
        return result
    }

    /// 先退出现在这个，再由一个小脚本等它退干净后重新打开。
    /// 不能用“新开一个实例”的方式：程序坞会把新实例当成另一个应用，在固定的图标旁边再多出一个图标。
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let arguments = relaunchArguments(Array(CommandLine.arguments.dropFirst()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 = 应用路径，其余是原来的启动参数；最多等 10 秒
        let script = #"i=0; while kill -0 \#(pid) 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; app="$0"; if [ $# -gt 0 ]; then /usr/bin/open "$app" --args "$@"; else /usr/bin/open "$app"; fi"#
        process.arguments = ["-c", script, Bundle.main.bundlePath] + arguments
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Log.app.error("重新打开失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
