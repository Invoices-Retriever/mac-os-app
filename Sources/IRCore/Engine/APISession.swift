import Foundation
import CryptoKit

/// Runs a plugin that has no browser at all.
///
/// It satisfies `BrowserSession` so the step executor stays one piece of code
/// rather than two, but every browser-shaped method refuses: an API plugin has
/// no page to click, and saying so plainly beats pretending. The validator
/// rejects those steps before a plugin ever ships, so this is a backstop and
/// not the first line of defence.
///
/// What it does have is a real HTTP client — deliberately, and in contrast to
/// `apiRequest` inside a browser plugin, which goes through the page precisely
/// so it inherits the user's session. Here there is no session to inherit: the
/// credentials are the user's own API keys. Not having a browser is the point.
/// It is also the safer half of the two: no cookies, no JavaScript, no window,
/// and the same `allowedDomains` sandbox applied to every single request.
public final class APISession: BrowserSession, @unchecked Sendable {
    public let sourceID: UUID

    private let transport: APITransport
    private let policy: DomainPolicy
    private let logger: RedactingLogger
    private let urlSession: URLSession
    /// Resolves `{{…}}` against the run's configuration and secrets.
    private let resolve: @Sendable (String) throws -> String

    private let lock = NSLock()
    private var cachedToken: String?
    /// The API's clock minus ours, measured once.
    private var timeOffset: TimeInterval?

    public init(sourceID: UUID,
                transport: APITransport,
                policy: DomainPolicy,
                resolve: @escaping @Sendable (String) throws -> String,
                logger: RedactingLogger = .shared) {
        self.sourceID = sourceID
        self.transport = transport
        self.policy = policy
        self.resolve = resolve
        self.logger = logger

        // Ephemeral on purpose: an API plugin has no session to keep, so there
        // is nothing to leave on disk between runs.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Requests

    public func requestJSON(url: URL, method: String, headers: [String: String],
                            body: String?, timeout: Duration) async throws -> APIResponse {
        let (data, status) = try await send(url: url, method: method,
                                            headers: headers, body: body, timeout: timeout)
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return APIResponse(status: status, json: .null,
                               text: String(data: data, encoding: .utf8))
        }
        return APIResponse(status: status, json: JSONValue(any: any))
    }

    public func download(from url: URL, timeout: Duration) async throws -> Data {
        // A PDF link is very often on a storage host rather than the API's, so
        // it goes through the same policy check as everything else and the
        // plugin has to declare that host too.
        let (data, status) = try await send(url: url, method: "GET",
                                            headers: [:], body: nil, timeout: timeout,
                                            authenticated: false)
        guard (200..<300).contains(status) else {
            throw IRError.assertionFailed(core("%1$@ answered %2$@: %3$@",
                                               url.host ?? url.absoluteString, String(status), ""))
        }
        return data
    }

    /// The one place a request is actually made, so the sandbox check and the
    /// authentication cannot be bypassed by adding a caller.
    private func send(url: URL, method: String, headers: [String: String],
                      body: String?, timeout: Duration,
                      authenticated: Bool = true) async throws -> (Data, Int) {
        guard policy.allows(url: url) else {
            throw IRError.domainNotAllowed(host: url.host ?? url.absoluteString, allowed: policy.patterns)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout.seconds
        for (name, value) in transport.headers ?? [:] {
            request.setValue(try resolve(value), forHTTPHeaderField: name)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        if authenticated, let auth = transport.auth {
            try await authenticate(&request, with: auth, method: method, url: url, body: body ?? "")
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.debug("\(method) \(url.path) → \(status)")
        return (data, status)
    }

    // MARK: - Authentication

    private func authenticate(_ request: inout URLRequest, with auth: APIAuth,
                              method: String, url: URL, body: String) async throws {
        // Read before the headers, not inside the signature branch: a scheme
        // like OVHcloud's puts the timestamp in a header of its own as well as
        // in the signature, and those headers are resolved here.
        let time = try await apiTime(auth.time)
        for (name, value) in try authHeaders(auth, method: method, url: url, body: body, time: time) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if auth.type == .oauth2ClientCredentials {
            guard let endpoint = auth.token else {
                throw IRError.invalidPlugin(core("the plugin declares OAuth2 but no token endpoint"))
            }
            let token = try await accessToken(endpoint)
            let format = endpoint.format ?? "Bearer %@"
            request.setValue(String(format: format, token),
                             forHTTPHeaderField: endpoint.header ?? "Authorization")
        }
    }

    /// Every header authentication contributes, as a value rather than a side
    /// effect — so it can be tested without a server.
    ///
    /// The declared headers are resolved with the *request's* scope, because
    /// that is where `{{api.time}}` and `{{request.…}}` mean anything. Resolving
    /// them against the run's context alone throws "unknown variable", and that
    /// failure surfaces as "the API refused these credentials", which sends the
    /// user to check keys that were never the problem.
    public func authHeaders(_ auth: APIAuth, method: String, url: URL,
                            body: String, time: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in auth.headers ?? [:] {
            out[name] = try resolveRequestTemplate(value, method: method, url: url,
                                                   body: body, time: time)
        }

        switch auth.type {
        case .header, .oauth2ClientCredentials:
            break

        case .basic:
            let user = try resolve(auth.username ?? "")
            let password = try resolve(auth.password ?? "")
            out["Authorization"] = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()

        case .signature:
            guard let recipe = auth.signature else {
                throw IRError.invalidPlugin(core("the plugin declares a signed API but no signature"))
            }
            out[recipe.header] = try sign(recipe, method: method, url: url, body: body, time: time)
        }
        return out
    }

    /// Fetched once and reused: the token is valid for a while, and asking for
    /// a new one per request would be both slow and rude to the supplier.
    private func accessToken(_ endpoint: APITokenEndpoint) async throws -> String {
        if let cachedToken = lock.withLock({ cachedToken }) { return cachedToken }

        guard let url = URL(string: try resolve(endpoint.url)) else {
            throw IRError.assertionFailed("'\(endpoint.url)' is not a URL")
        }
        var fields = [
            "grant_type": "client_credentials",
            "client_id": try resolve(endpoint.clientID),
            "client_secret": try resolve(endpoint.clientSecret),
        ]
        if let scope = endpoint.scope { fields["scope"] = try resolve(scope) }
        for (key, value) in endpoint.parameters ?? [:] { fields[key] = try resolve(value) }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let form = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")

        let (data, status) = try await send(
            url: url, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: form, timeout: .seconds(30), authenticated: false)

        guard (200..<300).contains(status) else {
            throw IRError.authenticationFailed(core(
                "the API refused these credentials (%@)", String(status)))
        }
        let json = JSONValue(any: (try? JSONSerialization.jsonObject(with: data)) ?? [:])
        guard let token = json.value(atPath: endpoint.jsonPath ?? "access_token")?.stringValue,
              !token.isEmpty else {
            throw IRError.authenticationFailed(core("the API returned no access token"))
        }
        logger.registerSecret(token)
        lock.withLock { cachedToken = token }
        return token
    }

    /// The API's clock. Measured once; afterwards our own clock advances it, so
    /// a long run does not spend a request per signature.
    private func apiTime(_ source: APITimeSource?) async throws -> String {
        guard let source else { return String(Int(Date().timeIntervalSince1970)) }

        let known = lock.withLock { timeOffset }
        if let known {
            return String(Int(Date().timeIntervalSince1970 + known))
        }

        guard let url = URL(string: try resolve(source.url)) else {
            throw IRError.assertionFailed("'\(source.url)' is not a URL")
        }
        let (data, status) = try await send(url: url, method: "GET", headers: [:],
                                            body: nil, timeout: .seconds(15),
                                            authenticated: false)
        guard (200..<300).contains(status) else {
            throw IRError.assertionFailed(core("%1$@ answered %2$@: %3$@",
                                               url.host ?? "", String(status), ""))
        }
        let raw: String?
        switch source.format ?? .text {
        case .text:
            raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .json:
            let json = JSONValue(any: (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:])
            raw = (source.jsonPath.flatMap { json.value(atPath: $0) } ?? json).stringValue
        }
        guard let raw, let seconds = TimeInterval(raw) else {
            throw IRError.assertionFailed(core("the API did not return a usable time"))
        }
        lock.withLock { timeOffset = seconds - Date().timeIntervalSince1970 }
        return String(Int(seconds))
    }

    public func sign(_ recipe: APISignature, method: String, url: URL,
              body: String, time: String) throws -> String {
        let joined = try recipe.parts
            .map { try resolveRequestTemplate($0, method: method, url: url, body: body, time: time) }
            .joined(separator: recipe.separator ?? "+")

        let digest: Data
        if recipe.algorithm.isHMAC {
            let key = SymmetricKey(data: Data(try resolve(recipe.key ?? "").utf8))
            switch recipe.algorithm {
            case .hmacSha1:
                digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(joined.utf8), using: key))
            case .hmacSha256:
                digest = Data(HMAC<SHA256>.authenticationCode(for: Data(joined.utf8), using: key))
            default:
                digest = Data(HMAC<SHA512>.authenticationCode(for: Data(joined.utf8), using: key))
            }
        } else {
            let input = Data(joined.utf8)
            switch recipe.algorithm {
            case .sha1:   digest = Data(Insecure.SHA1.hash(data: input))
            case .sha256: digest = Data(SHA256.hash(data: input))
            default:      digest = Data(SHA512.hash(data: input))
            }
        }

        let encoded: String
        switch recipe.encoding ?? .hex {
        case .hex:    encoded = digest.map { String(format: "%02x", $0) }.joined()
        case .base64: encoded = digest.base64EncodedString()
        }
        return (recipe.prefix ?? "") + encoded
    }

    /// The request's own values are substituted here rather than in the run's
    /// context: they differ per request, and a shared context would be a race.
    private func resolveRequestTemplate(_ template: String, method: String,
                                        url: URL, body: String, time: String) throws -> String {
        var out = template
        for (token, value) in [
            "{{request.method}}": method,
            "{{request.url}}": url.absoluteString,
            "{{request.body}}": body,
            "{{api.time}}": time,
        ] {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return try resolve(out)
    }

    // MARK: - Not a browser

    private func noBrowser(_ what: String) -> IRError {
        .assertionFailed(core("'%@' needs a browser, and this plugin talks to an API", what))
    }

    public func currentURL() async -> URL? { URL(string: transport.baseURL) }
    public func pageTitle() async -> String? { nil }
    public func navigate(to url: URL) async throws { throw noBrowser("navigate") }
    public func waitForNavigation(timeout: Duration) async throws { throw noBrowser("waitForNavigation") }
    public func waitForNetworkIdle(idle: Duration, timeout: Duration) async throws {}
    public func evaluate(_ javascript: String) async throws -> JSONValue { throw noBrowser("runJs") }
    public func setVisible(_ visible: Bool) async {}
    public func waitForUserSignIn(until: Date, isSignedIn: @Sendable () async -> Bool) async -> Bool {
        // There is nothing for the user to do in a window that does not exist;
        // either the keys work or they do not.
        await isSignedIn()
    }
    public func awaitPendingDownload(timeout: Duration) async throws -> Data { throw noBrowser("waitForPdfDownload") }
    public func printToPDF() async throws -> Data { throw noBrowser("printPdf") }
    public func captureScreenshot() async throws -> Data { throw noBrowser("captureScreenshot") }
    public func captureDOMOutline() async throws -> String {
        core("this plugin talks to an API; there is no page to describe")
    }
    public func drainNetworkResponses() async -> [ObservedResponse] { [] }
    public func clearSession() async throws {
        lock.withLock { cachedToken = nil; timeOffset = nil }
    }
    public func close() async {}
}
