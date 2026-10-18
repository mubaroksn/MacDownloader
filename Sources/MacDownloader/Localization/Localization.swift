import DownloadCore
import Foundation

/// The language picked in Settings › Tampilan. Stored as "system", "id" or "en".
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case indonesian = "id"
    case english = "en"

    var id: String { rawValue }

    /// Each language names itself, so it can be found whatever the current language is.
    var label: String {
        switch self {
        case .system: return L("Ikut sistem")
        case .indonesian: return "Indonesia"
        case .english: return "English"
        }
    }
}

/// Which language the UI is in right now.
///
/// Source text in the code is Indonesian and doubles as the lookup key (`L("Batal")`), so
/// Indonesian needs no table and only English is looked up (`Strings.en`, generated from
/// Localization/en.json by scripts/l10n.py).
enum Lang {
    static let key = "appLanguage"

    /// "id" or "en". Read on every lookup: UserDefaults is in-memory and thread-safe, so a
    /// change in Settings applies to the next redraw with no cache to invalidate.
    static var code: String {
        switch UserDefaults.standard.string(forKey: key) {
        case "id": return "id"
        case "en": return "en"
        default: return systemCode
        }
    }

    static var isEnglish: Bool { code == "en" }

    /// What the user picked (may be "system").
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// The first of the user's preferred languages we have; English otherwise.
    static let systemCode: String = {
        for tag in Locale.preferredLanguages {
            let base = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
            if base == "id" || base == "ms" { return "id" } // Malay readers read Indonesian comfortably
            if base == "en" { return "en" }
        }
        return "en"
    }()

    /// Installs from before languages existed were Indonesian-only: keep them Indonesian
    /// instead of switching to the system language behind the user's back.
    static func migrate(existingInstall: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil, existingInstall else { return }
        defaults.set(AppLanguage.indonesian.rawValue, forKey: key)
    }

    /// Lets the engine (DownloadCore) translate its error messages too.
    static func installEngineHook() {
        EngineLocalization.lookup = { Lang.lookup($0) }
    }

    /// The template for `key` in the current language (no formatting).
    static func lookup(_ key: String) -> String {
        isEnglish ? (Strings.en[key] ?? key) : key
    }

    /// Fills a template. English plurals are written "one|other" and picked by the first
    /// integer argument; Indonesian has no plural forms, so its keys never contain "|".
    static func format(_ template: String, _ args: [CVarArg]) -> String {
        var text = template
        if text.contains("|") {
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let count = args.lazy.compactMap { $0 as? Int }.first ?? 0
            text = String(count == 1 ? parts[0] : parts[1])
        }
        return args.isEmpty ? text : String(format: text, arguments: args)
    }
}

/// Translates Indonesian source text into the current language.
func L(_ key: String) -> String {
    Lang.lookup(key)
}

/// Translates a format string (`%ld` for integers, `%@` for strings) and fills it in.
func L(_ key: String, _ args: CVarArg...) -> String {
    Lang.format(Lang.lookup(key), args)
}
