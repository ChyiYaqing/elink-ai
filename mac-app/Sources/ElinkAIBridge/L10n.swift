import Foundation

/// 界面语言。未显式选择时跟随系统首选语言。
enum AppLanguage: String, CaseIterable {
    case chinese = "zh"
    case english = "en"

    static let defaultsKey = "elink_language"

    static var current: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let value = AppLanguage(rawValue: raw) {
                return value
            }
            return systemDefault
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .chinese : .english
    }
}

/// 按当前语言取文案。界面字符串在调用点成对给出，避免维护独立的 key 表；
/// 视图每次渲染都会重新求值，语言切换后由 ObservableObject 触发重渲染即可生效。
func tr(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .chinese ? zh : en
}
