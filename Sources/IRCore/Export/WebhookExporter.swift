import Foundation

/// F8.2. Posts each document to a URL the user configured, as multipart with
/// the metadata as a JSON part and the PDF as a file part.
///
/// This is the escape hatch that keeps the project out of the business of
/// writing connectors for every accounting package (R6): anything that can
/// receive an HTTP POST can be integrated without a line of code here.
public struct WebhookExporter: Exporter {
    public let url: URL
    public let headers: [String: String]
    public let includeFile: Bool
    public let sourceNames: [UUID: String]
    private let session: URLSession

    public init(url: URL,
                headers: [String: String] = [:],
                includeFile: Bool = true,
                sourceNames: [UUID: String] = [:],
                session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.includeFile = includeFile
        self.sourceNames = sourceNames
        self.session = session
    }

    public var destinationID: String { "webhook:\(url.absoluteString)" }
    public var kind: ExportDestinationKind { .webhook }
    public var displayName: String { "Webhook \(url.host ?? url.absoluteString)" }

    /// The documented payload. Kept flat and boring on purpose: whoever is on
    /// the receiving end is probably writing five lines in a low-code tool.
    struct Payload: Encodable {
        var id: String
        var issuer: String?
        var number: String?
        var date: String?
        var total: String?
        var net: String?
        var vat: String?
        var currency: String?
        var vatNumber: String?
        var kind: String
        var source: String?
        var origin: String
        var filename: String
        var sha256: String
        var verifiedByHuman: Bool
        var confidence: Double
    }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        func amount(_ money: Money?) -> String? {
            guard let money else { return nil }
            let sign = money.cents < 0 ? "-" : ""
            let value = abs(money.cents)
            return String(format: "%@%d.%02d", sign, value / 100, value % 100)
        }

        let payload = Payload(
            id: document.id.uuidString,
            issuer: document.issuer,
            number: document.number,
            date: document.issuedOn.map(InvoiceDateParser.isoString),
            total: amount(document.total),
            net: amount(document.net),
            vat: amount(document.vat),
            currency: document.total?.currency,
            vatNumber: document.vatNumber,
            kind: document.kind.rawValue,
            source: document.sourceID.flatMap { sourceNames[$0] },
            origin: document.origin.rawValue,
            filename: (document.relativePath as NSString).lastPathComponent,
            sha256: document.sha256,
            verifiedByHuman: document.verifiedByHuman,
            confidence: document.lowestConfidence)

        let boundary = "ir-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(try JSONEncoder().encode(payload))
        append("\r\n")

        if includeFile {
            let fileData = try Data(contentsOf: fileURL)
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"file\"; filename=\"\(payload.filename)\"\r\n")
            append("Content-Type: application/pdf\r\n\r\n")
            body.append(fileData)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 60

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw IRError.export("no HTTP response from \(url.host ?? "the webhook")")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw IRError.export("the webhook answered \(http.statusCode): \(detail)")
        }
        return "HTTP \(http.statusCode)"
    }
}
