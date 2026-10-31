import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case sv, en
    var id: String { rawValue }
    var name: String { self == .sv ? "Svenska" : "English" }
}

/// Appens språk, valt under inställningarna. Svenska om inget är valt.
enum L {
    static let key = "language"
    static var lang: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sv
    }
    static var isSwedish: Bool { lang == .sv }

    /// Svensk eller engelsk text efter valt språk.
    static func t(_ sv: String, _ en: String) -> String { isSwedish ? sv : en }
}
