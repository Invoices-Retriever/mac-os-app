import AppKit
import IRCore

/// F8.4. Puts the selected invoices into a message, attachments and all.
///
/// **It does not send anything.** It opens a message in whichever mail client
/// the user has, with the PDFs attached and a summary written, and stops there.
/// That is deliberate and not a limitation to be fixed later: sending mail on
/// someone's behalf is an outward-facing act, and the person whose accountant
/// is on the other end should be the one who presses Send — and should get to
/// read what is going out first.
///
/// It also means there is no SMTP server to configure, no password to store,
/// and nothing that can quietly fail at three in the morning.
///
/// Lives in the application rather than in IRCore because it is AppKit all the
/// way down; IRCore stays free of the user interface so it can be tested and,
/// one day, ported.
final class EmailExporter: Exporter, @unchecked Sendable {
    let recipients: [String]
    let entityName: String?

    private let lock = NSLock()
    private var attachments: [URL] = []

    init(recipients: [String], entityName: String?) {
        self.recipients = recipients.filter { !$0.isEmpty }
        self.entityName = entityName
    }

    /// One destination per recipient list: invoices mailed to the bookkeeper
    /// are not "already sent" to the auditor.
    var destinationID: String {
        "email:" + (recipients.isEmpty ? "-" : recipients.sorted().joined(separator: ","))
    }
    var kind: ExportDestinationKind { .email }
    /// Nothing leaves until `finish`.
    var deliversOnFinish: Bool { true }
    var displayName: String {
        recipients.isEmpty ? t("E-mail") : t("E-mail to %@", recipients.joined(separator: ", "))
    }

    /// Nothing leaves here: the file is only noted, because a message with
    /// twelve attachments is one message, not twelve.
    func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        lock.withLock { attachments.append(fileURL) }
        return nil
    }

    func finish(_ documents: [InvoiceDocument]) async throws -> String? {
        let files = lock.withLock { attachments }
        guard !files.isEmpty else { return nil }

        let subject = EmailMessage.subject(for: documents, entityName: entityName)
        let body = EmailMessage.body(for: documents)

        let opened = await MainActor.run { () -> Bool in
            guard let service = NSSharingService(named: .composeEmail) else { return false }
            service.recipients = recipients.isEmpty ? nil : recipients
            service.subject = subject
            // The body goes first so the message reads as a message rather than
            // as a pile of attachments with a stray sentence at the end.
            let items: [Any] = [body] + files
            guard service.canPerform(withItems: items) else { return false }
            service.perform(withItems: items)
            return true
        }

        guard opened else {
            throw IRError.export(t("No mail application is set up on this Mac, so there is nothing to open a message in."))
        }
        // Said plainly, because the documents are now marked as exported and
        // the message is still sitting unsent in a window.
        return t("%@ attached. Nothing has been sent: check the message and press Send in your mail application.",
                 tn("%d document", documents.count))
    }
}
