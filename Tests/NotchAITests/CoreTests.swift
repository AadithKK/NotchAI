import XCTest
@testable import NotchAI

// MARK: - Fakes

final class FakeKeychain: SecureKeyStoring {
    var storage: [String: String] = [:]
    func set(_ value: String?, for key: String) throws {
        if let value { storage[key] = value } else { storage[key] = nil }
    }
    func value(for key: String) -> String? { storage[key] }
    func removeAll() throws { storage.removeAll() }
}

final class InMemoryChatStore: ChatPersisting {
    var conversations: [Conversation] = []
    var saveCount = 0
    func loadConversations() -> [Conversation] { conversations }
    func saveConversations(_ conversations: [Conversation]) {
        self.conversations = conversations
        saveCount += 1
    }
}

struct FakeProvider: AIProvider {
    let id: AIProviderID
    var chunks: [String] = ["Hello", " world"]
    var failure: Error?
    var models: [AIModel] = []

    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let chunks = chunks
            let failure = failure
            Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for chunk in chunks {
                    continuation.yield(.textDelta(chunk))
                }
                continuation.finish()
            }
        }
    }

    func availableModels(apiKey: String) async throws -> [AIModel] { models }
}

// MARK: - Geometry

final class IslandGeometryTests: XCTestCase {
    private let notchScreen = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 37,
        hasNotch: true,
        auxiliaryTopLeft: CGRect(x: 0, y: 945, width: 540, height: 37),
        auxiliaryTopRight: CGRect(x: 972, y: 945, width: 540, height: 37),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
    )

    private let plainScreen = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0,
        hasNotch: false,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil,
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
    )

    func testNotchRectMatchesCameraHousing() {
        let notch = IslandGeometry.notchRect(for: notchScreen)
        XCTAssertEqual(notch?.width, 432)
        XCTAssertEqual(notch?.height, 37)
        XCTAssertEqual(notch?.minX, 540)
    }

    func testCollapsedPillIsExactlyTheNotch() {
        let pill = IslandGeometry.pillSize(for: notchScreen)
        XCTAssertEqual(pill.width, 432)
        XCTAssertEqual(pill.height, 37)
    }

    func testAnchorWindowIsExactlyThePill() {
        let frame = IslandGeometry.anchorFrame(for: notchScreen)
        XCTAssertEqual(frame.width, 432)
        XCTAssertEqual(frame.height, 37)
        XCTAssertEqual(frame.maxY, notchScreen.frame.maxY)
        XCTAssertEqual(frame.minX, notchScreen.frame.midX - 432 / 2)
    }

    func testBadgeWindowSitsJustRightOfThePill() {
        let anchor = IslandGeometry.anchorFrame(for: notchScreen)
        let badge = IslandGeometry.badgeFrame(for: notchScreen)
        XCTAssertEqual(badge.minX, anchor.maxX + IslandGeometry.badgeGap)
        XCTAssertEqual(badge.midY, anchor.midY)
        XCTAssertEqual(badge.size, IslandGeometry.badgeSize)
    }

    func testHoverRegionCoversNotchAndBelowIt() {
        let region = IslandGeometry.hoverRegion(for: notchScreen)
        XCTAssertEqual(region.minX, notchScreen.frame.midX - 432 / 2 - IslandGeometry.hoverSideMargin)
        XCTAssertEqual(region.maxY, notchScreen.frame.maxY)
        XCTAssertEqual(region.height, 37 + IslandGeometry.hoverMarginBelow)
        XCTAssertEqual(region.width, 432 + IslandGeometry.hoverSideMargin * 2)
        // A point inside the hardware cutout and a point just below it both count as hover.
        XCTAssertTrue(region.contains(CGPoint(x: notchScreen.frame.midX, y: notchScreen.frame.maxY - 10)))
        XCTAssertTrue(region.contains(CGPoint(x: notchScreen.frame.midX, y: notchScreen.frame.maxY - 37 - 6)))
    }

    func testNotchlessAnchorSitsBelowMenuBarInset() {
        let pill = IslandGeometry.pillSize(for: plainScreen)
        XCTAssertEqual(pill, IslandGeometry.collapsedPillSize)
        let frame = IslandGeometry.anchorFrame(for: plainScreen)
        XCTAssertEqual(frame.maxY, plainScreen.frame.maxY - IslandGeometry.notchlessTopInset)
        XCTAssertEqual(frame.minX + IslandGeometry.collapsedPillSize.width / 2, plainScreen.frame.midX)
    }

    func testExpandedAndFullStartAtMenuBarBottom() {
        let expanded = IslandGeometry.contentFrame(for: .expanded, screen: notchScreen)
        XCTAssertEqual(expanded?.width, IslandGeometry.expandedSize.width)
        XCTAssertEqual(expanded?.height, IslandGeometry.expandedSize.height)
        XCTAssertEqual(expanded?.maxY, notchScreen.frame.maxY - notchScreen.safeAreaTop)
        XCTAssertEqual(expanded?.maxY, notchScreen.visibleFrame.maxY)

        let full = IslandGeometry.contentFrame(for: .full, screen: notchScreen)
        XCTAssertEqual(full?.width, IslandGeometry.fullSize.width)
        XCTAssertEqual(full?.maxY, notchScreen.frame.maxY - notchScreen.safeAreaTop)
        XCTAssertEqual(IslandGeometry.contentFrame(for: .collapsed, screen: notchScreen), nil)
    }

    func testContentPanelIsBelowMenuBarOnNotchlessDisplay() {
        let expanded = IslandGeometry.contentFrame(for: .expanded, screen: plainScreen)
        let expectedTop = plainScreen.frame.maxY - IslandGeometry.notchlessTopInset - IslandGeometry.collapsedPillSize.height
        XCTAssertEqual(expanded?.maxY, expectedTop)
    }

    func testNarrowScreenClampsWidth() {
        let narrow = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            safeAreaTop: 0,
            hasNotch: false,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let frame = IslandGeometry.contentFrame(for: .expanded, screen: narrow)
        XCTAssertNotNil(frame)
        XCTAssertLessThanOrEqual(frame?.width ?? 0, 384)
        XCTAssertGreaterThanOrEqual(frame?.width ?? 0, 120)
        XCTAssertGreaterThanOrEqual(frame?.minY ?? -1, 0)
    }
}

// MARK: - Markdown

final class MarkdownParserTests: XCTestCase {
    func testHeadingsCodeAndParagraphs() {
        let text = """
        # Title

        First paragraph.

        ```swift
        let x = 1
        ```

        ## Section
        More text.
        """
        let blocks = MarkdownParser.blocks(from: text)
        XCTAssertEqual(blocks.count, 5)
        if case let .heading(title, level) = blocks[0].kind {
            XCTAssertEqual(title, "Title")
            XCTAssertEqual(level, 1)
        } else {
            XCTFail("expected heading")
        }
        if case let .code(code, language) = blocks[2].kind {
            XCTAssertEqual(code, "let x = 1")
            XCTAssertEqual(language, "swift")
        } else {
            XCTFail("expected code block")
        }
        if case let .heading(section, level) = blocks[3].kind {
            XCTAssertEqual(section, "Section")
            XCTAssertEqual(level, 2)
        } else {
            XCTFail("expected heading")
        }
    }

    func testUnclosedFenceStillRenders() {
        let blocks = MarkdownParser.blocks(from: "```\nlet x = 1")
        XCTAssertEqual(blocks.count, 1)
        if case let .code(code, language) = blocks[0].kind {
            XCTAssertEqual(code, "let x = 1")
            XCTAssertNil(language)
        } else {
            XCTFail("expected code block")
        }
    }
}

// MARK: - Shortcut display

final class KeyboardShortcutTests: XCTestCase {
    func testDefaultShortcutDisplay() {
        let shortcut = KeyboardShortcut.defaultCapture
        XCTAssertEqual(shortcut.displayString, "⌃⌥⌘4")
    }

    func testKeyNames() {
        XCTAssertEqual(KeyboardShortcut.keyName(for: 0), "A")
        XCTAssertEqual(KeyboardShortcut.keyName(for: 49), "Space")
        XCTAssertEqual(KeyboardShortcut.keyName(for: 200), "Key 200")
    }
}

// MARK: - Settings store

@MainActor
final class SettingsStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var keychain: FakeKeychain!

    override func setUp() async throws {
        let suite = "NotchAI.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        keychain = FakeKeychain()
    }

    func testSettingsRoundTrip() {
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        store.settings.hoverBehavior = .none
        store.settings.appearance = .dark
        store.settings.screenshot.format = .jpeg
        store.settings.browser.searchEngine = .duckDuckGo

        let reloaded = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(reloaded.settings.hoverBehavior, .none)
        XCTAssertEqual(reloaded.settings.appearance, .dark)
        XCTAssertEqual(reloaded.settings.screenshot.format, .jpeg)
        XCTAssertEqual(reloaded.settings.browser.searchEngine, .duckDuckGo)
    }

    func testAPIKeysLiveInKeychainAndPresenceUpdates() throws {
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(store.keyPresence[.deepSeek], false)
        try store.saveAPIKey("sk-test", for: .deepSeek)
        XCTAssertEqual(keychain.storage["deepseek-api-key"], "sk-test")
        XCTAssertEqual(store.keyPresence[.deepSeek], true)
        try store.removeAPIKey(for: .deepSeek)
        XCTAssertNil(keychain.storage["deepseek-api-key"])
        XCTAssertEqual(store.keyPresence[.deepSeek], false)
    }

    func testDiscoveredModelsAreMergedAfterDefaults() {
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        let live = AIModel(id: "gemini-9-flash", displayName: "Gemini 9 Flash", provider: .gemini, supportsImages: true)
        store.setDiscoveredModels([live], for: .gemini)
        let models = store.models(for: .gemini)
        XCTAssertEqual(models.first?.id, AIModelCatalog.defaultGeminiModels.first?.id)
        XCTAssertTrue(models.contains { $0.id == "gemini-9-flash" })
    }

    func testSelectingModelUpdatesDefaults() {
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        let model = AIModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", provider: .deepSeek, supportsImages: false)
        store.select(model: model)
        XCTAssertEqual(store.settings.defaultProvider, .deepSeek)
        XCTAssertEqual(store.settings.defaultModelID, "deepseek-v4-pro")
        XCTAssertEqual(store.selectedModel.id, "deepseek-v4-pro")
    }
}

// MARK: - Chat store

final class JSONChatStoreTests: XCTestCase {
    func testRoundTrip() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchAI-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("conversations.json")
        let store = JSONChatStore(fileURL: file)
        let conversation = Conversation(title: "Test", messages: [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "hello", modelLabel: "deepseek-flash"),
        ])
        store.saveConversations([conversation])
        let loaded = store.loadConversations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Test")
        XCTAssertEqual(loaded[0].messages.count, 2)
        XCTAssertEqual(loaded[0].messages[1].text, "hello")
        try? FileManager.default.removeItem(at: directory)
    }

    func testCorruptFileLoadsEmpty() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchAI-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("conversations.json")
        try? Data("{not json".utf8).write(to: file)
        XCTAssertTrue(JSONChatStore(fileURL: file).loadConversations().isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Chat manager

@MainActor
final class ChatManagerTests: XCTestCase {
    func makeManager(store: InMemoryChatStore = InMemoryChatStore(), provider: FakeProvider = FakeProvider(id: .deepSeek)) -> ChatManager {
        let registry = AIProviderRegistry(deepSeek: provider, gemini: provider)
        let manager = ChatManager(store: store, providers: registry)
        manager.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        manager.resolveAPIKey = { _ in "test-key" }
        return manager
    }

    private func waitForIdle(_ manager: ChatManager, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !manager.isPreparingSend && !manager.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSendStreamsAssistantReplyAndPersists() async throws {
        let store = InMemoryChatStore()
        let manager = makeManager(store: store)
        manager.draft = "Hi"
        manager.sendDraft()
        await waitForIdle(manager)
        XCTAssertFalse(manager.isStreaming)
        XCTAssertFalse(manager.isPreparingSend)
        let messages = manager.currentConversation.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "Hi")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "Hello world")
        XCTAssertGreaterThan(store.saveCount, 0)
    }

    func testSuccessfulReplyEmitsCompletionPulse() async throws {
        let manager = makeManager()
        XCTAssertEqual(manager.completionPulse, 0)
        manager.send(text: "Hello")
        await waitForIdle(manager)
        XCTAssertEqual(manager.completionPulse, 1)
    }

    func testTitleComesFromFirstUserMessage() async throws {
        let manager = makeManager()
        manager.send(text: "Write a spec for a login page")
        await waitForIdle(manager)
        XCTAssertEqual(manager.currentConversation.title, "Write a spec for a login page")
    }

    func testMissingAPIKeyFailsBeforeStreaming() {
        let manager = makeManager()
        manager.resolveAPIKey = { _ in nil }
        manager.send(text: "Hello")
        XCTAssertTrue(manager.isStreaming == false)
        XCTAssertTrue(manager.errorMessage?.contains("API key") == true)
        XCTAssertTrue(manager.currentConversation.messages.isEmpty)
    }

    func testUnsupportedModelRejectsScreenshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchAI-shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let screenshot = CapturedScreenshot(
            id: UUID(),
            fileURL: file,
            pixelWidth: 100,
            pixelHeight: 100,
            displayName: "Test Display",
            createdAt: Date()
        )
        let manager = makeManager()
        manager.resolveModel = {
            AIModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", provider: .deepSeek, supportsImages: false)
        }
        manager.attach(screenshot)
        manager.send(text: "Look at this")
        XCTAssertFalse(manager.isStreaming)
        XCTAssertTrue(manager.errorMessage?.contains("does not accept screenshots") == true)
        XCTAssertEqual(manager.pendingAttachments.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAttachmentCleanupOnlyRemovesSessionCaptures() throws {
        let sessionFile = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("session-\(UUID().uuidString).png")
        let keptFile = AppPaths.screenshotsDirectory
            .appendingPathComponent("kept-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: sessionFile)
        try Data([0x89, 0x50]).write(to: keptFile)
        defer {
            try? FileManager.default.removeItem(at: sessionFile)
            try? FileManager.default.removeItem(at: keptFile)
        }

        let manager = makeManager()
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: sessionFile, pixelWidth: 1, pixelHeight: 1, displayName: "Session", createdAt: Date()))
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: keptFile, pixelWidth: 1, pixelHeight: 1, displayName: "Kept", createdAt: Date()))
        XCTAssertEqual(manager.pendingAttachments.count, 2)

        for attachment in manager.pendingAttachments {
            manager.removeAttachment(attachment.id)
        }
        XCTAssertTrue(manager.pendingAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path), "session capture should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path), "kept capture must survive attachment removal")
    }

    func testClearHistoryRemovesMessages() async throws {
        let manager = makeManager()
        manager.send(text: "Hello")
        await waitForIdle(manager)
        manager.clearAllHistory()
        XCTAssertTrue(manager.currentConversation.messages.isEmpty)
        XCTAssertTrue(manager.conversations.count == 1)
    }
}

// MARK: - Attachment sanitizer (security regression coverage)

final class AttachmentSanitizerTests: XCTestCase {
    private var scratchPaths: [URL] = []

    override func tearDown() {
        for path in scratchPaths {
            try? FileManager.default.removeItem(at: path)
        }
        scratchPaths = []
        super.tearDown()
    }

    private func makeFile(_ url: URL, bytes: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        scratchPaths.append(url)
        return url
    }

    private func makeTempRef(fileURL: URL) -> ImageAttachmentRef {
        ImageAttachmentRef(id: UUID(), fileURL: fileURL, pixelWidth: 10, pixelHeight: 10, createdAt: Date())
    }

    private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    func testRejectsFileOutsideAllowedDirectories() throws {
        let outside = try makeFile(
            FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png"),
            bytes: pngMagic
        )
        XCTAssertFalse(AttachmentSanitizer.isInsideAllowedDirectory(outside))
        XCTAssertNil(AttachmentSanitizer.payload(for: makeTempRef(fileURL: outside)))
    }

    func testRejectsDotDotTraversalToSiblingFile() throws {
        let victim = try makeFile(
            AppPaths.appSupportDirectory.appendingPathComponent("victim-\(UUID().uuidString).png"),
            bytes: pngMagic
        )
        // `Screenshots-Session/../victim.png` standardizes outside the session directory.
        let traversal = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("..")
            .appendingPathComponent(victim.lastPathComponent)
        XCTAssertFalse(
            AttachmentSanitizer.isStrictlyInside(AppPaths.temporaryCapturesDirectory, traversal)
        )
        XCTAssertNil(AttachmentSanitizer.payload(for: makeTempRef(fileURL: traversal)))
    }

    func testRejectsSiblingDirectoryWithSharedPrefix() throws {
        let siblingDirectory = AppPaths.appSupportDirectory
            .appendingPathComponent("Screenshots-Session-backup", isDirectory: true)
        let siblingFile = try makeFile(
            siblingDirectory.appendingPathComponent("kept-\(UUID().uuidString).png"),
            bytes: pngMagic
        )
        scratchPaths.append(siblingDirectory)
        XCTAssertFalse(
            AttachmentSanitizer.isStrictlyInside(AppPaths.temporaryCapturesDirectory, siblingFile)
        )
        XCTAssertNil(AttachmentSanitizer.payload(for: makeTempRef(fileURL: siblingFile)))
    }

    func testAcceptsValidPNGInsideSessionDirectory() throws {
        let file = try makeFile(
            AppPaths.temporaryCapturesDirectory.appendingPathComponent("valid-\(UUID().uuidString).png"),
            bytes: pngMagic + Array(repeating: 0, count: 32)
        )
        let payload = AttachmentSanitizer.payload(for: makeTempRef(fileURL: file))
        XCTAssertEqual(payload?.mimeType, "image/png")
        XCTAssertFalse(payload?.base64.isEmpty ?? true)
    }

    func testRejectsNonImageAndOversizedFiles() throws {
        let textFile = try makeFile(
            AppPaths.temporaryCapturesDirectory.appendingPathComponent("text-\(UUID().uuidString).png"),
            bytes: Array("not an image at all".utf8)
        )
        XCTAssertNil(AttachmentSanitizer.payload(for: makeTempRef(fileURL: textFile)))

        let largeFile = try makeFile(
            AppPaths.temporaryCapturesDirectory.appendingPathComponent("large-\(UUID().uuidString).png"),
            bytes: pngMagic + Array(repeating: 0, count: 64)
        )
        XCTAssertNil(AttachmentSanitizer.payload(for: makeTempRef(fileURL: largeFile), maximumBytes: 8))
    }

    func testPreparedPayloadsEnforcesAggregateEncodedBudget() throws {
        var refs: [ImageAttachmentRef] = []
        for index in 0..<3 {
            let file = try makeFile(
                AppPaths.temporaryCapturesDirectory.appendingPathComponent("batch-\(index)-\(UUID().uuidString).png"),
                bytes: pngMagic + Array(repeating: 0, count: 8)
            )
            refs.append(makeTempRef(fileURL: file))
        }
        // Each 16-byte image encodes to 24 base64 characters; a 30-character total budget fits one.
        let prepared = AttachmentSanitizer.preparedPayloads(
            for: refs,
            maximumRawBytes: 100,
            maximumTotalEncodedBytes: 30
        )
        XCTAssertEqual(prepared.payloads.count, 1)
        XCTAssertEqual(prepared.dropped, 2)
    }

    func testPreparedPayloadsHonorsCustomRawCapWithoutSecondRead() throws {
        let file = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("cap-\(UUID().uuidString).png")
        var bytes = pngMagic
        bytes.append(contentsOf: Array(repeating: 0, count: 15 * 1024 * 1024))
        try Data(bytes).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let ref = makeTempRef(fileURL: file)
        let prepared = AttachmentSanitizer.preparedPayloads(
            for: [ref],
            maximumRawBytes: 20 * 1024 * 1024,
            maximumTotalEncodedBytes: 32 * 1024 * 1024
        )
        XCTAssertEqual(prepared.payloads.count, 1, "custom raw cap must be honored")
        XCTAssertEqual(prepared.dropped, 0)
    }

    func testAttachmentBudgetIsSharedAcrossMessages() throws {
        var refs: [ImageAttachmentRef] = []
        for index in 0..<2 {
            let file = try makeFile(
                AppPaths.temporaryCapturesDirectory.appendingPathComponent("shared-\(index)-\(UUID().uuidString).png"),
                bytes: pngMagic + Array(repeating: 0, count: 8)
            )
            refs.append(makeTempRef(fileURL: file))
        }
        // 24 base64 chars per image, 30-char request budget: the second message must be dropped.
        var budget = AttachmentSanitizer.AttachmentBudget(totalEncodedBytes: 30)
        let first = budget.prepare([refs[0]])
        let second = budget.prepare([refs[1]])
        XCTAssertEqual(first.payloads.count, 1)
        XCTAssertEqual(second.payloads.count, 0)
        XCTAssertEqual(second.dropped, 1)
    }

    func testPreparedPayloadsDropsOversizedRawImage() throws {
        let file = try makeFile(
            AppPaths.temporaryCapturesDirectory.appendingPathComponent("raw-\(UUID().uuidString).png"),
            bytes: pngMagic + Array(repeating: 0, count: 8)
        )
        let prepared = AttachmentSanitizer.preparedPayloads(
            for: [makeTempRef(fileURL: file)],
            maximumRawBytes: 8
        )
        XCTAssertTrue(prepared.payloads.isEmpty)
        XCTAssertEqual(prepared.dropped, 1)
    }

    func testDetectsImageMagicBytes() {
        XCTAssertEqual(AttachmentSanitizer.imageMimeType(for: Data(pngMagic)), "image/png")
        XCTAssertEqual(AttachmentSanitizer.imageMimeType(for: Data([0xFF, 0xD8, 0xFF, 0x00])), "image/jpeg")
        XCTAssertEqual(AttachmentSanitizer.imageMimeType(for: Data(Array("GIF89a".utf8))), "image/gif")
        XCTAssertNil(AttachmentSanitizer.imageMimeType(for: Data(Array("plain text".utf8))))
    }
}

// MARK: - Capture delivery policy

final class CaptureDeliveryPolicyTests: XCTestCase {
    func testDeletesOnlyWhenNeitherAttachedNorKept() {
        XCTAssertTrue(CaptureDeliveryPolicy.deleteImmediately(attachToChat: false, isReplacement: false, saveLocally: false))
        XCTAssertFalse(CaptureDeliveryPolicy.deleteImmediately(attachToChat: true, isReplacement: false, saveLocally: false))
        XCTAssertFalse(CaptureDeliveryPolicy.deleteImmediately(attachToChat: false, isReplacement: true, saveLocally: false))
        XCTAssertFalse(CaptureDeliveryPolicy.deleteImmediately(attachToChat: false, isReplacement: false, saveLocally: true))
    }
}

// MARK: - Small-screen island geometry

final class IslandGeometryClampTests: XCTestCase {
    private let smallScreen = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 640, height: 480),
        safeAreaTop: 0,
        hasNotch: false,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil,
        visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 455)
    )

    func testFullPanelStaysOnScreenOnSmallDisplay() {
        let frame = IslandGeometry.contentFrame(for: .full, screen: smallScreen)
        XCTAssertNotNil(frame)
        XCTAssertGreaterThanOrEqual(frame?.minY ?? -1, smallScreen.frame.minY)
        XCTAssertLessThanOrEqual(frame?.maxY ?? .infinity, smallScreen.frame.maxY)
        XCTAssertLessThan(frame?.height ?? .infinity, IslandGeometry.fullSize.height)
        XCTAssertGreaterThan(frame?.height ?? 0, 200)
    }

    func testExpandedPanelStaysOnScreenOnSmallDisplay() {
        let frame = IslandGeometry.contentFrame(for: .expanded, screen: smallScreen)
        XCTAssertNotNil(frame)
        XCTAssertGreaterThanOrEqual(frame?.minY ?? -1, smallScreen.frame.minY)
        XCTAssertLessThanOrEqual(frame?.maxY ?? .infinity, smallScreen.frame.maxY)
    }
}

// MARK: - Chat safety regressions

private final class HangingProvider: AIProvider {
    let id: AIProviderID = .deepSeek

    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in }
        }
    }

    func availableModels(apiKey: String) async throws -> [AIModel] { [] }
}

private final class EmptySuccessProvider: AIProvider {
    let id: AIProviderID = .deepSeek
    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
    func availableModels(apiKey: String) async throws -> [AIModel] { [] }
}

private final class RecordingProvider: @unchecked Sendable, AIProvider {
    let id: AIProviderID = .deepSeek
    var received: [[ProviderMessage]] = []

    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        received.append(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.finish()
        }
    }

    func availableModels(apiKey: String) async throws -> [AIModel] { [] }
}

@MainActor
final class ChatManagerSafetyTests: XCTestCase {
    private func makeManager(deepSeek: any AIProvider, store: InMemoryChatStore = InMemoryChatStore()) -> ChatManager {
        let registry = AIProviderRegistry(deepSeek: deepSeek, gemini: deepSeek)
        let manager = ChatManager(store: store, providers: registry)
        manager.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        manager.resolveAPIKey = { _ in "test-key" }
        return manager
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testStopBeforeFirstTokenRemovesPlaceholder() async throws {
        let manager = makeManager(deepSeek: HangingProvider())
        manager.send(text: "hi")
        await waitUntil { manager.isStreaming }
        XCTAssertTrue(manager.isStreaming)
        manager.stop()
        await waitUntil { !manager.isStreaming }
        XCTAssertFalse(manager.isStreaming)
        let messages = manager.currentConversation.messages
        XCTAssertEqual(manager.completionPulse, 0, "a cancelled empty response must not announce completion")
        XCTAssertEqual(messages.count, 1, "cancelled empty placeholder must be removed")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertFalse(messages.contains { $0.text == "(no response)" })
    }

    func testClearAllHistoryDeletesPendingSessionCapture() throws {
        let file = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("pending-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let manager = makeManager(deepSeek: FakeProvider(id: .deepSeek))
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: file, pixelWidth: 1, pixelHeight: 1, displayName: "Test", createdAt: Date()))
        XCTAssertEqual(manager.pendingAttachments.count, 1)
        manager.clearAllHistory()
        XCTAssertTrue(manager.pendingAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "pending session capture must be deleted")
    }

    func testEmptySuccessfulStreamDoesNotAnnounceCompletionOrFabricateReply() async throws {
        let store = InMemoryChatStore()
        let manager = makeManager(deepSeek: EmptySuccessProvider(), store: store)
        manager.send(text: "hello")
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming }
        XCTAssertEqual(manager.completionPulse, 0)
        XCTAssertTrue(manager.errorMessage?.contains("without returning any text") == true)
        XCTAssertEqual(manager.currentConversation.messages.last?.role, .user)
        XCTAssertFalse(manager.currentConversation.messages.contains { $0.text == "(no response)" })
        XCTAssertFalse(store.conversations.contains { conversation in
            conversation.messages.contains { $0.text == "(no response)" }
        })
    }

    func testConversationCannotSwitchWhilePreparingSend() async throws {
        let file = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("guard-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let manager = makeManager(deepSeek: RecordingProvider())
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: file, pixelWidth: 1, pixelHeight: 1, displayName: "Guard", createdAt: Date()))
        let originalID = manager.selectedConversationID
        manager.send(text: "stay in this conversation")
        XCTAssertTrue(manager.isPreparingSend)
        manager.newConversation()
        XCTAssertEqual(manager.conversations.count, 1, "new conversation must be blocked during attachment prep")
        XCTAssertEqual(manager.selectedConversationID, originalID)
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming }
        XCTAssertEqual(manager.selectedConversationID, originalID)
        XCTAssertFalse(manager.currentConversation.messages.isEmpty)
    }

    func testSanitizedAllowedImageReachesProvider() async throws {
        let allowed = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("allowed-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: allowed)
        defer { try? FileManager.default.removeItem(at: allowed) }

        let provider = RecordingProvider()
        let manager = makeManager(deepSeek: provider)
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: allowed, pixelWidth: 1, pixelHeight: 1, displayName: "Allowed", createdAt: Date()))
        manager.send(text: "look")
        await waitUntil { !manager.isStreaming }
        await waitUntil { !provider.received.isEmpty }

        let userMessages = provider.received.compactMap { $0.first(where: { $0.role == .user }) }
        XCTAssertEqual(userMessages.count, 1)
        XCTAssertEqual(userMessages.first?.images.count, 1)
        XCTAssertEqual(userMessages.first?.images.first?.mimeType, "image/png")
    }

    func testUnsendableAttachmentSurfacesErrorAndKeepsComposer() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let provider = RecordingProvider()
        let manager = makeManager(deepSeek: provider)
        manager.draft = "look at this"
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: outside, pixelWidth: 1, pixelHeight: 1, displayName: "Outside", createdAt: Date()))
        manager.sendDraft()
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming && manager.errorMessage != nil }

        XCTAssertTrue(provider.received.isEmpty, "provider must not be called while an attachment is unsendable")
        XCTAssertTrue(manager.errorMessage?.contains("could not be sent") == true, "user must be told the attachment was not sent")
        XCTAssertEqual(manager.pendingAttachments.count, 1, "composer attachment must not be discarded")
        XCTAssertEqual(manager.draft, "look at this", "draft must not be cleared on rejection")
        XCTAssertTrue(manager.currentConversation.messages.isEmpty, "no user message may be appended on rejection")

        // Removing the rejected attachment must let the same conversation send again.
        manager.removeAttachment(manager.pendingAttachments[0].id)
        manager.send(text: "second, text only")
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming }
        await waitUntil { !provider.received.isEmpty }
        XCTAssertEqual(provider.received.count, 1, "text-only send must reach the provider")
        XCTAssertFalse(manager.currentConversation.messages.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }

    func testHistoricalUnreadableAttachmentDoesNotBlockLaterSends() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let provider = RecordingProvider()
        let manager = makeManager(deepSeek: provider)
        // Simulate a restored history whose stored path is outside the capture folders.
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: outside, pixelWidth: 1, pixelHeight: 1, displayName: "Old", createdAt: Date()))
        manager.send(text: "first")
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming }
        XCTAssertTrue(manager.errorMessage?.contains("could not be sent") == true)

        // The rejected attachment is still pending; remove it and send again.
        if let pending = manager.pendingAttachments.first {
            manager.removeAttachment(pending.id)
        }
        manager.send(text: "second")
        await waitUntil { !manager.isPreparingSend && !manager.isStreaming }
        await waitUntil { !provider.received.isEmpty }
        XCTAssertTrue(provider.received.count >= 1)
        XCTAssertNil(manager.errorMessage)
    }

    func testDiscardUnsentSessionCapturesAtShutdown() throws {
        let file = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("unsent-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let manager = makeManager(deepSeek: FakeProvider(id: .deepSeek))
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: file, pixelWidth: 1, pixelHeight: 1, displayName: "Unsent", createdAt: Date()))
        manager.discardUnsentSessionCaptures()
        XCTAssertTrue(manager.pendingAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: - Screenshot exclusion of additional app windows

final class CaptureAdditionalWindowTests: XCTestCase {
    func testAdditionalWindowNumbersAreAlwaysExcluded() {
        let windows: [CaptureFilterLogic.WindowInfo] = [
            .init(windowNumber: 10, ownerPID: 999),
            .init(windowNumber: 11, ownerPID: 999),
            .init(windowNumber: 12, ownerPID: 999),
        ]
        let excluded = CaptureFilterLogic.exclusions(
            ourPID: 999,
            islandWindowNumber: 10,
            additionalWindowNumbers: [11],
            excludeAllOwnedWindows: false,
            windows: windows
        )
        XCTAssertEqual(excluded, [10, 11])
    }

    func testAdditionalWindowNumbersAreDedupedAndSorted() {
        let windows: [CaptureFilterLogic.WindowInfo] = [
            .init(windowNumber: 42, ownerPID: 7),
            .init(windowNumber: 41, ownerPID: 7),
        ]
        let excluded = CaptureFilterLogic.exclusions(
            ourPID: 1,
            islandWindowNumber: 42,
            additionalWindowNumbers: [41, 42],
            excludeAllOwnedWindows: false,
            windows: windows
        )
        XCTAssertEqual(excluded, [41, 42])
    }
}

// MARK: - Hover dwell policy

final class HoverDwellTests: XCTestCase {
    func testDwellRequiresFullSecondInside() {
        var tracker = HoverDwellTracker()
        let start = Date()
        XCTAssertFalse(tracker.shouldOpen(inside: true, now: start))
        XCTAssertFalse(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(0.9)))
        XCTAssertTrue(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(1.0)))
        XCTAssertFalse(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(1.1)), "dwell must fire once")
        XCTAssertEqual(IslandHoverPolicy.openDwell, 1.0)
    }

    func testLeavingResetsTheDwellTimer() {
        var tracker = HoverDwellTracker()
        let start = Date()
        _ = tracker.shouldOpen(inside: true, now: start)
        XCTAssertFalse(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(0.8)))
        _ = tracker.shouldOpen(inside: false, now: start.addingTimeInterval(0.85))
        XCTAssertFalse(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(0.86)))
        XCTAssertTrue(tracker.shouldOpen(inside: true, now: start.addingTimeInterval(1.87)))
    }

    func testCloseDelaysArePrompt() {
        XCTAssertLessThanOrEqual(IslandHoverPolicy.closeDelayExpanded, 0.1)
        XCTAssertLessThanOrEqual(IslandHoverPolicy.closeDelayFull, 0.2)
    }
}

// MARK: - Restart persistence and full reset

@MainActor
final class ChatPersistenceTests: XCTestCase {
    private func makeManager(
        store: InMemoryChatStore,
        defaults: UserDefaults,
        provider: FakeProvider = FakeProvider(id: .deepSeek)
    ) -> ChatManager {
        let registry = AIProviderRegistry(deepSeek: provider, gemini: provider)
        let manager = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        manager.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        manager.resolveAPIKey = { _ in "test-key" }
        return manager
    }

    private func waitForIdle(_ manager: ChatManager, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !manager.isPreparingSend && !manager.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testResetDuringPreparationDoesNotSendAndClearsHistory() async throws {
        let suite = "NotchAI.reset-preparation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryChatStore()
        let provider = RecordingProvider()
        let registry = AIProviderRegistry(deepSeek: provider, gemini: provider)
        let manager = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        manager.resolveAPIKey = { _ in "test-key" }
        let oldID = manager.selectedConversationID
        manager.draft = "Do not send this after reset"
        manager.sendDraft()
        XCTAssertTrue(manager.isPreparingSend)
        manager.resetAllConversations()
        await waitForIdle(manager)
        XCTAssertNotEqual(manager.selectedConversationID, oldID)
        XCTAssertTrue(manager.currentConversation.messages.isEmpty)
        XCTAssertTrue(manager.draft.isEmpty)
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertTrue(store.conversations.allSatisfy { $0.messages.isEmpty })
        XCTAssertEqual(manager.completionPulse, 0)
    }

    func testResetDoesNotPublishCompletionPulse() async throws {
        let suite = "NotchAI.reset-pulse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeManager(store: InMemoryChatStore(), defaults: defaults)
        manager.send(text: "Finish a reply")
        await waitForIdle(manager)
        let pulse = manager.completionPulse
        XCTAssertEqual(pulse, 1)
        manager.resetAllConversations()
        XCTAssertEqual(manager.completionPulse, pulse)
    }

    func testConversationsAndSelectionSurviveRelaunch() async throws {
        let suite = "NotchAI.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = InMemoryChatStore()

        let first = makeManager(store: store, defaults: defaults)
        first.send(text: "survive the restart")
        await waitForIdle(first)
        XCTAssertTrue(first.conversations[0].messages.contains { $0.text == "survive the restart" })

        first.newConversation()
        let secondID = first.selectedConversationID
        XCTAssertEqual(first.conversations.count, 2)
        first.selectConversation(first.conversations.first(where: { $0.id != secondID })!.id)
        let selectedBefore = first.selectedConversationID
        first.persistNow()

        // New process/manager with the same on-disk store and defaults.
        let relaunched = makeManager(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.selectedConversationID, selectedBefore)
        XCTAssertTrue(relaunched.conversations.contains { conversation in
            conversation.messages.contains { $0.text == "survive the restart" }
        })
        XCTAssertEqual(relaunched.conversations.count, first.conversations.count)
    }

    func testSelectionChangeIsPersistedImmediately() async throws {
        let suite = "NotchAI.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = InMemoryChatStore()
        let manager = makeManager(store: store, defaults: defaults)
        manager.newConversation()
        let chosen = manager.selectedConversationID
        manager.persistNow()

        let relaunched = makeManager(store: store, defaults: defaults)
        XCTAssertEqual(relaunched.selectedConversationID, chosen)
    }

    func testResetDuringStreamingLeavesNoStaleReply() async throws {
        let suite = "NotchAI.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = InMemoryChatStore()
        let manager = makeManager(store: store, defaults: defaults, provider: FakeProvider(id: .deepSeek))
        // A hanging provider keeps the stream open while we reset.
        let hanging = HangingProvider()
        let registry = AIProviderRegistry(deepSeek: hanging, gemini: hanging)
        let resetting = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        resetting.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        resetting.resolveAPIKey = { _ in "test-key" }
        resetting.send(text: "streaming")
        for _ in 0..<200 where !resetting.isStreaming {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(resetting.isStreaming)
        resetting.resetAllConversations()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(resetting.isStreaming)
        XCTAssertTrue(resetting.currentConversation.messages.isEmpty)
        XCTAssertTrue(store.conversations.allSatisfy { $0.messages.isEmpty })
    }

    func testJSONStoreConversationsSurviveProcessRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONChatStore(fileURL: directory.appendingPathComponent("conversations.json"))
        let suite = "NotchAI.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let registry = AIProviderRegistry(
            deepSeek: FakeProvider(id: .deepSeek),
            gemini: FakeProvider(id: .deepSeek)
        )
        let first = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        first.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        first.resolveAPIKey = { _ in "test-key" }
        first.send(text: "persist through a process restart")
        await waitForIdle(first)
        let selection = first.selectedConversationID

        // Simulates the next launch: same file store, same defaults, new manager.
        let relaunched = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        XCTAssertEqual(relaunched.selectedConversationID, selection)
        XCTAssertTrue(relaunched.conversations.contains { conversation in
            conversation.messages.contains { $0.text == "persist through a process restart" }
        })
    }

    func testResetAllConversationsClearsHistoryAndSessionFiles() async throws {
        let suite = "NotchAI.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = InMemoryChatStore()
        let manager = makeManager(store: store, defaults: defaults)

        manager.send(text: "old history")
        await waitForIdle(manager)
        XCTAssertFalse(manager.currentConversation.messages.isEmpty)

        let file = AppPaths.temporaryCapturesDirectory
            .appendingPathComponent("reset-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        manager.attach(CapturedScreenshot(id: UUID(), fileURL: file, pixelWidth: 1, pixelHeight: 1, displayName: "Reset", createdAt: Date()))

        manager.resetAllConversations()

        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertTrue(manager.currentConversation.messages.isEmpty)
        XCTAssertTrue(manager.pendingAttachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.conversations.count == 1)
        XCTAssertTrue(store.conversations[0].messages.isEmpty)
        let stored = defaults.string(forKey: "NotchAI.selectedConversationID")
        XCTAssertEqual(stored, manager.selectedConversationID.uuidString)
    }
}

// MARK: - Regenerate must not delete an older answer

@MainActor
final class ChatRegenerateSafetyTests: XCTestCase {
    private func waitForIdle(_ manager: ChatManager, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !manager.isPreparingSend && !manager.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testRegenerateAfterStoppedEmptyReplyKeepsEarlierAnswer() async throws {
        let suite = "NotchAI.regenerate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let conversation = Conversation(
            title: "Two questions",
            messages: [
                ChatMessage(role: .user, text: "first question"),
                ChatMessage(role: .assistant, text: "GOOD ANSWER"),
                ChatMessage(role: .user, text: "second question"),
            ]
        )
        let store = InMemoryChatStore()
        store.conversations = [conversation]
        let provider = RecordingProvider()
        let registry = AIProviderRegistry(deepSeek: provider, gemini: provider)
        let manager = ChatManager(store: store, providers: registry, selectionDefaults: defaults)
        manager.resolveModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
        manager.resolveAPIKey = { _ in "test-key" }

        manager.regenerate()
        await waitForIdle(manager)

        let messages = manager.currentConversation.messages
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.text == "GOOD ANSWER" },
                      "regenerate must keep the earlier assistant answer")
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.text, "ok")
        XCTAssertFalse(provider.received.isEmpty)
        let recorded = try XCTUnwrap(provider.received.first)
        XCTAssertEqual(recorded.last?.role, .user)
        XCTAssertEqual(recorded.last?.text, "second question")
    }
}

// MARK: - Lenient chat-store decoding + backup

final class JSONChatStoreSalvageTests: XCTestCase {
    func testOneUnknownProviderKeepsOtherConversationsAndBacksUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-salvage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("conversations.json")

        let good = Conversation(
            title: "Good conversation",
            messages: [ChatMessage(role: .user, text: "keep me")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let goodData = try encoder.encode([good])
        var elements = try XCTUnwrap(JSONSerialization.jsonObject(with: goodData) as? [[String: Any]])
        var bad = try XCTUnwrap(elements.first)
        bad["providerID"] = "some-future-provider"
        elements.append(bad)
        let fileData = try JSONSerialization.data(withJSONObject: elements, options: [.prettyPrinted])
        try fileData.write(to: fileURL)

        let store = JSONChatStore(fileURL: fileURL)
        let loaded = store.loadConversations()
        XCTAssertEqual(loaded.count, 1, "valid conversations must survive an unreadable sibling")
        XCTAssertEqual(loaded.first?.title, "Good conversation")

        store.saveConversations(loaded)
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("conversations.unreadable-") },
                      "the unreadable original must be backed up before overwrite")
        XCTAssertEqual(store.loadConversations().count, 1)
    }

    func testCompletelyCorruptFileIsBackedUpOnNextSave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("conversations.json")
        try Data("{not a conversation array".utf8).write(to: fileURL)

        let store = JSONChatStore(fileURL: fileURL)
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.saveConversations([Conversation(title: "Fresh")])
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("conversations.unreadable-") })
        XCTAssertEqual(store.loadConversations().count, 1)
    }
}

final class JSONChatStoreUnreadableTests: XCTestCase {
    func testUnreadablePresentFileIsBackedUpBeforeOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAI-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("conversations.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode([Conversation(title: "Original", messages: [ChatMessage(role: .user, text: "old")])])
        try original.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = JSONChatStore(fileURL: fileURL)
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.saveConversations([Conversation(title: "Fresh")])
        store.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("conversations.unreadable-") },
                      "unreadable history must be backed up before the save")
        XCTAssertEqual(store.loadConversations().count, 1)
    }
}
