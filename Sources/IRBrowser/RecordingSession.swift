import Foundation
import WebKit
import AppKit
import IRCore

/// A browser window the user drives themselves, while the app writes down what
/// they do.
///
/// **There is no domain sandbox here, and that is the one thing to understand
/// about this type.** The sandbox exists to stop a *plugin* going somewhere the
/// user never agreed to; during a recording there is no plugin, only a person
/// browsing their own supplier with their own hands. Constraining it would also
/// be circular — the whole point is to find out which domains the plugin will
/// need, and it learns that from where the user actually goes.
///
/// The consequences are worth stating plainly, because they are why this is a
/// separate type rather than a mode of `WebKitBrowserSession`:
///
/// - The recording profile is its own `WKWebsiteDataStore`, separate from every
///   source's. Signing in here does not create a session any plugin can later
///   use, and it does not touch one.
/// - Nothing typed is recorded. The observer reports which field was used and
///   what it was labelled; the value never leaves the page. A recorded password
///   would end up in a JSON file destined for a pull request.
/// - The generated plugin's `allowedDomains` is exactly the set of hosts the
///   recording touched, which is narrower than anyone writes by hand — and from
///   the moment it is generated, the plugin runs under the sandbox like any
///   other.
@MainActor
public final class RecordingSession: NSObject {

    private let webView: WKWebView
    private let window: NSWindow
    private let recorder: PluginRecorder
    private let logger: RedactingLogger

    public init(recorder: PluginRecorder, logger: RedactingLogger = .shared) {
        self.recorder = recorder
        self.logger = logger

        let configuration = WKWebViewConfiguration()
        // A profile of its own: a recording must not borrow, or disturb, the
        // session a real source depends on.
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)

        let controller = WKUserContentController()
        configuration.userContentController = controller
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                 configuration: configuration)

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Invoices Retriever — recording"
        window.contentView = webView
        window.isReleasedWhenClosed = false

        super.init()

        controller.add(RecorderBridge(session: self), name: "irRecorder")
        controller.addUserScript(WKUserScript(source: RecorderScriptSource.observer,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        webView.navigationDelegate = self
    }

    public func start(at url: URL) {
        webView.load(URLRequest(url: url))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func stop() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "irRecorder")
        window.orderOut(nil)
        window.contentView = nil
    }

    public func currentURL() -> URL? { webView.url }

    /// Runs the analyser on whatever the user is looking at now.
    public func analyseCurrentPage() async throws -> PluginRecorder.PageAnalysis {
        let result = try await webView.evaluateJavaScript(RecorderScriptSource.analysis)
        let json = JSONValue(any: result)
        let data = try JSONEncoder().encode(json)
        let analysis = try JSONDecoder().decode(PluginRecorder.PageAnalysis.self, from: data)
        await recorder.setAnalysis(analysis)
        return analysis
    }

    fileprivate func received(_ payload: [String: Any]) {
        guard let kindText = payload["kind"] as? String,
              let kind = PluginRecorder.Event.Kind(rawValue: kindText),
              let url = payload["url"] as? String else { return }

        var event = PluginRecorder.Event(kind: kind, url: url)
        event.selector = payload["selector"] as? String
        event.label = payload["label"] as? String
        event.fieldType = payload["fieldType"] as? String

        let recorder = self.recorder
        Task { await recorder.record(event) }
    }
}

extension RecordingSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let recorder = self.recorder
        // A redirect chain ends here, which is the address a plugin should use.
        Task { await recorder.record(.init(kind: .navigate, url: url.absoluteString)) }
    }
}

/// Keeps the message handler from retaining the session.
private final class RecorderBridge: NSObject, WKScriptMessageHandler {
    private weak var session: RecordingSession?

    init(session: RecordingSession) { self.session = session }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { session?.received(payload) }
    }
}
