import Foundation

/// The regular expressions behind the text-extraction fallback (F6.2).
///
/// These are ordered: the first pattern that matches wins, so the most
/// specific and least ambiguous ones come first. French, English and German
/// are covered at v1 because that is where the suppliers are; the shape of the
/// table makes adding a language a data change, not a code change.
enum InvoicePatterns {

    struct Pattern {
        let regex: String
        /// Roughly how much we trust a hit. A label as explicit as "Montant
        /// TTC" deserves more confidence than a bare currency amount found
        /// somewhere on the page.
        let confidence: Double
    }

    // MARK: - Invoice number

    static let number: [Pattern] = [
        .init(regex: "(?i)(?:facture|invoice|rechnung)\\s*(?:n[o°º]|nr\\.?|number|no\\.?|#)\\s*[:\\s]\\s*([A-Z0-9][A-Z0-9\\-/_.]{2,30})", confidence: 0.9),
        .init(regex: "(?i)(?:n[o°º]|nr\\.?)\\s*(?:de\\s+)?(?:facture|rechnung)\\s*[:\\s]\\s*([A-Z0-9][A-Z0-9\\-/_.]{2,30})", confidence: 0.9),
        .init(regex: "(?i)(?:invoice|facture|rechnung|belegnummer|document)\\s*(?:id|ref(?:erence)?)?\\s*[:#]\\s*([A-Z0-9][A-Z0-9\\-/_.]{2,30})", confidence: 0.75),
        .init(regex: "(?i)\\b(?:ref(?:erence|\\.)?)\\s*[:#]\\s*([A-Z0-9][A-Z0-9\\-/_.]{4,30})", confidence: 0.5),
    ]

    // MARK: - Dates

    static let date: [Pattern] = [
        .init(regex: "(?i)(?:date\\s+(?:de\\s+)?(?:facture|facturation|d['’]émission)|invoice\\s+date|rechnungsdatum|issued\\s+on|date\\s+of\\s+issue)\\s*[:\\s]\\s*([0-9]{1,2}[/.\\-][0-9]{1,2}[/.\\-][0-9]{2,4})", confidence: 0.9),
        .init(regex: "(?i)(?:date\\s+(?:de\\s+)?(?:facture|facturation)|invoice\\s+date|rechnungsdatum)\\s*[:\\s]\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", confidence: 0.9),
        .init(regex: "(?i)(?:date|datum)\\s*[:\\s]\\s*([0-9]{1,2}[/.\\-][0-9]{1,2}[/.\\-][0-9]{2,4})", confidence: 0.6),
        .init(regex: "(?i)(?:date|datum)\\s*[:\\s]\\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", confidence: 0.6),
        .init(regex: "\\b([0-9]{4}-[0-9]{2}-[0-9]{2})\\b", confidence: 0.35),
        .init(regex: "\\b([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})\\b", confidence: 0.3),
    ]

    // MARK: - Amounts

    /// The number itself: "1 234,56", "1,234.56", "1234.56", with optional
    /// currency symbol on either side.
    private static let amount = "((?:[€$£]\\s*)?-?[0-9][0-9\\s.,\u{00A0}\u{202F}]*[0-9](?:\\s*(?:€|EUR|USD|\\$|£|GBP|CHF))?)"

    static let total: [Pattern] = [
        .init(regex: "(?i)(?:total\\s+ttc|montant\\s+ttc|net\\s+à\\s+payer|total\\s+amount\\s+due|amount\\s+due|gesamtbetrag|rechnungsbetrag|brutto(?:betrag)?|total\\s+incl[.\\s]*(?:vat|tax))\\s*[:\\s]\\s*" + amount, confidence: 0.92),
        .init(regex: "(?i)(?:total|montant|betrag|summe)\\s*(?:\\(.*?\\))?\\s*[:\\s]\\s*" + amount, confidence: 0.65),
        .init(regex: "(?i)(?:à\\s+payer|to\\s+pay|zu\\s+zahlen|balance\\s+due)\\s*[:\\s]\\s*" + amount, confidence: 0.8),
    ]

    static let net: [Pattern] = [
        .init(regex: "(?i)(?:total\\s+ht|montant\\s+ht|sous[- ]total|subtotal|net\\s+amount|nettobetrag|total\\s+excl[.\\s]*(?:vat|tax)|zwischensumme)\\s*[:\\s]\\s*" + amount, confidence: 0.9),
    ]

    static let vat: [Pattern] = [
        .init(regex: "(?i)(?:tva|t\\.v\\.a\\.|vat|mwst\\.?|umsatzsteuer|ust\\.?|sales\\s+tax)\\s*(?:\\([0-9.,]+\\s*%\\))?\\s*(?:[0-9.,]+\\s*%)?\\s*[:\\s]\\s*" + amount, confidence: 0.85),
    ]

    // MARK: - Identifiers

    /// EU VAT identification numbers. Worth extracting because it is what an
    /// accountant checks first on a cross-border invoice.
    static let vatNumber: [Pattern] = [
        .init(regex: "(?i)(?:n[o°º]\\s*(?:de\\s*)?tva(?:\\s*intracommunautaire)?|vat\\s*(?:id|number|no\\.?)|ust[-\\s]?idnr\\.?|umsatzsteuer[-\\s]?id)\\s*[:\\s]\\s*((?:AT|BE|BG|CY|CZ|DE|DK|EE|EL|ES|FI|FR|HR|HU|IE|IT|LT|LU|LV|MT|NL|PL|PT|RO|SE|SI|SK|XI|GB)[0-9A-Z]{8,14})", confidence: 0.9),
        .init(regex: "\\b((?:FR|DE|BE|LU|ES|IT|NL|IE|PT|AT)[0-9A-Z]{8,13})\\b", confidence: 0.5),
    ]

    /// Words whose presence says this is a credit note, not an invoice. Getting
    /// this wrong flips the sign of an amount in the user's books.
    static let creditNoteMarkers = [
        "avoir", "note de crédit", "note de credit",
        "credit note", "credit memo", "refund",
        "gutschrift", "stornorechnung",
    ]

    static let receiptMarkers = ["reçu", "recu", "receipt", "quittung", "ticket de caisse", "payment receipt"]

    static func firstMatch(_ patterns: [Pattern], in text: String) -> (value: String, confidence: Double)? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.dotMatchesLineSeparators]) else {
                continue
            }
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else {
                continue
            }
            let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return (value, pattern.confidence) }
        }
        return nil
    }
}
