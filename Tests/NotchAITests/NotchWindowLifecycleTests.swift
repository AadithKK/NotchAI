import AppKit
import XCTest
@testable import NotchAI

@MainActor
final class NotchWindowLifecycleTests: XCTestCase {
    func testDecorativeWindowsAndSleepLifecycle() async throws {
        let suite = "NotchAI.window-life.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(keychain: FakeKeychain(), defaults: defaults)
        settings.settings.hoverBehavior = .none
        settings.settings.animationsEnabled = false
        let chat = ChatManager(store: InMemoryChatStore(), providers: AIProviderRegistry(
            deepSeek: FakeProvider(id: .deepSeek), gemini: FakeProvider(id: .gemini)), selectionDefaults: defaults)
        let controller = IslandWindowController(settingsStore: settings, chatManager: chat,
                                               browserManager: BrowserManager(), actions: IslandActions())
        defer { controller.hide() }
        controller.viewModel.isPinned = true
        controller.viewModel.setState(.expanded)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(controller.contentPanel.isVisible)
        XCTAssertTrue(controller.shoulderPanel.ignoresMouseEvents)
        XCTAssertFalse(controller.shoulderPanel.canBecomeKey)
        XCTAssertTrue(controller.badgePanel.ignoresMouseEvents)
        XCTAssertFalse(controller.badgePanel.canBecomeKey)
        XCTAssertTrue(controller.additionalCaptureWindowNumbers.contains(controller.shoulderWindowNumber))
        XCTAssertTrue(controller.additionalCaptureWindowNumbers.contains(controller.badgeWindowNumber))
        XCTAssertEqual(Set(controller.additionalCaptureWindowNumbers).count, 3)
        XCTAssertEqual(controller.contentPanel.frame.maxY, controller.anchorPanel.frame.minY)

        if controller.viewModel.isNotchDisplay {
            XCTAssertTrue(controller.shoulderPanel.isVisible)
            XCTAssertEqual(controller.shoulderPanel.frame.midX, controller.anchorPanel.frame.midX)
            XCTAssertEqual(controller.anchorPanel.backgroundColor, .black)
        }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(controller.anchorPanel.isVisible)
        XCTAssertFalse(controller.contentPanel.isVisible)
        XCTAssertFalse(controller.shoulderPanel.isVisible)
        XCTAssertFalse(controller.badgePanel.isVisible)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(controller.anchorPanel.isVisible)
        XCTAssertFalse(controller.contentPanel.isVisible)
        XCTAssertFalse(controller.shoulderPanel.isVisible)
        XCTAssertEqual(controller.viewModel.state, .collapsed)
        XCTAssertEqual(controller.anchorPanel.backgroundColor, .clear)
    }
}
