import Foundation

/// F8.4. Sends the invoices as one e-mail, through a mail server the user
/// configured.
///
/// The sibling of the compose-window export, and the one that can run
/// unattended: a scheduled collection can put the month's invoices in the
/// accountant's inbox — or in an accounting tool's intake address, which is how
/// most of them take supporting documents — without anybody being at the Mac.
///
/// By default it sends **one message per invoice**, because that is what the
/// thing on the other end usually is: an accounting tool's intake address reads
/// a message as a single document, and twelve attachments in one message get
/// one of them filed and eleven ignored. It also makes a partial failure
/// recoverable — each invoice is recorded as sent on its own, so a server that
/// gives up halfway leaves the rest to be retried rather than the whole batch
/// marked as sent or the whole batch marked as failed.
///
/// A person reading them rather than a machine would rather have one message
/// with everything attached, so that remains a choice.
public struct SMTPExporter: Exporter {
    public let settings: SMTPSettings
    public let recipients: [String]
    public let entityName: String?
    /// One message per invoice, rather than one message carrying all of them.
    public let oneMessagePerInvoice: Bool
    /// Injected so the conversation can be tested without a mail server.
    public let makeTransport: @Sendable (SMTPSettings) -> any SMTPTransport

    private let collected = Collected()

    public init(settings: SMTPSettings,
                recipients: [String],
                entityName: String? = nil,
                oneMessagePerInvoice: Bool = true,
                makeTransport: @escaping @Sendable (SMTPSettings) -> any SMTPTransport
                    = { NetworkSMTPTransport(settings: $0) }) {
        self.settings = settings
        self.recipients = recipients
        self.entityName = entityName
        self.oneMessagePerInvoice = oneMessagePerInvoice
        self.makeTransport = makeTransport
    }

    /// Files gathered during a batch. A final class because `Exporter` is a
    /// value and the batch has to accumulate somewhere.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [(String, Data)] = []

        func add(_ name: String, _ data: Data) { lock.withLock { files.append((name, data)) } }
        func take() -> [(String, Data)] { lock.withLock { let out = files; files = []; return out } }
    }

    public var destinationID: String {
        "smtp:\(settings.host):\(recipients.sorted().joined(separator: ","))"
    }
    public var kind: ExportDestinationKind { .smtp }
    /// One message per invoice really does deliver in `export`, so each is
    /// recorded as it goes. Only the single-message mode waits for `finish`.
    public var deliversOnFinish: Bool { !oneMessagePerInvoice }
    public var displayName: String {
        recipients.isEmpty ? settings.host : recipients.joined(separator: ", ")
    }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        let name = (document.relativePath as NSString).lastPathComponent
        let data = try Data(contentsOf: fileURL)

        guard oneMessagePerInvoice else {
            collected.add(name, data)
            return nil
        }
        try requireRecipients()

        // A connection per message. For the dozen invoices a month a person
        // collects that is unremarkable — it is how every mail client behaves —
        // and it keeps each send independent, which is worth more here than
        // saving eleven handshakes.
        let message = MIMEMessage(
            from: sender,
            to: recipients,
            subject: EmailMessage.subject(for: document, entityName: entityName),
            body: EmailMessage.body(for: document),
            attachments: [MIMEMessage.Attachment(filename: name, data: data)])
        try await SMTPMailer(settings: settings).send(message, over: makeTransport(settings))
        return core("Sent to %@", recipients.joined(separator: ", "))
    }

    public func finish(_ documents: [InvoiceDocument]) async throws -> String? {
        let files = collected.take()
        guard !oneMessagePerInvoice else {
            return documents.isEmpty ? nil
                : coreCount("%d message sent", documents.count)
        }
        guard !files.isEmpty else { return nil }
        try requireRecipients()

        let message = MIMEMessage(
            from: sender,
            to: recipients,
            subject: EmailMessage.subject(for: documents, entityName: entityName),
            body: EmailMessage.body(for: documents),
            attachments: files.map { MIMEMessage.Attachment(filename: $0.0, data: $0.1) })

        try await SMTPMailer(settings: settings).send(message, over: makeTransport(settings))
        return core("Sent to %@", recipients.joined(separator: ", "))
    }

    private var sender: String {
        settings.from.nilIfEmpty ?? settings.username
    }

    private func requireRecipients() throws {
        guard recipients.isEmpty else { return }
        throw IRError.export(core("This destination has no recipient to send to."))
    }
}
