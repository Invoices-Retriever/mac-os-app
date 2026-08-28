import Foundation
import IRCore

/// Interface strings.
///
/// `t("Sources")` reads better at the call site than a symbolic key would, and
/// it means an unbundled build — `swift run`, a contributor's first launch —
/// shows correct English rather than a screen full of identifiers. The cost is
/// that changing an English string orphans its translation, which the test
/// suite catches by comparing the two catalogues key for key.
func t(_ key: String) -> String {
    Localization.string(key, in: .module)
}

/// The same, with values substituted. Placeholders are `%@` in the catalogue,
/// or `%1$@` where a translator needs to reorder them — French and English put
/// dates and quantities in different places often enough for that to matter.
func t(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.string(key, in: .module), arguments: arguments)
}

/// Counted strings, resolved through `Localizable.stringsdict`.
///
/// This exists because "%d document(s)" is not good enough in either language
/// and is wrong in French for a different reason than in English: French treats
/// zero as singular ("0 document"), English does not ("0 documents"). The
/// stringsdict encodes each language's own rule.
func tn(_ key: String, _ count: Int) -> String {
    String(format: Localization.string(key, in: .module), count)
}

/// Percentages, amounts and counts follow the user's regional settings rather
/// than the interface language.
func number(_ value: Int) -> String {
    value.formatted(.number.locale(Localization.formattingLocale))
}
