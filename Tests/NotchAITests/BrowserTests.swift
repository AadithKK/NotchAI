import XCTest
@testable import NotchAI

/// Pure-logic coverage for the browser module: address/search resolution and the persisted history
/// store. WebKit (`WKWebView`) is intentionally never instantiated here, so the suite stays fast and
/// headless.
final class BrowserTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-BrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func resolve(_ text: String, engine: BrowserSearchEngine = .google) -> URL? {
        BrowserURLResolver.resolve(text, searchEngine: engine)
    }

    // MARK: - URL resolution

    func testExplicitHTTPSURLIsPreserved() throws {
        let url = try XCTUnwrap(resolve("https://example.com"))
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let url = try XCTUnwrap(resolve("  https://example.com  \n"))
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testBareDomainBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("example.com"))
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testDomainWithPathAndQueryBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("example.com/path?q=1"))
        XCTAssertEqual(url.absoluteString, "https://example.com/path?q=1")
    }

    func testDomainWithPortBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("example.com:8080/page"))
        XCTAssertEqual(url.absoluteString, "https://example.com:8080/page")
    }

    func testLocalhostWithPortBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("localhost:8080"))
        XCTAssertEqual(url.absoluteString, "https://localhost:8080")
    }

    func testLocalhostWithoutPortBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("localhost"))
        XCTAssertEqual(url.absoluteString, "https://localhost")
    }

    func testIPv4HostWithPortBecomesHTTPS() throws {
        let url = try XCTUnwrap(resolve("127.0.0.1:8000"))
        XCTAssertEqual(url.absoluteString, "https://127.0.0.1:8000")
    }

    func testWordsBecomeGoogleSearch() throws {
        let url = try XCTUnwrap(resolve("hello world"))
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=hello%20world")
    }

    func testSingleWordWithoutDotSearches() throws {
        let url = try XCTUnwrap(resolve("swiftui"))
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=swiftui")
    }

    func testMultiWordQueryIsPercentEncodedByURLComponents() throws {
        let query = "swift ui & concurrency"
        let url = try XCTUnwrap(resolve(query))

        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.google.com/search?"))
        XCTAssertTrue(url.absoluteString.contains("%20"))
        XCTAssertFalse(url.absoluteString.contains(" "))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        XCTAssertEqual(queryItems.filter { $0.name == "q" }.count, 1, "The engine template's existing ?q= must be reused, not duplicated")
        XCTAssertEqual(queryItems.first?.value, query)
    }

    func testDuckDuckGoTemplateIsRespected() throws {
        let url = try XCTUnwrap(resolve("swift ui", engine: .duckDuckGo))
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=swift%20ui")
    }

    func testBingTemplateIsRespected() throws {
        let url = try XCTUnwrap(resolve("swift ui", engine: .bing))
        XCTAssertEqual(url.absoluteString, "https://www.bing.com/search?q=swift%20ui")
    }

    func testEmptyAndWhitespaceOnlyInputIsNil() {
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("   "))
        XCTAssertNil(resolve("\n\t "))
    }

    func testMailtoAndTelephoneLinksAreRejected() {
        XCTAssertNil(resolve("mailto:a@b.com"))
        XCTAssertNil(resolve("tel:+15551234567"))
        XCTAssertNil(resolve("MAILTO:a@b.com"))
    }

    func testAboutBlankIsAllowed() throws {
        let url = try XCTUnwrap(resolve("about:blank"))
        XCTAssertEqual(url.absoluteString, "about:blank")
    }

    func testFileURLIsPreserved() throws {
        let url = try XCTUnwrap(resolve("file:///tmp/page.html"))
        XCTAssertEqual(url.absoluteString, "file:///tmp/page.html")
    }

    func testUppercaseSchemeIsAccepted() throws {
        let url = try XCTUnwrap(resolve("HTTPS://EXAMPLE.COM"))
        XCTAssertEqual(url.scheme?.lowercased(), "https")
        XCTAssertEqual(url.host?.lowercased(), "example.com")
    }

    // MARK: - History store

    func testHistoryRoundTrip() throws {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertTrue(store.entries.isEmpty)

        let first = BrowserHistoryEntry(
            url: "https://example.com/first",
            title: "First page",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = BrowserHistoryEntry(
            url: "https://example.com/second",
            title: "Second page",
            date: Date(timeIntervalSince1970: 1_700_000_100)
        )
        store.record(first)
        store.record(second)

        let reloaded = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertEqual(reloaded.entries.map(\.id), [second.id, first.id], "Newest entry comes first")
        XCTAssertEqual(reloaded.entries.map(\.url), [second.url, first.url])
        XCTAssertEqual(reloaded.entries.map(\.title), [second.title, first.title])
        let newestDate = try XCTUnwrap(reloaded.entries.first?.date)
        XCTAssertEqual(newestDate.timeIntervalSince1970, 1_700_000_100, accuracy: 0.001)
    }

    func testHistoryIsCappedAt200AndDropsOldestEntries() {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        for index in 0..<205 {
            store.record(
                BrowserHistoryEntry(
                    url: "https://example.com/\(index)",
                    title: "Page \(index)",
                    date: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        XCTAssertEqual(store.entries.count, BrowserHistoryStore.maximumEntries)
        XCTAssertEqual(store.entries.first?.url, "https://example.com/204")
        XCTAssertEqual(store.entries.last?.url, "https://example.com/5")

        let reloaded = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertEqual(reloaded.entries.count, BrowserHistoryStore.maximumEntries)
        XCTAssertEqual(reloaded.entries.first?.url, "https://example.com/204")
        XCTAssertEqual(reloaded.entries.last?.url, "https://example.com/5")
    }

    func testCorruptHistoryFileLoadsAsEmptyAndRecovers() throws {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        try Data("this is not valid json".utf8).write(to: store.fileURL, options: .atomic)

        let reloaded = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertTrue(reloaded.entries.isEmpty, "A corrupt file must never block the browser from opening")

        reloaded.record(BrowserHistoryEntry(url: "https://example.com", title: "Example"))
        let recovered = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertEqual(recovered.entries.count, 1)
        XCTAssertEqual(recovered.entries.first?.url, "https://example.com")
    }

    func testAtomicSaveWritesOnlyValidJSON() throws {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        store.record(
            BrowserHistoryEntry(
                url: "https://example.com/saved",
                title: "Saved",
                date: Date(timeIntervalSince1970: 1_700_000_200)
            )
        )

        let data = try Data(contentsOf: store.fileURL)
        let decoded = try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.url, "https://example.com/saved")
        XCTAssertEqual(decoded.first?.title, "Saved")

        let contents = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertEqual(contents.sorted(), [BrowserHistoryStore.fileName], "Atomic save leaves no temporary artifacts behind")
    }

    func testClearHistoryRemovesFileAndEntries() {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        store.record(BrowserHistoryEntry(url: "https://example.com", title: "Example"))

        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(BrowserHistoryStore(directory: temporaryDirectory).entries.isEmpty)
    }

    func testOversizedHistoryFileIsTrimmedOnLoad() throws {
        let store = BrowserHistoryStore(directory: temporaryDirectory)
        let entries = (0..<(BrowserHistoryStore.maximumEntries + 40)).map { index in
            BrowserHistoryEntry(
                url: "https://example.com/\(index)",
                title: "Page \(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let data = try JSONEncoder().encode(entries)
        try data.write(to: store.fileURL, options: .atomic)

        let reloaded = BrowserHistoryStore(directory: temporaryDirectory)
        XCTAssertEqual(reloaded.entries.count, BrowserHistoryStore.maximumEntries)
        XCTAssertEqual(reloaded.entries.first?.url, entries.first?.url)
        XCTAssertEqual(reloaded.entries.last?.url, entries[BrowserHistoryStore.maximumEntries - 1].url)
    }

    func testHistoryEntryDisplayTitleFallsBackToHost() {
        let entry = BrowserHistoryEntry(url: "https://example.com/page", title: "   ")
        XCTAssertEqual(entry.displayTitle, "example.com")

        let titled = BrowserHistoryEntry(url: "https://example.com/page", title: " Real title ")
        XCTAssertEqual(titled.displayTitle, "Real title")
    }

    func testDefaultStoreLocationMatchesAppPaths() {
        let store = BrowserHistoryStore()
        XCTAssertEqual(store.fileURL, AppPaths.browserHistoryFile)
    }
}
