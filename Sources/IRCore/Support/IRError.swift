import Foundation

/// Failures the engine distinguishes, because the retry policy depends on the
/// kind: an authentication failure must never be retried automatically (F2.9),
/// while a timeout usually deserves one more attempt.
public enum IRError: Error, LocalizedError, Sendable {
    case authenticationRequired(String)
    case authenticationFailed(String)
    case blockedByPortal(String)
    case domainNotAllowed(host: String, allowed: [String])
    case stepTimedOut(action: String, milliseconds: Int)
    case runBudgetExhausted(seconds: Int)
    case elementNotFound(selector: String)
    case assertionFailed(String)
    case invalidPlugin(String)
    case engineTooOld(required: String, current: String)
    case vault(String)
    case storage(String)
    case export(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let s):
            return "Sign-in required: \(s)"
        case .authenticationFailed(let s):
            return "Sign-in failed: \(s)"
        case .blockedByPortal(let s):
            return "The portal blocked automated access: \(s). Collect this source by hand."
        case .domainNotAllowed(let host, let allowed):
            return "Plugin tried to reach \(host), which is not in allowedDomains (\(allowed.joined(separator: ", ")))"
        case .stepTimedOut(let action, let ms):
            return "Step '\(action)' timed out after \(ms) ms"
        case .runBudgetExhausted(let seconds):
            return "Run exceeded its \(seconds) s budget"
        case .elementNotFound(let selector):
            return "No element matched \(selector)"
        case .assertionFailed(let s):
            return "Check failed: \(s)"
        case .invalidPlugin(let s):
            return "Invalid plugin: \(s)"
        case .engineTooOld(let required, let current):
            return "Plugin requires engine \(required); this build implements \(current)"
        case .vault(let s):
            return "Keychain: \(s)"
        case .storage(let s):
            return "Storage: \(s)"
        case .export(let s):
            return "Export: \(s)"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// F2.9: two attempts with exponential backoff, but never on an auth failure —
    /// retrying a bad password is how accounts get locked.
    public var isRetryable: Bool {
        switch self {
        case .stepTimedOut, .elementNotFound, .storage:
            return true
        case .authenticationRequired, .authenticationFailed, .blockedByPortal,
             .domainNotAllowed, .assertionFailed, .invalidPlugin, .engineTooOld,
             .vault, .export, .cancelled, .runBudgetExhausted:
            return false
        }
    }

    /// Whether the UI should offer "sign in again" rather than "retry".
    public var needsUserSignIn: Bool {
        switch self {
        case .authenticationRequired, .authenticationFailed: return true
        default: return false
        }
    }
}
