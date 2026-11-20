import AppKit
import SwiftUI

/// A normal window that hosts the same conversation as the island.
@MainActor
final class DetachedChatWindowController: NSWindowController {
    init(chatManager: ChatManager, settingsStore: SettingsStore, actions: IslandActions) {
        let root = ChatView(
            chat: chatManager,
            onCapture: actions.capture,
            onOpenSettings: actions.openSettings,
            onReplaceAttachment: actions.replaceAttachment
        )
        .environmentObject(settingsStore)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(minWidth: 380, minHeight: 460)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchAI Chat"
        window.minSize = NSSize(width: 380, height: 460)
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

/// A normal window that hosts a browser with its own (optionally isolated) WebKit session.
@MainActor
final class DetachedBrowserWindowController: NSWindowController {
    init(browserManager: BrowserManager) {
        let root = BrowserView(manager: browserManager)
            .environmentObject(browserManager)
            .padding(10)
            .frame(minWidth: 480, minHeight: 400)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchAI Browser"
        window.minSize = NSSize(width: 480, height: 400)
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
