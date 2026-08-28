import Foundation

/// Portals print dates in every format imaginable. We try ISO first because
/// plugins are asked to emit ISO, then the common FR/EN/DE written forms.
public enum InvoiceDateParser {
    private static let isoFormats = [
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
        "yyyy/MM/dd",
    ]

    private static let numericFormats = [
        "dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy",
        "MM/dd/yyyy",
        "dd/MM/yy", "dd.MM.yy",
        "yyyyMMdd",
    ]

    private static let writtenFormats = ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy", "d. MMMM yyyy"]
    private static let writtenLocales = ["en_US_POSIX", "fr_FR", "de_DE", "en_GB"]

    /// Returns a date normalised to UTC midnight, so that two portals reporting
    /// the same calendar day in different timezones dedupe against each other.
    public static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        for format in isoFormats + numericFormats {
            if let d = formatter(format, locale: "en_US_POSIX").date(from: s) { return startOfDayUTC(d) }
        }
        for locale in writtenLocales {
            for format in writtenFormats {
                if let d = formatter(format, locale: locale).date(from: s) { return startOfDayUTC(d) }
            }
        }
        // Epoch seconds or milliseconds, as some JSON APIs return.
        if let n = Double(s), n > 100_000_000 {
            return startOfDayUTC(Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n))
        }
        return nil
    }

    public static func isoString(_ date: Date) -> String {
        formatter("yyyy-MM-dd", locale: "en_US_POSIX").string(from: date)
    }

    private static func startOfDayUTC(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.startOfDay(for: date)
    }

    private static func formatter(_ format: String, locale: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        f.isLenient = false
        return f
    }
}
