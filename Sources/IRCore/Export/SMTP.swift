import Foundation

/// How to reach a mail server.
public struct SMTPSettings: Sendable, Hashable {
    public enum Security: String, Sendable, Codable, CaseIterable {
        /// Port 465: the connection is encrypted from the first byte.
        case tls
        /// Port 587: plain connection, then STARTTLS before anything secret.
        case startTLS
        /// Only for a server on this machine. Never for one across a network:
        /// the password goes over the wire in base64, which is not encryption.
        case none
    }

    public var host: String
    public var port: Int
    public var security: Security
    public var username: String
    public var password: String
    public var from: String

    public init(host: String, port: Int, security: Security,
                username: String, password: String, from: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
        self.from = from
    }

    /// What a given security choice normally listens on, so the interface can
    /// fill the port in rather than making the user look it up.
    public static func defaultPort(for security: Security) -> Int {
        switch security {
        case .tls: return 465
        case .startTLS: return 587
        case .none: return 25
        }
    }
}

/// One line of an SMTP reply.
public struct SMTPReply: Sendable, Hashable {
    public var code: Int
    public var lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    public var isPositive: Bool { (200..<400).contains(code) }
    public var text: String { lines.joined(separator: " ") }
}

/// The wire, separated from the conversation.
///
/// This exists so the protocol below can be tested exhaustively — every branch,
/// every failure, every server that answers something unexpected — without a
/// mail server, a network, or a password. The real one is `NetworkSMTPTransport`;
/// the test one is a script.
public protocol SMTPTransport: Sendable {
    func open() async throws
    func write(_ line: String) async throws
    func read() async throws -> SMTPReply
    func startTLS() async throws
    func close() async
}

/// Speaks SMTP.
///
/// Written out rather than taken from a package, for the same reason as the
/// MIME builder: this application ships no third-party code, and the protocol
/// is small. What it is careful about is the order — a password must never be
/// sent before the connection is encrypted, and that is checked here rather
/// than left to the server to enforce.
public struct SMTPMailer: Sendable {
    public let settings: SMTPSettings
    private let logger: RedactingLogger

    public init(settings: SMTPSettings, logger: RedactingLogger = .shared) {
        self.settings = settings
        self.logger = logger
        // Registered before it can be used, so a password cannot appear in a
        // log line written between here and the AUTH command.
        if !settings.password.isEmpty { logger.registerSecret(settings.password) }
    }

    public func send(_ message: MIMEMessage, over transport: any SMTPTransport) async throws {
        try await transport.open()
        defer { Task { await transport.close() } }

        try await expect(transport.read(), 220, step: "greeting")

        var capabilities = try await ehlo(transport)

        if settings.security == .startTLS {
            guard capabilities.contains("STARTTLS") else {
                throw IRError.export(core("%@ does not offer STARTTLS, so the password would travel in clear. Refusing.",
                                          settings.host))
            }
            try await transport.write("STARTTLS")
            try await expect(transport.read(), 220, step: "STARTTLS")
            try await transport.startTLS()
            // The server's capabilities are re-read after the upgrade: what it
            // advertises in clear and what it advertises encrypted differ, and
            // AUTH is usually only in the second list.
            capabilities = try await ehlo(transport)
        }

        if !settings.username.isEmpty {
            guard settings.security != .none || settings.host == "localhost" else {
                throw IRError.export(core("Refusing to send a password over an unencrypted connection to %@.",
                                          settings.host))
            }
            try await authenticate(transport, capabilities: capabilities)
        }

        try await transport.write("MAIL FROM:<\(Self.addressOnly(message.from))>")
        try await expect(transport.read(), 250, step: "MAIL FROM")

        for recipient in message.to {
            try await transport.write("RCPT TO:<\(Self.addressOnly(recipient))>")
            let reply = try await transport.read()
            guard reply.isPositive else {
                throw IRError.export(core("%1$@ refused the recipient %2$@: %3$@",
                                          settings.host, recipient, reply.text))
            }
        }

        try await transport.write("DATA")
        try await expect(transport.read(), 354, step: "DATA")
        try await transport.write(message.dataPayload().trimmingSuffixCRLF())
        try await expect(transport.read(), 250, step: "message body")

        try await transport.write("QUIT")
        _ = try? await transport.read()
    }

    // MARK: - Steps

    private func ehlo(_ transport: any SMTPTransport) async throws -> Set<String> {
        try await transport.write("EHLO \(Self.clientName)")
        let reply = try await transport.read()
        guard reply.isPositive else {
            // A server that rejects EHLO may still speak the older HELO, which
            // is enough for a plain unauthenticated relay.
            try await transport.write("HELO \(Self.clientName)")
            try await expect(transport.read(), 250, step: "HELO")
            return []
        }
        return Set(reply.lines.map {
            $0.uppercased().trimmingCharacters(in: .whitespaces)
        })
    }

    private func authenticate(_ transport: any SMTPTransport, capabilities: Set<String>) async throws {
        let mechanisms = capabilities.first { $0.hasPrefix("AUTH") }?
            .split(separator: " ").map(String.init) ?? []

        if mechanisms.contains("PLAIN") || mechanisms.isEmpty {
            // \0user\0password, base64. The empty first field is the authorising
            // identity, which is the same as the user for every server we care
            // about.
            var payload = Data([0])
            payload.append(Data(settings.username.utf8))
            payload.append(0)
            payload.append(Data(settings.password.utf8))
            try await transport.write("AUTH PLAIN \(payload.base64EncodedString())")
            try await expectAuth(transport.read())
        } else if mechanisms.contains("LOGIN") {
            try await transport.write("AUTH LOGIN")
            try await expect(transport.read(), 334, step: "AUTH LOGIN")
            try await transport.write(Data(settings.username.utf8).base64EncodedString())
            try await expect(transport.read(), 334, step: "user name")
            try await transport.write(Data(settings.password.utf8).base64EncodedString())
            try await expectAuth(transport.read())
        } else {
            throw IRError.export(core("%1$@ offers no authentication this application can use (%2$@).",
                                      settings.host, mechanisms.joined(separator: " ")))
        }
    }

    private func expectAuth(_ reply: SMTPReply) throws {
        guard reply.code == 235 else {
            // The distinction matters: a wrong password is the user's to fix,
            // where a 4xx is the server having a bad day.
            if reply.code == 535 {
                throw IRError.authenticationFailed(
                    core("%1$@ rejected this user name and password: %2$@", settings.host, reply.text))
            }
            throw IRError.export(core("%1$@ refused the sign-in: %2$@", settings.host, reply.text))
        }
    }

    private func expect(_ reply: SMTPReply, _ code: Int, step: String) throws {
        guard reply.code == code else {
            throw IRError.export(core("%1$@ answered %2$@ at '%3$@': %4$@",
                                      settings.host, String(reply.code), step, reply.text))
        }
    }

    /// The name given in EHLO. Not the machine's host name: that would put the
    /// user's computer name into the headers of every message they send.
    static let clientName = "invoicesretriever.app"

    /// `Name <a@b>` → `a@b`, which is what the envelope commands take.
    public static func addressOnly(_ value: String) -> String {
        guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"),
              open < close else {
            return value.trimmingCharacters(in: .whitespaces)
        }
        return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    /// DATA's terminator is written by the transport as its own line, so the
    /// payload must not carry a second one.
    func trimmingSuffixCRLF() -> String {
        hasSuffix("\r\n") ? String(dropLast(2)) : self
    }
}
