import Foundation

/// The network sandbox described in §5.4.1 of the specification.
///
/// This type answers one question — may this plugin reach this URL? — and it is
/// the only place that question is answered. The driver enforces the verdict;
/// the plugin never sees it and cannot influence it. Without this, a community
/// plugin could navigate anywhere carrying the user's live session cookies,
/// which is threat M1 and the worst thing that could happen to this project.
public struct DomainPolicy: Sendable, Equatable {
    public let patterns: [String]

    public init(allowedDomains: [String]) {
        self.patterns = allowedDomains.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
    }

    /// A policy that permits nothing. Used as the default so that a code path
    /// which forgets to install a policy fails closed.
    public static let denyAll = DomainPolicy(allowedDomains: [])

    public func allows(url: URL) -> Bool {
        // Schemes that never touch the network are always fine; they are how
        // the driver injects its own bootstrap and how PDFs come back.
        if let scheme = url.scheme?.lowercased(), ["about", "data", "blob", "javascript"].contains(scheme) {
            return true
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return allows(host: host)
    }

    public func allows(host rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        guard !host.isEmpty else { return false }

        for pattern in patterns {
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(2))
                // "*.ovh.com" covers any subdomain but, deliberately, not the
                // apex: a plugin that needs both must list both. Being explicit
                // here is cheap and makes review meaningful.
                if host.hasSuffix("." + suffix) { return true }
            } else if host == pattern {
                return true
            }
        }
        return false
    }

    /// Content-blocker rules handed to WebKit so that subresources — XHR,
    /// images, scripts, beacons — are blocked too, not only top-level
    /// navigations. Cancelling navigations alone would leave a plugin free to
    /// POST cookies to an attacker with a single fetch().
    public func contentRuleListJSON() -> String {
        var rules: [[String: Any]] = [[
            "trigger": ["url-filter": ".*"],
            "action": ["type": "block"],
        ]]
        for pattern in patterns {
            let bare = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            let escaped = NSRegularExpression.escapedPattern(for: bare)
            // Matches https://host/... and https://any.sub.host/... for a
            // wildcard entry; only the exact host otherwise.
            let filter = pattern.hasPrefix("*.")
                ? "^https?://([^/]+\\.)?\(escaped)([:/]|$)"
                : "^https?://\(escaped)([:/]|$)"
            rules.append([
                "trigger": ["url-filter": filter],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    /// Every domain a set of steps will navigate to, so the app and the CI can
    /// verify up front that the manifest declares them (CI check 4, §9.3).
    public static func staticallyReferencedHosts(in steps: [PluginStep]) -> Set<String> {
        var hosts: Set<String> = []
        func walk(_ steps: [PluginStep]) {
            for step in steps {
                for candidate in step.staticURLTemplates {
                    // Templated URLs ({{config.region}}.example.com) cannot be
                    // resolved statically; the runtime check still catches them.
                    guard !candidate.contains("{{"), let url = URL(string: candidate), let host = url.host else { continue }
                    hosts.insert(host.lowercased())
                }
                walk(step.nestedSteps)
            }
        }
        walk(steps)
        return hosts
    }
}
