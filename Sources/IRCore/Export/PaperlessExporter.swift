import Foundation

/// F8.3. Pushes each PDF into a Paperless-ngx instance.
///
/// Paperless is the document manager a lot of the people this application is
/// for already run, and it is the natural other half of the story: this
/// collects invoices from portals, Paperless files and searches them. It takes
/// a plain multipart POST with a token, so it needs no library and no OAuth
/// dance — the same shape as the webhook exporter, with the field names
/// Paperless expects.
///
/// The endpoint answers with a task identifier rather than a document: the
/// import is queued and consumed asynchronously. That is worth knowing when
/// reading the export log, so the identifier is what gets recorded.
public struct PaperlessExporter: Exporter {
    public let baseURL: URL
    public let token: String
    /// Applied to every document, for people who keep collected invoices in
    /// their own tag rather than the inbox.
    public let tagIDs: [Int]
    public let sourceNames: [UUID: String]
    private let session: URLSession

    public init(baseURL: URL,
                token: String,
                tagIDs: [Int] = [],
                sourceNames: [UUID: String] = [:],
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.tagIDs = tagIDs
        self.sourceNames = sourceNames
        self.session = session
    }

    public var destinationID: String { "paperless:\(baseURL.absoluteString)" }
    public var kind: ExportDestinationKind { .paperless }
    public var displayName: String { "Paperless \(baseURL.host ?? baseURL.absoluteString)" }

    /// `/api/documents/post_document/`, whatever path the instance is served
    /// under — a Paperless behind a reverse proxy at /paperless is common.
    public var endpoint: URL {
        var path = baseURL.path
        while path.hasSuffix("/") { path.removeLast() }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path + "/api/documents/post_document/"
        components?.query = nil
        return components?.url ?? baseURL.appendingPathComponent("api/documents/post_document/")
    }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        let filename = (document.relativePath as NSString).lastPathComponent
        let boundary = "ir-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        // Paperless derives a title from the filename otherwise, which for our
        // naming pattern is readable but noisy. Give it the fields we already
        // know rather than making it guess them again.
        if let issuer = document.issuer, let number = document.number {
            field("title", "\(issuer) \(number)")
        } else if let issuer = document.issuer {
            field("title", issuer)
        }
        if let issuedOn = document.issuedOn {
            field("created", InvoiceDateParser.isoString(issuedOn))
        }
        for tag in tagIDs { field("tags", String(tag)) }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"document\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/pdf\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw IRError.export(core("no HTTP response from %@", baseURL.host ?? "Paperless"))
        }
        // 403 with a token nearly always means the token is right but the user
        // it belongs to cannot add documents; saying "check the token" would
        // send someone to re-copy a token that is fine.
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
            throw IRError.export(core("Paperless answered %1$@: %2$@",
                                      String(http.statusCode), detail))
        }
        // The body is a quoted task UUID.
        return String(decoding: data.prefix(120), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n "))
    }
}
