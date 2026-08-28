import Foundation
import IRCore

/// A `BrowserSession` backed by a scripted set of pages.
///
/// This is what makes the step executor testable without WebKit, without a
/// network and without a supplier account — which in turn is what lets the
/// engine's semantics be pinned down by tests rather than by whichever portal
/// happened to be open when someone last changed it.
final class FakeBrowserSession: BrowserSession, @unchecked Sendable {
    struct Page {
        var elements: [String: String] = [:]      // selector -> text
        var attributes: [String: [String: String]] = [:]  // selector -> attribute -> value
        var rows: [[String: String]] = []          // for extractAll
        var title: String = ""
    }

    let sourceID = UUID()
    var pages: [String: Page]
    var currentURLValue: URL?
    var downloads: [String: Data] = [:]
    var pendingDownload: Data?
    var responses: [ObservedResponse] = []
    var visible = false
    var navigationLog: [String] = []
    var signInAfterChecks = 0
    private var signInChecks = 0

    init(pages: [String: Page], start: String? = nil) {
        self.pages = pages
        self.currentURLValue = start.flatMap(URL.init(string:))
    }

    private var page: Page { currentURLValue.flatMap { pages[$0.absoluteString] } ?? Page() }

    func currentURL() async -> URL? { currentURLValue }
    func pageTitle() async -> String? { page.title }

    func navigate(to url: URL) async throws {
        navigationLog.append(url.absoluteString)
        guard pages[url.absoluteString] != nil else {
            throw IRError.assertionFailed("the fake browser has no page for \(url)")
        }
        currentURLValue = url
    }

    func waitForNavigation(timeout: Duration) async throws {}
    func waitForNetworkIdle(idle: Duration, timeout: Duration) async throws {}

    /// Recognises the shapes `DOMScripts` produces. Crude on purpose: the point
    /// is to exercise the executor's logic, not to reimplement a DOM.
    func evaluate(_ javascript: String) async throws -> JSONValue {
        let page = self.page

        if javascript.contains("return window.location.href") {
            return .string(currentURLValue?.absoluteString ?? "")
        }
        if javascript.contains("return document.title") { return .string(page.title) }

        if let selector = Self.quoted(after: "__find(", in: javascript), javascript.contains("!== null") {
            return .bool(page.elements[selector] != nil || page.attributes[selector] != nil)
        }
        if javascript.contains("const rows = __findAll(") {
            return .array(page.rows.map { row in
                .object(row.mapValues { JSONValue.string($0) })
            })
        }
        if javascript.contains("__read(el,") {
            guard let selector = Self.quoted(after: "__find(", in: javascript) else { return .null }
            if let attribute = Self.readAttribute(javascript) {
                guard let value = page.attributes[selector]?[attribute] else { return .null }
                return .string(value)
            }
            guard let value = page.elements[selector] else { return .null }
            return .string(value)
        }
        if javascript.contains("el.click()") {
            guard let selector = Self.quoted(after: "__find(", in: javascript),
                  page.elements[selector] != nil || page.attributes[selector] != nil else {
                return .object(["ok": .bool(false), "reason": .string("not-found")])
            }
            return .object(["ok": .bool(true)])
        }
        if javascript.contains("setter.set.call") || javascript.contains("el.options") {
            return .object(["ok": .bool(true)])
        }
        return .null
    }

    private static func quoted(after marker: String, in script: String) -> String? {
        guard let range = script.range(of: marker) else { return nil }
        let rest = script[range.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest[rest.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: "\"") else { return nil }
        return String(afterOpen[..<close])
    }

    private static func readAttribute(_ script: String) -> String? {
        guard let range = script.range(of: "__read(el, ") else { return nil }
        let rest = script[range.upperBound...]
        guard rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(rest[rest.index(after: rest.startIndex)..<close])
    }

    func setVisible(_ visible: Bool) async { self.visible = visible }

    /// Calls the predicate, so a test sees whether the runner asked the
    /// destructive question — which is the thing worth asserting about.
    func waitForUserSignIn(until: Date, isSignedIn: @Sendable () async -> Bool) async -> Bool {
        signInChecks += 1
        if signInChecks >= signInAfterChecks { return true }
        return await isSignedIn()
    }

    func download(from url: URL, timeout: Duration) async throws -> Data {
        guard let data = downloads[url.absoluteString] else {
            throw IRError.stepTimedOut(action: "download", milliseconds: 1000)
        }
        return data
    }

    func awaitPendingDownload(timeout: Duration) async throws -> Data {
        guard let data = pendingDownload else {
            throw IRError.stepTimedOut(action: "download", milliseconds: 1000)
        }
        return data
    }

    func printToPDF() async throws -> Data { Data("%PDF-1.4 printed".utf8) }
    func captureScreenshot() async throws -> Data { Data("PNG".utf8) }

    func captureDOMOutline() async throws -> String {
        let page = self.page
        let names = Set(page.elements.keys).union(page.attributes.keys).sorted()
        return names.map { "element " + $0 }.joined(separator: "\n")
    }

    func drainNetworkResponses() async -> [ObservedResponse] {
        let out = responses
        responses.removeAll()
        return out
    }

    func clearSession() async throws {}
    func close() async {}
}

struct FakeSessionFactory: BrowserSessionFactory {
    let session: FakeBrowserSession
    func makeSession(sourceID: UUID, policy: DomainPolicy) async throws -> any BrowserSession { session }
}
