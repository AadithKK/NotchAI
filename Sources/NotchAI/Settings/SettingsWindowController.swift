import AppKit
import SwiftUI

/// Hosts the SwiftUI Settings window with standard window behavior.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        settingsStore: SettingsStore,
        chat: ChatManager,
        providers: AIProviderRegistry,
        browserManager: @escaping () -> BrowserManager?
    ) {
        let root = SettingsView(
            settingsStore: settingsStore,
            chat: chat,
            providers: providers,
            browserManager: browserManager
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchAI Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
