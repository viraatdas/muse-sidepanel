import AppKit
import WebKit

/// Owns the web view that hosts muse.ai. The view is created on first use and can be
/// dropped again while the panel is hidden, which releases the whole web content process.
final class WebController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let home = URL(string: "https://muse.ai/")!

    private(set) var webView: WKWebView?
    private var loadingObservation: NSKeyValueObservation?

    var onLoadingChanged: ((Bool) -> Void)?
    /// Called with true/false around dialogs that take key focus away from the panel.
    var onModal: ((Bool) -> Void)?

    // MARK: Lifecycle

    func ensureLoaded(in container: NSView) {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Makes the user agent identical to Safari's, so the site serves its normal web app.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true

        let view = WKWebView(frame: container.bounds, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        // Let the panel material show through until the page paints, instead of a white flash.
        view.setValue(false, forKey: "drawsBackground")
        Self.disableOcclusionDetection(view)
        container.addSubview(view)
        webView = view

        loadingObservation = view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
            self?.onLoadingChanged?(view.isLoading)
        }
        view.load(URLRequest(url: Settings.lastURL ?? Self.home))
    }

    /// WebKit stops painting when macOS reports the window as occluded, which a transparent
    /// floating panel can be even while it is plainly on screen. Hiding the panel still
    /// pauses the page, because that takes the window off screen entirely.
    private static func disableOcclusionDetection(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
    }

    func unload() {
        guard let view = webView else { return }
        rememberLocation()
        loadingObservation = nil
        view.stopLoading()
        view.removeFromSuperview()
        webView = nil
        onLoadingChanged?(false)
    }

    func reload() {
        guard let view = webView else { return }
        if view.url == nil {
            view.load(URLRequest(url: Self.home))
        } else {
            view.reload()
        }
    }

    func rememberLocation() {
        guard let url = webView?.url, url.host == Self.home.host else { return }
        Settings.lastURL = url
    }

    var currentURL: URL {
        if let url = webView?.url, Self.isFirstParty(url) { return url }
        return Settings.lastURL ?? Self.home
    }

    // MARK: Swipe support

    /// Whether the element under `windowPoint` can still scroll horizontally in `direction`
    /// (-1 towards the start, 1 towards the end). Used so a swipe over a wide code block or
    /// table scrolls it instead of dismissing the panel.
    func canScrollHorizontally(at windowPoint: NSPoint, direction: Int, completion: @escaping (Bool) -> Void) {
        guard let view = webView else { return completion(false) }
        let point = view.convert(windowPoint, from: nil)
        guard view.bounds.contains(point) else { return completion(false) }
        let script = """
        (function (x, y, dir) {
          var e = document.elementFromPoint(x, y);
          while (e && e !== document.documentElement) {
            if (e.scrollWidth > e.clientWidth + 1) {
              var o = getComputedStyle(e).overflowX;
              if (o === 'auto' || o === 'scroll') {
                if (dir < 0 ? e.scrollLeft > 0 : e.scrollLeft + e.clientWidth < e.scrollWidth - 1) return true;
              }
            }
            e = e.parentElement;
          }
          return false;
        })(\(Int(point.x)), \(Int(point.y)), \(direction))
        """
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            completion(((try? result.get()) as? Bool) ?? false)
        }
    }

    // MARK: Navigation

    /// Hosts that stay inside the panel: the app itself and Meta's sign-in pages.
    static func isFirstParty(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["muse.ai", "meta.com", "meta.ai", "facebook.com", "instagram.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    private static func isWeb(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download)
        }
        if let scheme = url.scheme, ["mailto", "tel", "sms", "facetime"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        // Links the user clicks that lead off-site open in the default browser.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if navigationAction.navigationType == .linkActivated, isMainFrame, Self.isWeb(url), !Self.isFirstParty(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // There is only one view: first-party popups load in place, everything else goes to the browser.
        guard let url = navigationAction.request.url else { return nil }
        if Self.isFirstParty(url) {
            webView.load(navigationAction.request)
        } else if Self.isWeb(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        rememberLocation()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload once; a page that keeps crashing is left for the reload button rather than looped.
        let now = Date()
        defer { lastCrash = now }
        if let lastCrash, now.timeIntervalSince(lastCrash) < 10 { return }
        webView.reload()
    }

    private var lastCrash: Date?

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename as NSString
        var destination = folder.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let numbered = "\(name.deletingPathExtension) \(counter)"
            destination = folder.appendingPathComponent(
                name.pathExtension.isEmpty ? numbered : numbered + "." + name.pathExtension)
            counter += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }

    // MARK: Dialogs

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.canChooseDirectories = parameters.allowsDirectories
        openPanel.canChooseFiles = true
        onModal?(true)
        NSApp.activate(ignoringOtherApps: true)
        openPanel.begin { [weak self] response in
            completionHandler(response == .OK ? openPanel.urls : nil)
            self?.onModal?(false)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        runAlert(message, in: webView, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        runAlert(message, in: webView, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private func runAlert(_ message: String, in webView: WKWebView, buttons: [String],
                          completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else { return completion(.alertSecondButtonReturn) }
        let alert = NSAlert()
        alert.messageText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        onModal?(true)
        alert.beginSheetModal(for: window) { [weak self] response in
            completion(response)
            self?.onModal?(false)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // macOS still asks once for the app itself; this only skips WebKit's per-visit prompt for muse.ai.
        let host = origin.host.lowercased()
        let isMuse = host == "muse.ai" || host.hasSuffix(".muse.ai")
        decisionHandler(isMuse && type == .microphone ? .grant : .prompt)
    }
}
