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
            return core("Sign-in required: %@", s)
        case .authenticationFailed(let s):
            return core("Sign-in failed: %@", s)
        case .blockedByPortal(let s):
            return core("The portal blocked automated access: %@. Collect this source by hand.", s)
        case .domainNotAllowed(let host, let allowed):
            return core("Plugin tried to reach %1$@, which is not in allowedDomains (%2$@)",
                        host, allowed.joined(separator: ", "))
        case .stepTimedOut(let action, let ms):
            return core("Step '%1$@' timed out after %2$@ ms", action, String(ms))
        case .runBudgetExhausted(let seconds):
            return core("Run exceeded its %@ s budget", String(seconds))
        case .elementNotFound(let selector):
            return core("No element matched %@", selector)
        case .assertionFailed(let s):
            return core("Check failed: %@", s)
        case .invalidPlugin(let s):
            return core("Invalid plugin: %@", s)
        case .engineTooOld(let required, let current):
            return core("Plugin requires engine %1$@; this build implements %2$@", required, current)
        case .vault(let s):
            return core("Keychain: %@", s)
        case .storage(let s):
            return core("Storage: %@", s)
        case .export(let s):
            return core("Export: %@", s)
        case .cancelled:
            return core("Cancelled")
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
