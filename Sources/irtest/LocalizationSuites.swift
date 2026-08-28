import Foundation
import IRCore

/// A missing translation is invisible until a French user sees an English
/// sentence in the middle of a French screen, so the catalogues are checked
/// against each other mechanically rather than by eye.
@MainActor
func runLocalizationSuites() async {

    await suite("Localization") {
        await test("Both languages ship, and each names itself in itself") {
            expectEqual(Localization.Language.allCases.count, 2)
            expectEqual(Localization.Language.english.endonym, "English")
            expectEqual(Localization.Language.french.endonym, "Français")
        }

        await test("The core catalogues are present in the bundle") {
            // Not via `Bundle.localizations`: SwiftPM's generated bundle has no
            // CFBundleLocalizations in its Info.plist, so that property is
            // empty even though the .lproj folders are right there.
            for language in ["en", "fr"] {
                expect(BundledResources.bundle.path(forResource: language, ofType: "lproj") != nil,
                       "the \(language) catalogue is missing from the bundle")
            }
        }

        await test("Every English key has a French translation, and vice versa") {
            func keys(_ language: String) -> Set<String> {
                guard let path = BundledResources.bundle.path(forResource: language, ofType: "lproj"),
                      let file = Bundle(path: path)?.path(forResource: "Localizable", ofType: "strings"),
                      let table = NSDictionary(contentsOfFile: file) as? [String: String] else {
                    return []
                }
                return Set(table.keys)
            }
            let english = keys("en"), french = keys("fr")
            expect(!english.isEmpty, "the English catalogue is empty or unreadable")

            let untranslated = english.subtracting(french).sorted()
            expect(untranslated.isEmpty, "not translated into French: \(untranslated.prefix(5))")

            let orphaned = french.subtracting(english).sorted()
            expect(orphaned.isEmpty, "in French but not in English: \(orphaned.prefix(5))")
        }

        await test("Format specifiers match between the two languages") {
            func table(_ language: String) -> [String: String] {
                guard let path = BundledResources.bundle.path(forResource: language, ofType: "lproj"),
                      let file = Bundle(path: path)?.path(forResource: "Localizable", ofType: "strings"),
                      let loaded = NSDictionary(contentsOfFile: file) as? [String: String] else { return [:] }
                return loaded
            }
            /// Counts %@ and %1$@ alike: a translation that drops one crashes
            /// String(format:) at run time, in the language we test least.
            func specifiers(_ value: String) -> Int {
                let pattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?@")
                return pattern.numberOfMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
            }
            let english = table("en"), french = table("fr")
            for (key, source) in english {
                guard let translation = french[key] else { continue }
                if specifiers(source) != specifiers(translation) {
                    expect(false, "'\(key)': \(specifiers(source)) placeholder(s) in English, \(specifiers(translation)) in French")
                }
            }
        }

        await test("Switching language changes what the core says") {
            Localization.setLanguage(.english)
            let english = IRError.cancelled.localizedDescription
            Localization.setLanguage(.french)
            let french = IRError.cancelled.localizedDescription
            Localization.setLanguage(nil)

            expectEqual(english, "Cancelled")
            expectEqual(french, "Annulé")
        }

        await test("An error carrying a value keeps it through translation") {
            Localization.setLanguage(.french)
            let message = IRError.domainNotAllowed(host: "evil.example.com",
                                                   allowed: ["ovh.com"]).localizedDescription
            Localization.setLanguage(.english)
            expect(message.contains("evil.example.com"), "the host was lost: \(message)")
            expect(message.contains("ovh.com"), "the allowed list was lost: \(message)")
        }

        await test("Model labels follow the chosen language") {
            Localization.setLanguage(.french)
            expectEqual(DocumentKind.creditNote.displayName, "Avoir")
            expectEqual(RunStatus.needsSignIn.displayName, "Connexion à refaire")
            expectEqual(Schedule.monthly(day: 5, hour: 9).displayName, "Chaque mois le 5 à 09:00")
            Localization.setLanguage(.english)
            expectEqual(DocumentKind.creditNote.displayName, "Credit note")
            expectEqual(Schedule.monthly(day: 5, hour: 9).displayName, "Monthly on day 5 at 09:00")
        }

        await test("An unknown key falls back to itself, so nothing shows an identifier") {
            expectEqual(Localization.string("This key does not exist anywhere", in: BundledResources.bundle),
                        "This key does not exist anywhere")
        }

        await test("Amount formatting follows the region, not the interface language") {
            // Someone reading the interface in English may still want French
            // conventions for amounts; the two settings are separate.
            let money = Money(cents: 123456, currency: "EUR")
            expect(money.formatted(locale: Locale(identifier: "fr_FR")).contains(","))
            expect(money.formatted(locale: Locale(identifier: "en_US")).contains("."))
        }
    }
}

/// The interface catalogues live in the app target, which `irtest` does not
/// link — checking them means reading the source tree. `#filePath` gives the
/// package root wherever the repository happens to be checked out, which is
/// what makes this work on a contributor's machine and on CI alike.
@MainActor
func runInterfaceCatalogueSuites() async {

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // irtest
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // package root
    let sources = packageRoot.appendingPathComponent("Sources/InvoicesRetriever")
    let resources = sources.appendingPathComponent("Resources")

    /// Every `t("…")` and `tn("…")` the interface actually calls.
    func keysUsedInCode() -> (plain: Set<String>, plural: Set<String>) {
        var plain: Set<String> = [], plural: Set<String> = []
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let plainPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z])t\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
        let pluralPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z])tn\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            for match in plainPattern.matches(in: text, range: range) {
                plain.insert((text as NSString).substring(with: match.range(at: 1)))
            }
            for match in pluralPattern.matches(in: text, range: range) {
                plural.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        return (plain.subtracting(plural), plural)
    }

    func table(_ language: String) -> [String: String] {
        let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String] ?? [:]
    }

    func pluralKeys(_ language: String) -> Set<String> {
        let url = resources.appendingPathComponent("\(language).lproj/Localizable.stringsdict")
        guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }

    await suite("Interface catalogues") {
        let used = keysUsedInCode()

        await test("Both catalogues exist and are readable") {
            expect(!table("en").isEmpty, "the English catalogue is empty or unreadable")
            expect(!table("fr").isEmpty, "the French catalogue is empty or unreadable")
        }

        await test("Every string the interface asks for is in both catalogues") {
            expect(!used.plain.isEmpty, "no t(…) calls found — the scan is broken, not the catalogue")
            for language in ["en", "fr"] {
                let missing = used.plain.subtracting(Set(table(language).keys)).sorted()
                expect(missing.isEmpty, "missing from \(language): \(missing.prefix(5))")
            }
        }

        await test("No catalogue entry is dead weight") {
            let english = Set(table("en").keys)
            let unused = english.subtracting(used.plain).sorted()
            expect(unused.isEmpty, "in the catalogue but never used: \(unused.prefix(5))")
        }

        await test("French translates every English key, and invents none") {
            let english = Set(table("en").keys), french = Set(table("fr").keys)
            expect(english.subtracting(french).sorted().isEmpty,
                   "not translated: \(english.subtracting(french).sorted().prefix(5))")
            expect(french.subtracting(english).sorted().isEmpty,
                   "orphaned: \(french.subtracting(english).sorted().prefix(5))")
        }

        await test("Nothing was left untranslated by copying the English through") {
            // A handful legitimately match: proper nouns, and "Webhook".
            let identical = ["Bearer …", "Catalogue", "Date", "E-mail", "Exports", "OK", "Organisation",
                             "Paperless-ngx", "Plugin", "Plugins", "Port", "Provider", "SHA-256",
                             "STARTTLS (587)", "TLS (465)",
                             "Source", "Sources", "Total", "Webhook", "· total %@"]
            let english = table("en"), french = table("fr")
            let lazy = english.filter { key, value in
                french[key] == value && !identical.contains(key)
            }.keys.sorted()
            expect(lazy.isEmpty, "identical in both languages: \(lazy.prefix(5))")
        }

        await test("Placeholders survive translation") {
            func specifiers(_ value: String) -> [String] {
                let pattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[@d]")
                let ns = value as NSString
                return pattern.matches(in: value, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range) }.sorted()
            }
            let english = table("en"), french = table("fr")
            for (key, source) in english {
                guard let translation = french[key] else { continue }
                if specifiers(source) != specifiers(translation) {
                    expect(false, "'\(key)': \(specifiers(source)) vs \(specifiers(translation))")
                }
            }
        }

        await test("Every counted string has a plural rule in both languages") {
            for language in ["en", "fr"] {
                let declared = pluralKeys(language)
                let missing = used.plural.subtracting(declared).sorted()
                expect(missing.isEmpty, "no plural rule in \(language) for: \(missing.prefix(5))")
                let extra = declared.subtracting(used.plural).sorted()
                expect(extra.isEmpty, "unused plural rule in \(language): \(extra.prefix(5))")
            }
        }
    }
}
