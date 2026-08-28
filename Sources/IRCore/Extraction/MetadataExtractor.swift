import Foundation
import PDFKit
import Vision

/// Fills in what the plugin did not declare.
///
/// The order is the one the specification insists on and it is not negotiable:
/// plugin-declared values first (F6.1), then the PDF's own text, then OCR, and
/// only then — if the user has explicitly turned it on — a language model.
/// Each level is less trustworthy than the one above, and the confidence score
/// carried on each field says so, which is what lets the library flag a
/// document as worth a glance instead of silently getting it wrong.
public struct MetadataExtractor: Sendable {
    public var enableOCR: Bool
    public var llm: (any LLMExtractor)?

    public init(enableOCR: Bool = true, llm: (any LLMExtractor)? = nil) {
        self.enableOCR = enableOCR
        self.llm = llm
    }

    public struct Result: Sendable {
        public var document: InvoiceDocument
        public var text: String?
        public var usedOCR: Bool = false
        public var usedLLM: Bool = false
    }

    public func enrich(_ document: InvoiceDocument, pdf data: Data) async -> Result {
        var document = document
        var result = Result(document: document)

        var text = Self.embeddedText(in: data)
        if (text?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) < 40, enableOCR {
            // A scanned invoice has no text layer worth the name. Vision keeps
            // this on-device, which is the only reason OCR is acceptable in a
            // product that promises nothing leaves the machine (F6.3).
            text = await Self.ocrText(in: data)
            result.usedOCR = text != nil
        }

        guard let text, !text.isEmpty else {
            result.document = document
            return result
        }
        result.text = text
        document.extractedText = String(text.prefix(200_000))

        let method: ExtractionMethod = result.usedOCR ? .ocr : .pdfText
        apply(text: text, to: &document, method: method)

        // F6.4: off unless the user turned it on, and it only ever sees what
        // the cheaper methods failed to read.
        if let llm, document.needsReview {
            if let inferred = try? await llm.extract(text: text, missing: Self.missingFields(document)) {
                merge(inferred, into: &document, method: .llm)
                result.usedLLM = true
            }
        }

        document.updatedAt = Date()
        result.document = document
        return result
    }

    // MARK: - Rules

    private func apply(text: String, to document: inout InvoiceDocument, method: ExtractionMethod) {
        let scale = method.baseConfidence

        if document.number == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.number, in: text) {
            document.number = hit.value
            document.fieldConfidence["number"] = hit.confidence * scale
        }

        if document.issuedOn == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.date, in: text),
           let parsed = InvoiceDateParser.parse(hit.value) {
            document.issuedOn = parsed
            document.fieldConfidence["issuedOn"] = hit.confidence * scale
        }

        if document.total == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.total, in: text),
           let money = MoneyParser.parse(hit.value) {
            document.total = money
            document.fieldConfidence["total"] = hit.confidence * scale
        }

        let currency = document.total?.currency
        if document.net == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.net, in: text),
           let money = MoneyParser.parse(hit.value, defaultCurrency: currency) {
            document.net = money
            document.fieldConfidence["net"] = hit.confidence * scale
        }

        if document.vat == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.vat, in: text),
           let money = MoneyParser.parse(hit.value, defaultCurrency: currency) {
            document.vat = money
            document.fieldConfidence["vat"] = hit.confidence * scale
        }

        if document.vatNumber == nil, let hit = InvoicePatterns.firstMatch(InvoicePatterns.vatNumber, in: text) {
            document.vatNumber = hit.value.replacingOccurrences(of: " ", with: "")
            document.fieldConfidence["vatNumber"] = hit.confidence * scale
        }

        // Arithmetic beats pattern matching: if two of the three amounts are
        // known, the third is not a guess.
        reconcileAmounts(&document)

        // A credit note read as an invoice puts the sign the wrong way round in
        // the user's books, so this check is worth doing even when the plugin
        // said nothing about it.
        let head = text.prefix(1200).lowercased()
        if document.kind == .invoice {
            if InvoicePatterns.creditNoteMarkers.contains(where: head.contains) {
                document.kind = .creditNote
                document.fieldConfidence["kind"] = 0.7 * scale
            } else if InvoicePatterns.receiptMarkers.contains(where: head.contains) {
                document.kind = .receipt
                document.fieldConfidence["kind"] = 0.6 * scale
            }
        }
        if document.kind == .creditNote, let total = document.total, total.cents > 0 {
            document.total = Money(cents: -total.cents, currency: total.currency)
        }
    }

    private func reconcileAmounts(_ document: inout InvoiceDocument) {
        let currency = document.total?.currency ?? document.net?.currency ?? "EUR"
        switch (document.total, document.net, document.vat) {
        case (let total?, let net?, nil):
            document.vat = Money(cents: total.cents - net.cents, currency: currency)
            document.fieldConfidence["vat"] = min(document.fieldConfidence["total"] ?? 0.5,
                                                  document.fieldConfidence["net"] ?? 0.5)
        case (let total?, nil, let vat?):
            document.net = Money(cents: total.cents - vat.cents, currency: currency)
            document.fieldConfidence["net"] = min(document.fieldConfidence["total"] ?? 0.5,
                                                  document.fieldConfidence["vat"] ?? 0.5)
        case (nil, let net?, let vat?):
            document.total = Money(cents: net.cents + vat.cents, currency: currency)
            document.fieldConfidence["total"] = min(document.fieldConfidence["net"] ?? 0.5,
                                                    document.fieldConfidence["vat"] ?? 0.5)
        case (let total?, let net?, let vat?):
            // All three present and inconsistent: something was misread, and
            // saying so is more useful than picking a winner.
            if abs(total.cents - net.cents - vat.cents) > 2 {
                for field in ["total", "net", "vat"] {
                    document.fieldConfidence[field] = min(document.fieldConfidence[field] ?? 0.5, 0.4)
                }
            }
        default:
            break
        }
    }

    private func merge(_ inferred: LLMExtraction, into document: inout InvoiceDocument, method: ExtractionMethod) {
        let scale = method.baseConfidence
        if document.number == nil, let value = inferred.number {
            document.number = value; document.fieldConfidence["number"] = scale
        }
        if document.issuer == nil, let value = inferred.issuer {
            document.issuer = value; document.fieldConfidence["issuer"] = scale
        }
        if document.issuedOn == nil, let value = inferred.issuedOn.flatMap(InvoiceDateParser.parse) {
            document.issuedOn = value; document.fieldConfidence["issuedOn"] = scale
        }
        if document.total == nil, let value = inferred.total.flatMap({ MoneyParser.parse($0, defaultCurrency: inferred.currency) }) {
            document.total = value; document.fieldConfidence["total"] = scale
        }
        if document.vat == nil, let value = inferred.vat.flatMap({ MoneyParser.parse($0, defaultCurrency: inferred.currency) }) {
            document.vat = value; document.fieldConfidence["vat"] = scale
        }
        reconcileAmounts(&document)
    }

    private static func missingFields(_ document: InvoiceDocument) -> [String] {
        var missing: [String] = []
        if document.number == nil { missing.append("number") }
        if document.issuedOn == nil { missing.append("date") }
        if document.total == nil { missing.append("total") }
        if document.issuer == nil { missing.append("issuer") }
        if document.vat == nil { missing.append("vat") }
        return missing
    }

    // MARK: - Text

    public static func embeddedText(in data: Data) -> String? {
        guard let pdf = PDFDocument(data: data) else { return nil }
        var out = ""
        // Four pages is enough: invoice headers and totals are at the front and
        // the back of the first page, and a 200-page usage report would cost
        // seconds for nothing.
        for index in 0..<min(pdf.pageCount, 4) {
            if let page = pdf.page(at: index), let text = page.string { out += text + "\n" }
        }
        return out.isEmpty ? nil : out
    }

    public static func ocrText(in data: Data) async -> String? {
        guard let pdf = PDFDocument(data: data) else { return nil }
        var out = ""
        for index in 0..<min(pdf.pageCount, 3) {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2× the page size: enough for Vision to read 8 pt legal text
            // without turning a scan into a 100 MB bitmap.
            let scale: CGFloat = 2
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard size.width > 1, size.height > 1,
                  let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }

            if let text = await recogniseText(in: image) { out += text + "\n" }
        }
        return out.isEmpty ? nil : out
    }

    private static func recogniseText(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["fr-FR", "en-US", "de-DE"]

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

/// F6.4. The protocol lives here but no implementation ships enabled: the
/// promise is that nothing leaves the machine unless the user says so, and a
/// default-on cloud call would break it. An implementation must show the user
/// exactly what it is about to send before it sends it.
public protocol LLMExtractor: Sendable {
    var providerDescription: String { get }
    var isLocal: Bool { get }
    func extract(text: String, missing: [String]) async throws -> LLMExtraction
}

public struct LLMExtraction: Sendable, Codable {
    public var issuer: String?
    public var number: String?
    public var issuedOn: String?
    public var total: String?
    public var net: String?
    public var vat: String?
    public var currency: String?

    public init() {}
}
