import AppKit
import Combine
import os
import WebKit

/// A single browser tab: owns one `WKWebView`, mirrors its state into published properties, and
/// reports navigation results back to the `BrowserManager` that created it.
///
/// Everything WebKit exposes is observed with KVO and the navigation/UI delegates — there is no
/// polling and no timer.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published private(set) var title: String = "New Tab"
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// Human-readable reason for the last failed navigation; cleared when a new one starts.
    @Published private(set) var lastErrorDescription: String?

    /// Called when a page finishes loading so the manager can record a history entry.
    var onVisit: (@MainActor (URL, String) -> Void)?
    /// Called when the page asks for a new window (`target="_blank"`, `window.open`).
    var onOpenNewTab: (@MainActor (URL) -> Void)?
    /// Called whenever the mirrored state changes so the manager can refresh its address text.
    var onStateChange: (@MainActor (BrowserTab) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsAirPlayForMediaPlayback = true
        // JavaScript is enabled by default in WKWebView on macOS; no opt-in is required here.

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
        Log.browser.debug("Created browser tab")
    }

    /// The address currently in the web view, or empty for a pristine tab.
    var currentURLString: String {
        webView.url?.absoluteString ?? url?.absoluteString ?? ""
    }

    // MARK: - Navigation

    func load(_ url: URL) {
        lastErrorDescription = nil
        Log.browser.debug("Loading \(url.absoluteString, privacy: .private)")
        webView.load(URLRequest(url: url))
    }

    func reload() {
        lastErrorDescription = nil
        if webView.url != nil {
            webView.reload()
        } else if let url {
            load(url)
        }
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    // MARK: - Observation

    private func observeWebView() {
        addObservation(for: \.title) { [weak self] webView in
            self?.titleDidChange(webView.title)
        }
        addObservation(for: \.url) { [weak self] webView in
            self?.urlDidChange(webView.url)
        }
        addObservation(for: \.isLoading) { [weak self] webView in
            self?.loadingDidChange(webView.isLoading)
        }
        addObservation(for: \.canGoBack) { [weak self] webView in
            self?.navigationStateDidChange(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        }
        addObservation(for: \.canGoForward) { [weak self] webView in
            self?.navigationStateDidChange(canGoBack: webView.canGoBack, canGoForward: webView.canGoForward)
        }
    }

    private func addObservation<Value>(
        for keyPath: KeyPath<WKWebView, Value>,
        onChange: @escaping @MainActor (WKWebView) -> Void
    ) {
        let observation = webView.observe(keyPath, options: [.new]) { webView, _ in
            // WebKit delivers these KVO callbacks on the main thread; this keeps the compiler's
            // actor isolation honest without adding an async hop (and therefore without reordering).
            MainActor.assumeIsolated {
                onChange(webView)
            }
        }
        observations.append(observation)
    }

    private func titleDidChange(_ newTitle: String?) {
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextTitle = trimmed.isEmpty ? fallbackTitle : trimmed
        guard title != nextTitle else { return }
        title = nextTitle
        onStateChange?(self)
    }

    private func urlDidChange(_ newURL: URL?) {
        guard url != newURL else { return }
        url = newURL
        let titleIsEmpty = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if titleIsEmpty, let newURL, newURL.scheme?.lowercased() != "about" {
            title = newURL.host ?? fallbackTitle
        }
        onStateChange?(self)
    }

    private var fallbackTitle: String {
        if let host = webView.url?.host, !host.isEmpty { return host }
        return "New Tab"
    }

    private func loadingDidChange(_ newValue: Bool) {
        guard isLoading != newValue else { return }
        isLoading = newValue
        if newValue {
            lastErrorDescription = nil
        }
        onStateChange?(self)
    }

    private func navigationStateDidChange(canGoBack: Bool, canGoForward: Bool) {
        guard self.canGoBack != canGoBack || self.canGoForward != canGoForward else { return }
        if self.canGoBack != canGoBack { self.canGoBack = canGoBack }
        if self.canGoForward != canGoForward { self.canGoForward = canGoForward }
        onStateChange?(self)
    }

    private func syncTitleFromWebView() {
        let trimmed = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? fallbackTitle : trimmed
    }

    private func recordVisit() {
        guard let pageURL = webView.url,
              let scheme = pageURL.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return }
        onVisit?(pageURL, title)
    }

    private func handleNavigationFailure(_ error: Error) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            onStateChange?(self)
            return
        }
        // 101 cannot-show-URL, 102 frame-load-interrupted-by-policy-change, 204 cannot-show-MIME-type.
        if nsError.domain == "WebKitErrorDomain", [101, 102, 204].contains(nsError.code) {
            onStateChange?(self)
            return
        }

        lastErrorDescription = "Couldn't open the page. \(error.localizedDescription)"
        Log.browser.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        onStateChange?(self)
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        lastErrorDescription = nil
        onStateChange?(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        isLoading = true
        url = webView.url
        syncTitleFromWebView()
        onStateChange?(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        url = webView.url
        syncTitleFromWebView()
        lastErrorDescription = nil
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        onStateChange?(self)
        recordVisit()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        lastErrorDescription = "The page stopped responding. Reload to try again."
        onStateChange?(self)
        Log.browser.error("Web content process terminated while browsing")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Links that belong to the system (mail, phone) open outside the mini browser.
        if let targetURL = navigationAction.request.url,
           let scheme = targetURL.scheme?.lowercased(),
           ["mailto", "tel", "sms", "facetime"].contains(scheme) {
            NSWorkspace.shared.open(targetURL)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let requestedURL = navigationAction.request.url else {
            return nil
        }
        if let onOpenNewTab {
            onOpenNewTab(requestedURL)
        } else {
            // No manager attached: keep the page in this tab instead of silently dropping it.
            webView.load(navigationAction.request)
        }
        return nil
    }
}
