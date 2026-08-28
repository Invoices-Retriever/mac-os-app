import Foundation

/// Amounts are integers of the currency's minor unit. Floating point has no
/// business anywhere near an invoice total.
public struct Money: Codable, Hashable, Sendable {
    public var cents: Int
    public var currency: String

    public init(cents: Int, currency: String) {
        self.cents = cents
        self.currency = currency.uppercased()
    }

    public var decimalValue: Decimal {
        Decimal(cents) / 100
    }

    /// Formatted with the user's regional settings, which are deliberately
    /// separate from the interface language: reading the interface in English
    /// does not mean wanting "1,234.56 €" instead of "1 234,56 €".
    public func formatted(locale: Locale = Localization.formattingLocale) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = locale
        return f.string(from: decimalValue as NSDecimalNumber) ?? "\(decimalValue) \(currency)"
    }
}

public enum MoneyParser {
    /// Currency symbols and codes we can recognise in a scraped string.
    private static let symbols: [(String, String)] = [
        ("€", "EUR"), ("EUR", "EUR"),
        ("$", "USD"), ("USD", "USD"),
        ("£", "GBP"), ("GBP", "GBP"),
        ("CHF", "CHF"), ("SEK", "SEK"), ("NOK", "NOK"), ("DKK", "DKK"),
        ("PLN", "PLN"), ("CZK", "CZK"), ("CAD", "CAD"), ("AUD", "AUD"),
    ]

    /// Parses the shapes invoices actually use: "1 234,56 €", "$1,234.56",
    /// "1.234,56 EUR", "-12.00", "1234". Returns nil rather than guessing when
    /// the string carries no digits.
    public static func parse(_ raw: String, defaultCurrency: String? = nil) -> Money? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var currency = defaultCurrency
        let upper = trimmed.uppercased()
        for (symbol, code) in symbols where upper.contains(symbol) {
            currency = code
            break
        }

        // Keep digits, separators and a leading sign.
        var kept = ""
        for ch in trimmed {
            if ch.isNumber || ch == "," || ch == "." || ch == "-" || ch == "\u{2212}" {
                kept.append(ch == "\u{2212}" ? "-" : ch)
            } else if ch == " " || ch == "\u{00A0}" || ch == "\u{202F}" {
                continue  // thin and non-breaking spaces are thousands separators
            }
        }
        guard kept.contains(where: \.isNumber) else { return nil }

        let negative = kept.hasPrefix("-") || trimmed.hasPrefix("(")
        kept = kept.replacingOccurrences(of: "-", with: "")

        let normalised = normaliseSeparators(kept)
        guard let decimal = Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }

        let cents = NSDecimalNumber(decimal: decimal * 100).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false)
        ).intValue

        return Money(cents: negative ? -cents : cents, currency: currency ?? "EUR")
    }

    /// Decides which of "," and "." is the decimal mark. The last separator
    /// wins when it is followed by exactly two digits; otherwise both are
    /// thousands separators.
    private static func normaliseSeparators(_ s: String) -> String {
        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")

        switch (lastComma, lastDot) {
        case (nil, nil):
            return s
        case (let c?, nil):
            return decimalMarkIsPlausible(s, at: c) ? replace(s, at: c) : s.replacingOccurrences(of: ",", with: "")
        case (nil, let d?):
            return decimalMarkIsPlausible(s, at: d) ? s : s.replacingOccurrences(of: ".", with: "")
        case (let c?, let d?):
            let mark = c > d ? c : d
            var out = s
            let other: Character = c > d ? "." : ","
            out = out.replacingOccurrences(of: String(other), with: "")
            if let markIndex = out.lastIndex(of: mark == c ? "," : ".") {
                return replace(out, at: markIndex)
            }
            return out
        }
    }

    /// Decides whether the separator at `index` is a decimal mark rather than a
    /// thousands separator.
    ///
    /// One or two digits after it can only be a decimal mark. Three digits is
    /// the ambiguous case — "1.005" is a thousand and five in German — and the
    /// tie-break is the group in front: a thousands separator never follows a
    /// bare zero or a group with a leading zero, so "0.005" is five thousandths
    /// and "1.005" is one thousand and five.
    private static func decimalMarkIsPlausible(_ s: String, at index: String.Index) -> Bool {
        let after = s.distance(from: s.index(after: index), to: s.endIndex)
        if after == 1 || after == 2 { return true }
        guard after == 3 else { return false }
        let before = s[s.startIndex..<index]
        return before.isEmpty || before.hasPrefix("0")
    }

    private static func replace(_ s: String, at index: String.Index) -> String {
        var out = s
        out.replaceSubrange(index...index, with: ".")
        return out.replacingOccurrences(of: ",", with: "")
    }
}
