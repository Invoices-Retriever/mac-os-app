import Foundation
import WebKit
import AppKit
import IRCore

/// The WebKit implementation of `BrowserSession`.
///
/// Two things here carry the project's security promise, and both are worth
/// reading carefully before changing anything.
///
/// First, isolation: each source gets its own `WKWebsiteDataStore`, keyed by
/// the source's UUID. Two AWS accounts never see each other's cookies, and
/// "forget this session" is a real operation rather than a best effort (F2.2).
///
/// Second, the sandbox: `allowedDomains` is compiled into a `WKContentRuleList`
/// that blocks *everything* by default and un-blocks the declared domains. That
/// covers subresources — fetch, XHR, images, beacons — not just top-level
/// navigation, which is the only version of this control that actually stops a
/// malicious plugin from posting the user's session somewhere (M1). The
/// navigation delegate then refuses out-of-policy navigations a second time, so
/// that the user gets a comprehensible error rather than a blank page.
@MainActor
public final class WebKitBrowserSession: NSObject, BrowserSession {
    public nonisolated let sourceID: UUID

    private let webView: WKWebView
    private let policy: DomainPolicy
    private let window: NSWindow
    private let logger: RedactingLogger

    private var navigationContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isLoading = false
    private var lastActivityAt = Date()
    private var observedResponses: [ObservedResponse] = []
    private var downloads = DownloadCoordinator()
    private var blockedHost: String?

    init(sourceID: UUID, policy: DomainPolicy, title: String,
         logger: RedactingLogger = .shared) async throws {
        self.sourceID = sourceID
        self.policy = policy
        self.logger = logger

        let configuration = WKWebViewConfiguration()

        // One persistent profile per source. `forIdentifier:` needs a UUID and
        // gives us a store WebKit manages on disk for us — cookies, local
        // storage and IndexedDB all survive a relaunch, which is what stops the
        // app asking for a 2FA code every single month.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: sourceID)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        let controller = WKUserContentController()
        configuration.userContentController = controller

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                 configuration: configuration)
        // A real, current user agent. Not a disguise: this *is* a WebKit
        // browser driven by its owner. §8.4 forbids faking a fingerprint to
        // defeat bot detection, and nothing here does that.
        self.webView.customUserAgent = nil
        self.webView.allowsBackForwardNavigationGestures = false

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        self.window.title = "Invoices Retriever — \(title)"
        self.window.contentView = webView
        self.window.isReleasedWhenClosed = false

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        controller.add(NetworkObserver(session: self), name: "irNetwork")
        controller.addUserScript(WKUserScript(source: Self.networkObserverScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        try await installContentRules(controller: controller)
    }

    private func installContentRules(controller: WKUserContentController) async throws {
        let json = policy.contentRuleListJSON()
        // The identifier is derived from the rules, so a plugin that changes
        // its allowedDomains gets a fresh compiled list rather than a stale one.
        let identifier = "ir-policy-\(abs(json.hashValue))"
        do {
            let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            if let list { controller.add(list) }
        } catch {
            // Failing open here would silently remove the sandbox, so refuse to
            // create the session at all.
            throw IRError.invalidPlugin("could not apply the domain sandbox: \(error.localizedDescription)")
        }
    }

    // MARK: - State

    public func currentURL() async -> URL? { webView.url }
    public func pageTitle() async -> String? { webView.title }

    public func setVisible(_ visible: Bool) async {
        if visible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderOut(nil)
        }
    }

    public func close() async {
        navigationContinuations.values.forEach { $0.resume(throwing: CancellationError()) }
        navigationContinuations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "irNetwork")
        window.orderOut(nil)
        window.contentView = nil
    }

    public func clearSession() async throws {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    // MARK: - Navigation

    public func navigate(to url: URL) async throws {
        guard policy.allows(url: url) else {
            throw IRError.domainNotAllowed(host: url.host ?? url.absoluteString, allowed: policy.patterns)
        }
        blockedHost = nil
        isLoading = true
        lastActivityAt = Date()
        webView.load(URLRequest(url: url))
        try await waitForNavigation(timeout: .seconds(45))
    }

    /// Waits for a navigation to finish — including one that has not started
    /// yet.
    ///
    /// A click that submits a form does not begin loading in the same turn of
    /// the run loop, so checking `isLoading` immediately after it is always
    /// false and this returned at once. Every plugin using the standard login
    /// shape — type, click, waitForNavigation — then evaluated its next step
    /// against the page it had just left. On OVHcloud that meant testing for
    /// the two-factor field while still looking at the login form, concluding
    /// there was none, and handing over a second before the prompt appeared.
    ///
    /// So: give a click a moment to turn into a navigation, and only conclude
    /// that nothing is happening once that moment has passed. A step that waits
    /// for a navigation which never comes returns quietly rather than failing,
    /// because plugins put it after clicks that may or may not navigate.
    public func waitForNavigation(timeout: Duration) async throws {
        let grace = Date().addingTimeInterval(min(1.5, timeout.seconds))
        while !isLoading && !webView.isLoading && Date() < grace {
            try await Task.sleep(for: .milliseconds(50))
        }
        if !isLoading && !webView.isLoading { return }

        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOutNavigation(id: id, after: timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            navigationContinuations[id] = continuation
        }
    }

    private func timeOutNavigation(id: UUID, after timeout: Duration) {
        guard let continuation = navigationContinuations.removeValue(forKey: id) else { return }
        continuation.resume(throwing: IRError.stepTimedOut(
            action: "waitForNavigation", milliseconds: Int(timeout.seconds * 1000)))
    }

    /// "Network idle" is approximated from the last time an observed request
    /// completed. It is not precise, and it does not need to be: it exists so a
    /// plugin can say "wait for the table to finish populating" without
    /// guessing at a sleep duration.
    public func waitForNetworkIdle(idle: Duration, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(timeout.seconds)
        while Date() < deadline {
            let quiet = Date().timeIntervalSince(lastActivityAt) >= idle.seconds
            if quiet && !webView.isLoading {
                let state = try? await webView.evaluateJavaScript(DOMScriptsBridge.readyState)
                if (state as? String) == "complete" { return }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw IRError.stepTimedOut(action: "waitForNetworkIdle",
                                   milliseconds: Int(timeout.seconds * 1000))
    }

    /// Waits for the person to finish signing in, without touching the page
    /// they are signing in on.
    ///
    /// The obvious implementation — poll `isSignedIn` every couple of seconds —
    /// is unusable, and it took someone trying it to see why: `checkAuth`
    /// begins by navigating, so polling it reloads the login form out from
    /// under the user every two seconds. The window flickers and no password
    /// can ever be typed.
    ///
    /// So the loop watches the URL instead, which costs nothing and changes
    /// nothing, and only pays for the real check once the page has settled
    /// somewhere other than where the sign-in started. A slow periodic check
    /// remains as a backstop for a portal that signs you in without changing
    /// the address.
    public func waitForUserSignIn(until deadline: Date,
                                  isSignedIn: @Sendable () async -> Bool) async -> Bool {
        await setVisible(true)

        /// Origin and path only: a login page rewrites its query string
        /// constantly, and that is not the user going anywhere.
        func landmark(_ url: URL?) -> String {
            guard let url else { return "" }
            return (url.host ?? "") + url.path
        }

        let origin = landmark(webView.url)
        var settledSince: Date?
        var lastLandmark = origin
        var lastFullCheck = Date()

        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(700))

            let now = landmark(webView.url)
            if now != lastLandmark {
                lastLandmark = now
                settledSince = Date()
                continue
            }

            // Somewhere new, and it stopped moving: worth asking properly.
            let arrivedSomewhereNew = now != origin
                && (settledSince.map { Date().timeIntervalSince($0) > 1.5 } ?? false)
                && !webView.isLoading

            // The backstop exists for a portal that signs you in without
            // changing the address, and it must stay rare and never fire while
            // the person is still on the page they started on: the check
            // navigates, and navigating away from a half-filled login form is
            // the bug this whole method exists to avoid. Three minutes, and
            // only once they have moved.
            let overdue = now != origin && Date().timeIntervalSince(lastFullCheck) > 180

            guard arrivedSomewhereNew || overdue else { continue }

            lastFullCheck = Date()
            settledSince = nil
            if await isSignedIn() { return true }

            // The check navigated; treat wherever it left us as the new origin
            // so the next change is measured from here.
            lastLandmark = landmark(webView.url)
        }
        return false
    }

    // MARK: - Scripting

    public func evaluate(_ javascript: String) async throws -> JSONValue {
        do {
            let result = try await webView.evaluateJavaScript(javascript)
            return JSONValue(any: result)
        } catch let error as NSError {
            // WKWebView reports "no result" as an error for statements that
            // return undefined, which is a perfectly normal outcome.
            if error.domain == WKErrorDomain,
               error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                return .null
            }
            throw IRError.assertionFailed("JavaScript failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Documents

    public func download(from url: URL, timeout: Duration) async throws -> Data {
        guard policy.allows(url: url) else {
            throw IRError.domainNotAllowed(host: url.host ?? url.absoluteString, allowed: policy.patterns)
        }
        let pending = downloads.expect()
        webView.startDownload(using: URLRequest(url: url)) { download in
            download.delegate = self
        }
        return try await downloads.wait(for: pending, timeout: timeout)
    }

    public func awaitPendingDownload(timeout: Duration) async throws -> Data {
        let pending = downloads.expect()
        return try await downloads.wait(for: pending, timeout: timeout)
    }

    public func printToPDF() async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.allowTransparentBackground = false
        do {
            return try await webView.pdf(configuration: configuration)
        } catch {
            throw IRError.export("could not render the page to PDF: \(error.localizedDescription)")
        }
    }

    public func captureScreenshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw IRError.storage("could not encode the screenshot")
        }
        return png
    }

    public func captureDOMOutline() async throws -> String {
        let value = try await evaluate(DOMScriptsBridge.outline)
        return value.stringValue ?? ""
    }

    public func drainNetworkResponses() async -> [ObservedResponse] {
        let responses = observedResponses
        observedResponses.removeAll()
        return responses
    }

    fileprivate func record(_ response: ObservedResponse) {
        lastActivityAt = Date()
        // Bounded: a single-page app can fire hundreds of requests, and holding
        // every body would balloon memory on a long run.
        if observedResponses.count > 60 { observedResponses.removeFirst(30) }
        observedResponses.append(response)
    }

    private func finishNavigation(_ error: (any Error)?) {
        isLoading = false
        lastActivityAt = Date()
        let continuations = navigationContinuations.values
        navigationContinuations.removeAll()
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    /// Injected before any page script runs. It observes this session's own
    /// traffic so `extractNetworkResponse` can read a JSON API the page already
    /// called — cheaper and far more robust than scraping a rendered table.
    private static let networkObserverScript = """
    (function() {
      const post = (url, status, body) => {
        try {
          window.webkit.messageHandlers.irNetwork.postMessage({
            url: String(url), status: status, body: typeof body === 'string' ? body.slice(0, 400000) : null
          });
        } catch (e) { /* handler gone; nothing to do */ }
      };
      const nativeFetch = window.fetch;
      if (nativeFetch) {
        window.fetch = function(...args) {
          return nativeFetch.apply(this, args).then((response) => {
            const type = response.headers.get('content-type') || '';
            if (type.includes('json') || type.includes('text')) {
              response.clone().text().then((t) => post(response.url, response.status, t)).catch(() => {});
            } else {
              post(response.url, response.status, null);
            }
            return response;
          });
        };
      }
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.__irURL = url;
        return open.call(this, method, url, ...rest);
      };
      XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', () => {
          let body = null;
          try { if (this.responseType === '' || this.responseType === 'text') body = this.responseText; } catch (e) {}
          post(this.__irURL || this.responseURL, this.status, body);
        });
        return send.apply(this, args);
      };
    })();
    """
}

// MARK: - Navigation delegate

extension WebKitBrowserSession: WKNavigationDelegate {

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        guard policy.allows(url: url) else {
            // The content rule list has almost certainly stopped this already;
            // this branch exists so the failure has a name.
            blockedHost = url.host
            logger.warning("blocked navigation to \(url.host ?? url.absoluteString): outside allowedDomains",
                           source: sourceID)
            decisionHandler(.cancel)
            return
        }
        lastActivityAt = Date()
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // A PDF the portal serves as an attachment arrives here rather than as
        // a click-triggered download; route it to the download machinery so
        // `waitForPdfDownload` sees it.
        if let mime = navigationResponse.response.mimeType, mime == "application/pdf",
           !navigationResponse.canShowMIMEType || downloads.hasPendingExpectation {
            decisionHandler(.download)
            return
        }
        if let http = navigationResponse.response as? HTTPURLResponse, let url = http.url {
            record(ObservedResponse(url: url, statusCode: http.statusCode,
                                    mimeType: http.mimeType, body: nil))
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(translate(error))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        finishNavigation(translate(error))
    }

    private func translate(_ error: any Error) -> any Error {
        let nsError = error as NSError
        // A cancelled load is what the domain policy produces, and also what a
        // page does to itself when it redirects mid-flight. Only the former is
        // an error worth reporting.
        if nsError.code == NSURLErrorCancelled {
            if let host = blockedHost {
                blockedHost = nil
                return IRError.domainNotAllowed(host: host, allowed: policy.patterns)
            }
            return CancellationError()
        }
        return error
    }
}

// MARK: - UI delegate

extension WebKitBrowserSession: WKUIDelegate {
    /// Portals open invoices in a new tab constantly. There are no tabs here,
    /// so load it in place instead of dropping it on the floor.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, policy.allows(url: url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        // Never block the run on a modal the user cannot see during a hidden
        // collection.
        logger.debug("page alert: \(message)", source: sourceID)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        logger.debug("page confirm: \(message)", source: sourceID)
        return true
    }
}

// MARK: - Downloads

extension WebKitBrowserSession: WKDownloadDelegate {

    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        guard let url = response.url, policy.allows(url: url) else {
            download.cancel(nil)
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoices-retriever", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(suggestedFilename)")
        downloads.note(download: download, destination: destination)
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        downloads.finish(download: download, error: nil)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error,
                         resumeData: Data?) {
        downloads.finish(download: download, error: error)
    }
}

// MARK: - Helpers

/// Bridges script-message callbacks back to the session without making the
/// session itself the handler, which would create a retain cycle through
/// `WKUserContentController`.
private final class NetworkObserver: NSObject, WKScriptMessageHandler {
    private weak var session: WebKitBrowserSession?

    init(session: WebKitBrowserSession) {
        self.session = session
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let urlString = payload["url"] as? String,
              let url = URL(string: urlString) else { return }
        let status = (payload["status"] as? Int) ?? 0
        let body = (payload["body"] as? String).map { Data($0.utf8) }
        MainActor.assumeIsolated {
            session?.record(ObservedResponse(url: url, statusCode: status, mimeType: nil, body: body))
        }
    }
}

/// Tracks in-flight downloads and hands their bytes back to whoever asked.
@MainActor
private final class DownloadCoordinator {
    private var expectations: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<Data, any Error>] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var completed: [Data] = []

    var hasPendingExpectation: Bool { !expectations.isEmpty }

    func expect() -> UUID {
        let id = UUID()
        expectations.append(id)
        return id
    }

    func note(download: WKDownload, destination: URL) {
        destinations[ObjectIdentifier(download)] = destination
    }

    func wait(for id: UUID, timeout: Duration) async throws -> Data {
        // A download that finished before anyone asked — a click that
        // immediately produced a file — is served from the buffer.
        if !completed.isEmpty {
            expectations.removeAll { $0 == id }
            return completed.removeFirst()
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOut(id: id, after: timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    private func timeOut(id: UUID, after timeout: Duration) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        expectations.removeAll { $0 == id }
        continuation.resume(throwing: IRError.stepTimedOut(
            action: "download", milliseconds: Int(timeout.seconds * 1000)))
    }

    func finish(download: WKDownload, error: (any Error)?) {
        let key = ObjectIdentifier(download)
        let destination = destinations.removeValue(forKey: key)

        guard error == nil, let destination, let data = try? Data(contentsOf: destination) else {
            deliver(.failure(error ?? IRError.export("the download did not produce a file")))
            return
        }
        try? FileManager.default.removeItem(at: destination)
        deliver(.success(data))
    }

    private func deliver(_ result: Result<Data, any Error>) {
        guard let id = expectations.first, let continuation = continuations.removeValue(forKey: id) else {
            // Nobody is waiting yet; hold the bytes for the step that will ask.
            if case .success(let data) = result {
                if completed.count > 4 { completed.removeFirst() }
                completed.append(data)
            }
            return
        }
        expectations.removeFirst()
        continuation.resume(with: result)
    }
}

enum DOMScriptsBridge {
    static let readyState = "(function(){ return document.readyState; })()"
    static let outline = DOMOutlineScript.source
}
