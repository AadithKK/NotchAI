import AppKit
import Combine
import os
import WebKit

/// Owns one browsing session: its tabs, the selected tab, the address text and the history list.
///
/// The island browser and a detached window each get their own manager — and therefore their own
/// `WKWebsiteDataStore` when Settings asks for an independent session — while the history file
/// itself is shared through `BrowserHistoryStore.shared`.
@MainActor
final class BrowserManager: NSObject, ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var history: [BrowserHistoryEntry] = []
    /// What the address field shows; kept in sync with the selected tab.
    @Published var addressText: String = ""
    /// The last user-visible problem, mirrored from the selected tab or set by a rejected address.
    @Published var lastError: String?

    /// Mirrors of the selected tab's navigation state, convenient for chrome outside this view.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isAtHome = true

    /// Read by the browser chrome and applied by Settings changes.
    var searchEngine: BrowserSearchEngine
    var homepage: String

    private let dataStore: WKWebsiteDataStore
    private let historyStore: BrowserHistoryStore
    /// The URL the address text was last synced from. Title-only KVO changes then never clobber
    /// text the user is in the middle of typing.
    private var addressTextSource: String?

    init(
        searchEngine: BrowserSearchEngine = .google,
        dataStore: WKWebsiteDataStore = .default(),
        homepage: String = "https://www.apple.com",
        historyStore: BrowserHistoryStore = .shared
    ) {
        self.searchEngine = searchEngine
        self.dataStore = dataStore
        self.homepage = homepage
        self.historyStore = historyStore
        super.init()
        self.history = historyStore.entries
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(urlString: String? = nil) -> BrowserTab {
        let tab = makeTab()
        tabs.append(tab)
        selectedTabID = tab.id
        lastError = nil

        let target = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target.isEmpty {
            addressText = tab.currentURLString
            addressTextSource = tab.currentURLString
        } else if let url = BrowserURLResolver.resolve(target, searchEngine: searchEngine) {
            addressText = url.absoluteString
            addressTextSource = url.absoluteString
            tab.load(url)
        } else {
            lastError = "That address couldn't be opened."
        }

        syncSelectedTabState()
        Log.browser.info("Opened a new tab (\(self.tabs.count) total)")
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        let wasSelected = selectedTabID == id
        closing.stopLoading()
        tabs.remove(at: index)

        if tabs.isEmpty {
            newTab()
        } else if wasSelected {
            selectTab(tabs[min(index, tabs.count - 1)].id)
        }
        Log.browser.info("Closed a tab; \(self.tabs.count) remaining")
    }

    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        lastError = tab.lastErrorDescription
        updateAddressText(from: tab)
        syncSelectedTabState()
    }

    /// Guarantees a selected tab exists. The browser view calls this when it first appears and
    /// every navigation path calls it before loading.
    @discardableResult
    func ensureSelectedTab() -> BrowserTab {
        if let selectedTab { return selectedTab }
        if let first = tabs.first {
            selectedTabID = first.id
            updateAddressText(from: first)
            lastError = first.lastErrorDescription
            syncSelectedTabState()
            return first
        }
        return newTab()
    }

    // MARK: - Navigation

    func navigate(addressText rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = BrowserURLResolver.resolve(trimmed, searchEngine: searchEngine) else {
            lastError = "Enter a web address or a search term."
            return
        }
        lastError = nil
        let tab = ensureSelectedTab()
        addressText = url.absoluteString
        addressTextSource = url.absoluteString
        tab.load(url)
    }

    func goBack() {
        selectedTab?.goBack()
    }

    func goForward() {
        selectedTab?.goForward()
    }

    func reload() {
        lastError = nil
        selectedTab?.reload()
    }

    func stopLoading() {
        selectedTab?.stopLoading()
    }

    func loadHomepage() {
        guard let url = BrowserURLResolver.resolve(homepage, searchEngine: searchEngine) else {
            lastError = "The homepage address in Settings isn't valid."
            return
        }
        lastError = nil
        let tab = ensureSelectedTab()
        addressText = url.absoluteString
        addressTextSource = url.absoluteString
        tab.load(url)
    }

    func openInDefaultBrowser() {
        let candidates: [URL] = [
            selectedTab?.webView.url,
            BrowserURLResolver.resolve(addressText, searchEngine: searchEngine)
        ].compactMap { $0 }

        guard let url = candidates.first(where: isOpenableByDefaultBrowser) else {
            lastError = "There's no page to open yet."
            return
        }
        Log.browser.info("Opening the current page in the default browser")
        NSWorkspace.shared.open(url)
    }

    // MARK: - History

    /// Re-reads the shared history, e.g. when the popover opens after another window recorded a visit.
    func refreshHistory() {
        history = historyStore.entries
    }

    func clearHistory() {
        historyStore.clear()
        history = []
        Log.browser.info("Cleared browser history")
    }

    // MARK: - Data clearing

    /// Removes every cookie, cache and storage entry for this session, then resets the tabs and the
    /// shared history to a clean slate.
    func clearBrowsingData() async {
        var seen = Set<ObjectIdentifier>()
        var stores: [WKWebsiteDataStore] = []
        for tab in tabs {
            let store = tab.webView.configuration.websiteDataStore
            if seen.insert(ObjectIdentifier(store)).inserted {
                stores.append(store)
            }
        }
        if seen.insert(ObjectIdentifier(dataStore)).inserted {
            stores.append(dataStore)
        }

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        for store in stores {
            await store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
        }

        for tab in tabs {
            tab.stopLoading()
        }
        tabs.removeAll()
        selectedTabID = nil
        addressText = ""
        addressTextSource = ""
        lastError = nil
        historyStore.clear()
        history = []
        newTab()
        Log.browser.info("Cleared all browsing data")
    }

    // MARK: - Address sync

    /// Points the address field at the tab's current URL.
    func updateAddressText(from tab: BrowserTab) {
        guard tab.id == selectedTabID else { return }
        let current = tab.currentURLString
        addressTextSource = current
        addressText = current
    }

    private func tabStateDidChange(_ tab: BrowserTab) {
        guard tab.id == selectedTabID else { return }
        let current = tab.currentURLString
        if current != addressTextSource {
            addressTextSource = current
            addressText = current
        }
        if lastError != tab.lastErrorDescription { lastError = tab.lastErrorDescription }
        syncSelectedTabState()
    }

    private func syncSelectedTabState() {
        guard let tab = selectedTab else {
            canGoBack = false
            canGoForward = false
            isAtHome = true
            return
        }
        if canGoBack != tab.canGoBack { canGoBack = tab.canGoBack }
        if canGoForward != tab.canGoForward { canGoForward = tab.canGoForward }
        let atHome = tab.currentURLString.isEmpty
        if isAtHome != atHome { isAtHome = atHome }
    }

    // MARK: - Internals

    private func makeTab() -> BrowserTab {
        let tab = BrowserTab(dataStore: dataStore)
        tab.onVisit = { [weak self] url, title in
            self?.recordVisit(url: url, title: title)
        }
        tab.onOpenNewTab = { [weak self] url in
            self?.newTab(urlString: url.absoluteString)
        }
        tab.onStateChange = { [weak self] tab in
            self?.tabStateDidChange(tab)
        }
        return tab
    }

    private func recordVisit(url: URL, title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = BrowserHistoryEntry(
            url: url.absoluteString,
            title: cleanTitle.isEmpty ? (url.host ?? url.absoluteString) : cleanTitle
        )
        history = historyStore.record(entry)
        Log.browser.debug("Recorded a history entry (\(self.history.count) total)")
    }

    private func isOpenableByDefaultBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }
}
