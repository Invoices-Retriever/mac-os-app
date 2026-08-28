import Foundation
import Network

/// The real socket, on Network.framework.
///
/// An actor because an SMTP conversation is strictly one exchange at a time and
/// a half-read reply interleaved with a write is not a failure anyone would
/// enjoy debugging.
public actor NetworkSMTPTransport: SMTPTransport {
    private let host: String
    private let port: Int
    private let security: SMTPSettings.Security
    private let timeout: Duration

    private var connection: NWConnection?
    /// Bytes read but not yet consumed: a reply can arrive split across packets
    /// or two replies can arrive in one.
    private var buffer = Data()

    public init(settings: SMTPSettings, timeout: Duration = .seconds(30)) {
        self.host = settings.host
        self.port = settings.port
        self.security = settings.security
        self.timeout = timeout
    }

    public func open() async throws {
        let parameters: NWParameters
        switch security {
        case .tls:
            parameters = .tls
        case .startTLS, .none:
            // Opened in clear; `startTLS` re-opens with TLS when the server
            // has agreed to it.
            parameters = .tcp
        }
        try await connect(with: parameters)
    }

    private func connect(with parameters: NWParameters) async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
            throw IRError.export(core("%@ is not a usable port number", String(self.port)))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection

        // A state handler can fire more than once — `.waiting` then `.ready`
        // on a slow network is normal — and resuming a continuation twice is a
        // crash, so the first outcome wins and the rest are ignored.
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        continuation.resume(throwing: IRError.export(
                            core("could not reach %1$@: %2$@", self.host, error.localizedDescription)))
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: IRError.export(
                            core("the connection to %@ was closed", self.host)))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Network.framework has no in-place TLS upgrade, so STARTTLS is done the
    /// way it is elsewhere on this platform: the negotiated session is dropped
    /// and a TLS connection is made to the same server. The server's STARTTLS
    /// acceptance still gates it, and everything secret happens afterwards.
    public func startTLS() async throws {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        try await connect(with: .tls)
        // The freshly encrypted connection greets us again.
        _ = try await read()
    }

    public func write(_ line: String) async throws {
        guard let connection else {
            throw IRError.export(core("the connection to %@ was closed", host))
        }
        let payload = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: IRError.export(
                        core("could not write to %1$@: %2$@", self.host, error.localizedDescription)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func read() async throws -> SMTPReply {
        let deadline = Date().addingTimeInterval(timeout.seconds)
        while true {
            if let reply = Self.takeReply(from: &buffer) { return reply }
            guard Date() < deadline else {
                throw IRError.export(core("%@ stopped answering", host))
            }
            buffer.append(try await receiveSome())
        }
    }

    private func receiveSome() async throws -> Data {
        guard let connection else {
            throw IRError.export(core("the connection to %@ was closed", host))
        }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: IRError.export(
                        core("could not read from %1$@: %2$@", self.host, error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: IRError.export(
                        core("%@ closed the connection", self.host)))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() async {
        connection?.cancel()
        connection = nil
    }

    /// Pulls one complete reply out of the buffer, or nil if it has not all
    /// arrived. A multi-line reply repeats the code with a hyphen — "250-SIZE"
    /// — and ends with a space: "250 HELP".
    public static func takeReply(from buffer: inout Data) -> SMTPReply? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        var lines: [String] = []
        var consumed = 0

        for rawLine in text.components(separatedBy: "\r\n") {
            // The last element is whatever follows the final CRLF: incomplete.
            guard rawLine.count >= 4 else { break }
            consumed += rawLine.utf8.count + 2
            let code = Int(rawLine.prefix(3)) ?? 0
            let separator = rawLine[rawLine.index(rawLine.startIndex, offsetBy: 3)]
            lines.append(String(rawLine.dropFirst(4)))
            if separator == " " {
                buffer.removeFirst(min(consumed, buffer.count))
                return SMTPReply(code: code, lines: lines)
            }
        }
        return nil
    }
}


/// One-shot latch for callbacks that may fire more than once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
