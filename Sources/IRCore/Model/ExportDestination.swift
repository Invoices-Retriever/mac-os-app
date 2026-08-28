import Foundation

/// A destination the user has configured and kept.
///
/// The difference from an `Exporter` is deliberate: an exporter is a thing that
/// can move one document, built fresh for one run. This is the *saved* choice —
/// where invoices go, whether it happens on its own, and how it went last time.
/// Keeping them separate means the engine stays testable without a database and
/// the interface has something stable to draw a card from.
public struct ExportDestination: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var entityID: UUID
    public var kind: ExportDestinationKind
    public var name: String
    /// What this kind of destination needs: a folder path, a URL, recipients.
    /// Never a secret — those live in the keychain, keyed by this id.
    public var config: [String: String]
    /// Whether a collection that finds new invoices sends them here without
    /// being asked. Off when a destination is created: the first run should be
    /// one the user watches.
    public var runsAutomatically: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastSucceeded: Bool?
    public var lastDetail: String?
    public var documentsSent: Int

    public init(id: UUID = UUID(),
                entityID: UUID,
                kind: ExportDestinationKind,
                name: String,
                config: [String: String] = [:],
                runsAutomatically: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.entityID = entityID
        self.kind = kind
        self.name = name
        self.config = config
        self.runsAutomatically = runsAutomatically
        self.createdAt = createdAt
        self.documentsSent = 0
    }

    /// Keychain account for this destination's one secret, if its kind has one.
    public var secretAccount: String { "export.\(id.uuidString)" }

    /// Whether the kind keeps a secret at all. A folder does not; a webhook's
    /// bearer token and a Paperless API token do.
    public var needsSecret: Bool {
        switch kind {
        case .webhook, .paperless, .smtp: return true
        case .folder, .csv, .json, .email: return false
        }
    }

    /// Enough to run: said here rather than in the view, so the automatic
    /// runner and the interface cannot disagree about it.
    public func isComplete(hasSecret: Bool) -> Bool {
        switch kind {
        case .folder, .csv, .json:
            return !(config["path"] ?? "").isEmpty
        case .webhook:
            return URL(string: config["url"] ?? "")?.scheme?.hasPrefix("http") == true
        case .paperless:
            return URL(string: config["url"] ?? "")?.scheme?.hasPrefix("http") == true && hasSecret
        case .email:
            // A recipient can be filled in the mail window, so there is nothing
            // this destination cannot do without.
            return true
        case .smtp:
            // Nothing can be typed in later here: the message goes out on its
            // own, so everything it needs has to be present now.
            return !(config["host"] ?? "").isEmpty
                && !(config["username"] ?? "").isEmpty
                && !(config["recipients"] ?? "").isEmpty
                && hasSecret
        }
    }
}

public extension ExportDestinationKind {
    /// The one-line description shown on a card before it is connected.
    var explanation: String {
        switch self {
        case .folder:
            return core("Copies the PDFs into a folder, organised the way your library is. This is what you hand to your accountant.")
        case .csv:
            return core("One row per document, for reconciliation in a spreadsheet.")
        case .json:
            return core("The same register as JSON, for a script.")
        case .webhook:
            return core("Posts each document to a URL as multipart: the metadata as JSON, the PDF as a file.")
        case .email:
            return core("Opens a message with the invoices attached. Nothing is sent: you read it and press Send yourself.")
        case .smtp:
            return core("Sends one message with the invoices attached, through your own mail server. Runs on its own — this is how an accounting tool's intake address gets fed.")
        case .paperless:
            return core("Uploads each PDF into a Paperless-ngx instance, with its date and title already filled in.")
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .csv: return "tablecells.fill"
        case .json: return "curlybraces"
        case .webhook: return "bolt.horizontal.fill"
        case .email: return "envelope.fill"
        case .smtp: return "paperplane.fill"
        case .paperless: return "tray.full.fill"
        }
    }

    /// Whether this kind actually delivers, or only prepares something a
    /// person then has to send. The card must not say "sent" for a message
    /// still sitting unsent in a compose window.
    var deliversItself: Bool {
        switch self {
        case .email: return false
        default: return true
        }
    }

    /// Whether a destination of this kind can sensibly run on its own after a
    /// collection. E-mail cannot: it opens a window someone has to look at, and
    /// having that happen unattended at 3am is not a feature.
    var canRunAutomatically: Bool {
        switch self {
        case .email: return false
        default: return true
        }
    }
}
