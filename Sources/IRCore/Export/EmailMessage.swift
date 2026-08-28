import Foundation

/// What the e-mail export actually says.
///
/// Separated from the AppKit that opens the compose window so it can be tested,
/// and because it is the part that matters: whoever receives this has to
/// reconcile it, and a message that is twelve attachments and no words is work
/// pushed onto them.
public enum EmailMessage {

    /// One invoice, one message. An accounting tool's intake address reads a
    /// message as a single document, so the subject has to identify that one
    /// invoice rather than a batch.
    public static func subject(for document: InvoiceDocument, entityName: String?) -> String {
        var parts: [String] = []
        if let issuer = document.issuer?.nilIfEmpty { parts.append(issuer) }
        if let number = document.number?.nilIfEmpty { parts.append(number) }
        if let date = document.issuedOn { parts.append(InvoiceDateParser.isoString(date)) }
        let described = parts.isEmpty
            ? (document.relativePath as NSString).lastPathComponent
            : parts.joined(separator: " ")
        guard let name = entityName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return core("Invoice — %@", described)
        }
        return core("Invoice — %1$@ — %2$@", name, described)
    }

    /// The same facts as a line of the batch manifest, laid out for a message
    /// carrying one document.
    public static func body(for document: InvoiceDocument) -> String {
        var lines: [String] = []
        if let issuer = document.issuer?.nilIfEmpty { lines.append(issuer) }
        if let number = document.number?.nilIfEmpty { lines.append(core("Number: %@", number)) }
        if let date = document.issuedOn {
            lines.append(core("Date: %@", InvoiceDateParser.isoString(date)))
        }
        if let total = document.total { lines.append(core("Total: %@", total.formatted())) }
        return lines.isEmpty ? core("Invoice") : lines.joined(separator: "\n")
    }

    public static func subject(for documents: [InvoiceDocument], entityName: String?) -> String {
        let period = self.period(of: documents)
        let name = entityName?.trimmingCharacters(in: .whitespaces)
        switch (name?.isEmpty == false ? name : nil, period) {
        case let (name?, period?): return core("Invoices — %1$@ — %2$@", name, period)
        case let (name?, nil): return core("Invoices — %@", name)
        case let (nil, period?): return core("Invoices — %@", period)
        default: return core("Invoices")
        }
    }

    /// A manifest a person can tick off: one line per invoice, oldest first,
    /// with the total when every document shares a currency.
    public static func body(for documents: [InvoiceDocument]) -> String {
        var lines: [String] = [coreCount("%d document", documents.count)]

        let amounts = documents.compactMap(\.total)
        if let currency = amounts.first?.currency, amounts.allSatisfy({ $0.currency == currency }) {
            let total = Money(cents: amounts.reduce(0) { $0 + $1.cents }, currency: currency)
            lines.append(core("Total: %@", total.formatted()))
        }
        lines.append("")

        let ordered = documents.sorted {
            ($0.issuedOn ?? .distantPast) < ($1.issuedOn ?? .distantPast)
        }
        for document in ordered {
            let date = document.issuedOn.map(InvoiceDateParser.isoString) ?? "—"
            let issuer = document.issuer ?? "—"
            let number = document.number ?? "—"
            let total = document.total?.formatted() ?? "—"
            lines.append("\(date)  \(issuer)  \(number)  \(total)")
        }
        return lines.joined(separator: "\n")
    }

    /// "March 2026", or "January 2026 – March 2026" across a range. Nil when no
    /// document carries a date, in which case the subject simply omits it
    /// rather than inventing a period.
    public static func period(of documents: [InvoiceDocument]) -> String? {
        let dates = documents.compactMap(\.issuedOn).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Localization.formattingLocale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        let start = formatter.string(from: first), end = formatter.string(from: last)
        return start == end ? start : "\(start) – \(end)"
    }
}
