// Localisation helpers.
//
// The UI ships in English, Simplified Chinese (zh-Hans) and Traditional Chinese
// (zh-Hant, Taiwan vocabulary). Strings live in Resources/<lang>.lproj/Localizable.strings
// and are copied into Contents/Resources by scripts/build.sh. macOS picks the
// language from the system preferences (CFBundleLocalizations in Info.plist).
//
// Keys: short UI strings use the English text itself as the key; longer copy
// (the welcome guide) uses dotted identifiers such as "onboarding.veil.p1.title".
// scripts/check_strings.py verifies every key exists in all three tables.

import Foundation

enum L10n {
    /// Bundle that strings are read from. Always `.main` in the app; the
    /// `--render-onboarding` developer flag swaps it to render other languages.
    static var bundle: Bundle = .main
}

/// Localised string for `key` (falls back to the key itself, i.e. the English text).
func L(_ key: String) -> String {
    L10n.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Localised format string with arguments, e.g. `LF("Ignore %@", name)`.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

// MARK: - Language choice

/// The languages the UI ships in, plus "follow the system".
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    var id: String { rawValue }

    /// Label for pickers. The three languages are always shown in their own script.
    var nativeName: String {
        switch self {
        case .system: return L("Follow System")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }

    /// The system's preferred language mapped onto what we ship:
    /// zh-Hant / zh-TW / zh-HK / zh-MO → Traditional, any other zh → Simplified, else English.
    static var systemDefault: AppLanguage {
        // Read the GLOBAL preference so an override stored in this app's own domain is ignored.
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        for tag in global ?? Locale.preferredLanguages {
            let t = tag.lowercased()
            if t.hasPrefix("zh") {
                return (t.contains("hant") || t.hasSuffix("-tw") || t.hasSuffix("-hk") || t.hasSuffix("-mo")) ? .zhHant : .zhHans
            }
            if t.hasPrefix("en") { return .en }
        }
        return .en
    }

    var resolved: AppLanguage { self == .system ? Self.systemDefault : self }
}

/// Holds the user's language choice. Changing it
///  * writes `AppleLanguages` into the app's own UserDefaults domain, so the whole app
///    (and Sparkle's dialogs) use it from the next launch, and
///  * swaps `L10n.bundle` and publishes the change so open windows and menus re-render now.
/// `.system` removes the override.
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    private static let key = "AppleLanguages"

    /// The stored override (`.system` when none is set).
    @Published private(set) var selection: AppLanguage
    /// The language actually shown.
    var effective: AppLanguage { selection.resolved }

    private init() {
        selection = Self.storedOverride()
        L10n.bundle = Self.bundle(for: selection.resolved)
    }

    /// `persist: false` is for offscreen rendering, which must not touch real preferences.
    func set(_ lang: AppLanguage, persist: Bool = true) {
        if persist {
            if lang == .system { UserDefaults.standard.removeObject(forKey: Self.key) }
            else { UserDefaults.standard.set([lang.rawValue], forKey: Self.key) }
        }
        L10n.bundle = Self.bundle(for: lang.resolved)
        selection = lang
    }

    private static func storedOverride() -> AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let tag = (UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String])?.first?.lowercased()
        else { return .system }
        if tag.hasPrefix("zh") { return (tag.contains("hant") || tag.hasSuffix("-tw") || tag.hasSuffix("-hk")) ? .zhHant : .zhHans }
        if tag.hasPrefix("en") { return .en }
        return .system
    }

    private static func bundle(for lang: AppLanguage) -> Bundle {
        Bundle.main.path(forResource: lang.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
