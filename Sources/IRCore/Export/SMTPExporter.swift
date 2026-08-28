import Foundation

/// F8.4. Sends the invoices as one e-mail, through a mail server the user
/// configured.
///
/// The sibling of the compose-window export, and the one that can run
/// unattended: a scheduled collection can put the month's invoices in the
/// accountant's inbox — or in an accounting tool's intake address, which is how
/// most of them take supporting documents — without anybody being at the Mac.
///
/// It sends one message with every invoice attached rather than one message per
/// invoice, because that is what a person on the other end wants to receive.
public struct SMTPExporter: Exporter {
    public let settings: SMTPSettings
    public let recipients: [String]
    public let entityName: String?
    /// Injected so the conversation can be tested without a mail server.
    public let makeTransport: @Sendable (SMTPSettings) -> any SMTPTransport

    private let collected = Collected()

    public init(settings: SMTPSettings,
                recipients: [String],
                entityName: String? = nil,
                makeTransport: @escaping @Sendable (SMTPSettings) -> any SMTPTransport
                    = { NetworkSMTPTransport(settings: $0) }) {
        self.settings = settings
        self.recipients = recipients
        self.entityName = entityName
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
    public var displayName: String {
        recipients.isEmpty ? settings.host : recipients.joined(separator: ", ")
    }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        let name = (document.relativePath as NSString).lastPathComponent
        collected.add(name, try Data(contentsOf: fileURL))
        return nil
    }

    public func finish(_ documents: [InvoiceDocument]) async throws -> String? {
        let files = collected.take()
        guard !files.isEmpty else { return nil }
        guard !recipients.isEmpty else {
            throw IRError.export(core("This destination has no recipient to send to."))
        }

        let message = MIMEMessage(
            from: settings.from.isEmpty ? settings.username : settings.from,
            to: recipients,
            subject: EmailMessage.subject(for: documents, entityName: entityName),
            body: EmailMessage.body(for: documents),
            attachments: files.map { MIMEMessage.Attachment(filename: $0.0, data: $0.1) })

        try await SMTPMailer(settings: settings).send(message, over: makeTransport(settings))
        return core("Sent to %@", recipients.joined(separator: ", "))
    }
}
