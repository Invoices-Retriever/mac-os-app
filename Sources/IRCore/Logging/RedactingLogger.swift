import Foundation
import os

/// Threat M3: a secret that reaches a log file, a failure screenshot or an
/// anomaly report has leaked, and log files get pasted into GitHub issues.
///
/// Redaction happens here, on the way out, once — not at each call site, where
/// somebody would eventually forget. Every value the vault hands to the engine
/// is registered with the logger before it is used, and any occurrence of it in
/// any message is replaced before the message is written anywhere.
public final class RedactingLogger: @unchecked Sendable {
    public static let shared = RedactingLogger()

    private let lock = NSLock()
    private var secrets: Set<String> = []
    private var sinks: [@Sendable (LogRecord) -> Void] = []
    private let osLog = Logger(subsystem: "app.invoicesretriever", category: "engine")

    public enum Level: String, Codable, Sendable, CaseIterable {
        case debug, info, warning, error
    }

    public struct LogRecord: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var timestamp: Date
        public var level: Level
        public var message: String
        public var sourceID: UUID?
        public var runID: UUID?
        public var step: String?
    }

    private init() {}

    /// Registers a value that must never appear in output. Short values are
    /// ignored: redacting every occurrence of a two-character password would
    /// mangle the log into uselessness and tell an attacker where it appeared.
    public func registerSecret(_ value: String) {
        guard value.count >= 4 else { return }
        lock.lock(); defer { lock.unlock() }
        secrets.insert(value)
        // A URL-encoded or JSON-escaped secret is still the secret.
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != value {
            secrets.insert(encoded)
        }
    }

    public func forgetSecrets() {
        lock.lock(); defer { lock.unlock() }
        secrets.removeAll()
    }

    public func addSink(_ sink: @escaping @Sendable (LogRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        sinks.append(sink)
    }

    public func redact(_ text: String) -> String {
        lock.lock()
        let current = secrets
        lock.unlock()
        var out = text
        // Longest first, so that a secret containing another is fully masked.
        for secret in current.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "«redacted»")
        }
        return out
    }

    public func log(_ level: Level, _ message: String,
                    source: UUID? = nil, run: UUID? = nil, step: String? = nil) {
        let record = LogRecord(timestamp: Date(), level: level,
                               message: redact(message),
                               sourceID: source, runID: run, step: step)
        lock.lock()
        let current = sinks
        lock.unlock()
        for sink in current { sink(record) }

        switch level {
        case .debug:   osLog.debug("\(record.message, privacy: .public)")
        case .info:    osLog.info("\(record.message, privacy: .public)")
        case .warning: osLog.warning("\(record.message, privacy: .public)")
        case .error:   osLog.error("\(record.message, privacy: .public)")
        }
    }

    public func debug(_ m: String, source: UUID? = nil, run: UUID? = nil, step: String? = nil) {
        log(.debug, m, source: source, run: run, step: step)
    }
    public func info(_ m: String, source: UUID? = nil, run: UUID? = nil, step: String? = nil) {
        log(.info, m, source: source, run: run, step: step)
    }
    public func warning(_ m: String, source: UUID? = nil, run: UUID? = nil, step: String? = nil) {
        log(.warning, m, source: source, run: run, step: step)
    }
    public func error(_ m: String, source: UUID? = nil, run: UUID? = nil, step: String? = nil) {
        log(.error, m, source: source, run: run, step: step)
    }
}
