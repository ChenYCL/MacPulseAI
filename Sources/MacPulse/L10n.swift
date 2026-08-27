import Foundation

/// 轻量双语层：所有用户可见文案以 `L10n.s("中文", "English")` 内联书写，
/// 跟随系统语言，设置页可手动覆盖（自动/中文/English）。
/// 选择代码内字典而非 .strings 文件：SPM 可执行目标手工打包 .app 时无需资源 bundles，
/// 且单测可直接断言双语文案。
enum L10n {
    enum Lang: String {
        case zh
        case en

        /// 跟随系统首选语言；未识别时回落中文。
        static func detect() -> Lang {
            for language in Locale.preferredLanguages {
                if language.hasPrefix("zh") { return .zh }
                if language.hasPrefix("en") { return .en }
            }
            return .zh
        }
    }

    /// 由 Settings.uiLanguage 写入："auto" / "zh" / "en"。
    static var overrideCode: String?
    /// 单测强制语言。
    static var forced: Lang?

    static var current: Lang {
        if let forced { return forced }
        switch overrideCode {
        case "zh": return .zh
        case "en": return .en
        default: return Lang.detect()
        }
    }

    static func s(_ zh: String, _ en: String) -> String {
        current == .zh ? zh : en
    }
}
