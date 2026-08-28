import Foundation

/// A plugin that talks to a supplier's API directly, with its own credentials,
/// and never opens a browser.
///
/// This is a different thing from an `apiRequest` step inside a browser plugin.
/// That one borrows the session the user established by signing in, so it still
/// needs a password and a two-factor dance. This one is the case where the
/// supplier issues API credentials: the user pastes keys once, and collection
/// afterwards needs no window, no password in the keychain, and no interaction
/// — which means it can also run unattended.
///
/// The hard part is that every API signs its requests differently, and the
/// obvious answer — let the plugin carry a snippet of code — would give up the
/// property the whole project rests on: a plugin is data, and a reviewer who is
/// not a programmer can read it. So authentication is declared as a *recipe*
/// from a closed vocabulary rather than written as an expression. It covers the
/// families that exist in practice: a static header, HTTP Basic, an OAuth2
/// client-credentials exchange, and a request signed by hashing an ordered list
/// of parts.
public struct APITransport: Codable, Sendable, Hashable {
    /// Prefixed to every relative URL in the plugin's steps, so the host
    /// appears once and `allowedDomains` has one obvious entry to cover.
    public var baseURL: String
    /// Sent on every request, before authentication headers.
    public var headers: [String: String]?
    public var auth: APIAuth?
    /// Where the user obtains the credentials. Shown verbatim when adding a
    /// source, because "create an application key" is useless without the URL.
    /// Prefer a link that pre-fills the supplier's form with exactly the rights
    /// the plugin needs: it removes the step users most often get wrong.
    public var credentialsURL: String?
    /// The one thing that is easy to get wrong on that page, in the plugin's
    /// own words. Suppliers differ — an expiry that silently stops collection,
    /// a scope that must be ticked — and the application cannot know which.
    public var credentialsHint: String?

    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case headers, auth
        case credentialsURL = "credentialsUrl"
        case credentialsHint = "credentialsHint"
    }

    public init(baseURL: String, headers: [String: String]? = nil,
                auth: APIAuth? = nil, credentialsURL: String? = nil,
                credentialsHint: String? = nil) {
        self.baseURL = baseURL
        self.headers = headers
        self.auth = auth
        self.credentialsURL = credentialsURL
        self.credentialsHint = credentialsHint
    }
}

public struct APIAuth: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Everything is already in `headers` — an API key, a bearer token.
        case header
        /// HTTP Basic. `username` and `password` are templates.
        case basic
        /// Exchange a client id and secret for a token, then send it.
        case oauth2ClientCredentials
        /// Hash an ordered list of parts into a header. OVHcloud, and most
        /// APIs that predate OAuth2, work this way.
        case signature
    }

    public var type: Kind
    /// Added to every request. Values are templates, so `{{secret.appKey}}`.
    public var headers: [String: String]?
    public var username: String?
    public var password: String?
    public var token: APITokenEndpoint?
    /// Some signature schemes are checked against the *server's* clock, so a
    /// user whose machine is a minute off would be rejected.
    public var time: APITimeSource?
    public var signature: APISignature?

    public init(type: Kind) { self.type = type }
}

/// An OAuth2 client-credentials exchange, which is the only OAuth2 flow that
/// needs no browser and therefore the only one that belongs here.
public struct APITokenEndpoint: Codable, Sendable, Hashable {
    public var url: String
    public var clientID: String
    public var clientSecret: String
    public var scope: String?
    /// Extra form fields, for APIs that want more than the standard three.
    public var parameters: [String: String]?
    /// Where the answer keeps the token. Defaults to `access_token`.
    public var jsonPath: String?
    /// Defaults to `Authorization: Bearer <token>`.
    public var header: String?
    public var format: String?

    private enum CodingKeys: String, CodingKey {
        case url, clientID = "clientId", clientSecret, scope, parameters
        case jsonPath, header, format
    }

    public init(url: String, clientID: String, clientSecret: String) {
        self.url = url; self.clientID = clientID; self.clientSecret = clientSecret
    }
}

/// Fetches the API's own idea of the current time, for signatures that include
/// a timestamp. Read once per run; later requests add the elapsed time rather
/// than asking again.
public struct APITimeSource: Codable, Sendable, Hashable {
    public enum Format: String, Codable, Sendable { case text, json }
    public var url: String
    public var format: Format?
    public var jsonPath: String?

    public init(url: String, format: Format? = nil, jsonPath: String? = nil) {
        self.url = url; self.format = format; self.jsonPath = jsonPath
    }
}

/// A signature expressed as a recipe rather than as code.
///
/// `parts` are templates joined by `separator`, hashed with `algorithm`, and
/// written into `header` after `prefix`. Beyond the usual namespaces the parts
/// may use `{{request.method}}`, `{{request.url}}`, `{{request.body}}` and
/// `{{api.time}}`, which is everything a request-signing scheme has ever
/// needed and nothing that could reach further.
public struct APISignature: Codable, Sendable, Hashable {
    public enum Algorithm: String, Codable, Sendable, CaseIterable {
        case sha1, sha256, sha512
        case hmacSha1, hmacSha256, hmacSha512

        public var isHMAC: Bool {
            switch self {
            case .hmacSha1, .hmacSha256, .hmacSha512: return true
            default: return false
            }
        }
    }
    public enum Encoding: String, Codable, Sendable { case hex, base64 }

    public var header: String
    public var algorithm: Algorithm
    public var parts: [String]
    public var separator: String?
    public var prefix: String?
    public var encoding: Encoding?
    /// The key, for the HMAC algorithms.
    public var key: String?

    public init(header: String, algorithm: Algorithm, parts: [String]) {
        self.header = header; self.algorithm = algorithm; self.parts = parts
    }
}
