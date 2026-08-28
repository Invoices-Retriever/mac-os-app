import Foundation

/// Language selection for the whole application.
///
/// `String(localized:locale:)` does not do what its signature suggests: the
/// `locale` argument affects formatting, not which `.lproj` is read. Switching
/// language inside a running app means resolving against a bundle for that
/// specific language, which is what this type does.
///
/// Everything user-facing goes through here — views, alerts, and the error
/// messages in this module — so there is one mechanism rather than one for
/// SwiftUI and another for everything else.
public enum Localization {

    public enum Language: String, CaseIterable, Sendable, Codable, Identifiable {
        case english = "en"
        case french = "fr"

        public var id: String { rawValue }

        /// Each language names itself in itself. A French speaker looking for
        /// their language scans for "Français", not for "French".
        public var endonym: String {
            switch self {
            case .english: return "English"
            case .french: return "Français"
            }
        }

        public var locale: Locale { Locale(identifier: rawValue) }
    }

    /// `nil` means "follow the system", which is the default and what most
    /// people want.
    nonisolated(unsafe) private static var override: Language?
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]
    private static let lock = NSLock()

    public static func setLanguage(_ language: Language?) {
        lock.lock(); defer { lock.unlock() }
        override = language
    }

    public static var current: Language {
        lock.lock()
        let chosen = override
        lock.unlock()
        if let chosen { return chosen }
        return systemLanguage
    }

    /// The best match between what the user's system asks for and what we
    /// actually ship. Anything we do not have falls back to English.
    public static var systemLanguage: Language {
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2)).lowercased()
            if let language = Language(rawValue: code) { return language }
        }
        return .english
    }

    /// Formatting locale — dates, amounts, number separators. Distinct from the
    /// interface language on purpose: someone can read the interface in English
    /// while still wanting French date and currency conventions, which is the
    /// common case for a French user of an English-language tool.
    public static var formattingLocale: Locale { Locale.current }

    /// Resolves `key` in `bundle` for the chosen language, falling back to the
    /// key itself. Keys are the English source strings, so an unbundled build —
    /// `swift run`, or a contributor's first launch — reads correctly in
    /// English rather than showing identifiers.
    public static func string(_ key: String, in bundle: Bundle, table: String? = nil) -> String {
        let target = localizedBundle(for: current, in: bundle) ?? bundle
        return target.localizedString(forKey: key, value: key, table: table)
    }

    private static func localizedBundle(for language: Language, in bundle: Bundle) -> Bundle? {
        let cacheKey = "\(bundle.bundlePath)#\(language.rawValue)"
        lock.lock()
        if let cached = cache[cacheKey] { lock.unlock(); return cached }
        lock.unlock()

        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let resolved = Bundle(path: path) else {
            return nil
        }
        lock.lock()
        cache[cacheKey] = resolved
        lock.unlock()
        return resolved
    }
}

/// The same strings, for browser drivers outside this module.
public func coreString(_ key: String, _ arguments: CVarArg...) -> String {
    arguments.isEmpty
        ? Localization.string(key, in: .module)
        : String(format: Localization.string(key, in: .module), arguments: arguments)
}

/// User-facing strings that belong to the core rather than to the interface:
/// error messages, mostly, which the app shows verbatim in an alert.
func core(_ key: String) -> String {
    Localization.string(key, in: .module)
}

/// Counted strings for the core's own messages, resolved through IRCore's
/// `.stringsdict`. French treats zero as singular where English does not, and
/// a message that says "0 documents attached" in French is a small tell that
/// nobody read it.
func coreCount(_ key: String, _ count: Int) -> String {
    String(format: Localization.string(key, in: .module), count)
}

/// Same, with positional arguments. `%@` in the catalogue, in an order the
/// translator can change with `%1$@`.
func core(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.string(key, in: .module), arguments: arguments)
}


public extension String {
    /// Trimmed, or nil when there was nothing but whitespace. Empty and absent
    /// mean the same thing everywhere in this application, and saying so once
    /// is better than a `.isEmpty ? nil :` at every call site.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
