import AppKit
import ServiceManagement
import WebKit

/// Owns the app graph: settings, chat, island, windows, status item, hot key and screenshot flow.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private let providers: AIProviderRegistry
    private let chatManager: ChatManager
    private let screenshotService = ScreenshotService.shared
    private let shortcutManager = ShortcutManager()
    private let answerShortcutManager = ShortcutManager(identifier: 2)
    private let watchShortcutManager = ShortcutManager(identifier: 3)
    private let regionWatcher = RegionWatcher()
    private var watchMenuItem: NSMenuItem?
    private var watchRegistered = false
    private var consecutiveWatchFailures = 0

    private var islandController: IslandWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var detachedChatController: DetachedChatWindowController?
    private var detachedBrowserController: DetachedBrowserWindowController?
    private var browserManagerInstance: BrowserManager?
    private var statusItem: NSStatusItem?
    private var captureInFlight = false
    private var lastShortcut: KeyboardShortcut?
    private var lastAnswerShortcut: KeyboardShortcut?
    private var quickAnswerInFlight = false
    private var recordingShortcut = false
    private var shortcutObservers: [NSObjectProtocol] = []

    override init() {
        let store = SettingsStore()
        let registry = AIProviderRegistry(deepSeek: DeepSeekProvider(), gemini: GeminiProvider())
        self.settingsStore = store
        self.providers = registry
        self.chatManager = ChatManager(store: JSONChatStore(), providers: registry)
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        observeShortcutRecording()
        wireChat()
        let actions = makeActions()
        islandController = IslandWindowController(
            settingsStore: settingsStore,
            chatManager: chatManager,
            browserManager: browserManager(),
            actions: actions
        )
        islandController?.onSuspend = { [weak self] in
            guard self?.regionWatcher.isWatching == true else { return }
            self?.stopWatching(toast: nil)
        }
        settingsStore.onSettingsChanged = { [weak self] settings in
            self?.apply(settings: settings)
        }
        apply(settings: settingsStore.settings)
        applyPreviewStateIfRequested()
        installStatusItem()
        Log.app.info("NotchAI launched (agent mode)")
    }

    /// Development aid: launch directly into a state for screenshot/geometry checks.
    private func applyPreviewStateIfRequested() {
        guard let requested = ProcessInfo.processInfo.environment["NOTCHAI_START_STATE"] else { return }
        switch requested {
        case "expanded":
            islandController?.viewModel.isPinned = true
            islandController?.viewModel.setState(.expanded)
        case "full":
            islandController?.viewModel.isPinned = true
            islandController?.viewModel.openFull(section: .chat)
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutManager.unregister()
        answerShortcutManager.unregister()
        watchShortcutManager.unregister()
        regionWatcher.stop()
        chatManager.stop()
        // Capture any partial stream + selection before the process exits.
        chatManager.persistNow()
        chatManager.discardUnsentSessionCaptures()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Chat wiring

    private func wireChat() {
        chatManager.resolveModel = { [weak self] in
            guard let self else { return AIModelCatalog.defaultModel(for: .deepSeek) }
            return self.settingsStore.selectedModel
        }
        chatManager.resolveAPIKey = { [weak self] provider in
            self?.settingsStore.apiKey(for: provider)
        }
    }

    private func browserManager() -> BrowserManager {
        if let browserManagerInstance { return browserManagerInstance }
        let browserSettings = settingsStore.settings.browser
        let manager = BrowserManager(
            searchEngine: browserSettings.searchEngine,
            dataStore: .default(),
            homepage: browserSettings.homepage
        )
        browserManagerInstance = manager
        return manager
    }

    // MARK: - Actions

    private func makeActions() -> IslandActions {
        IslandActions(
            capture: { [weak self] in self?.captureScreen(replacing: nil) },
            replaceAttachment: { [weak self] id in self?.captureScreen(replacing: id) },
            openSettings: { [weak self] in self?.openSettings() },
            detachChat: { [weak self] in self?.detachChat() },
            detachBrowser: { [weak self] in self?.detachBrowser() },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func showIsland(section: IslandSection) {
        guard let islandController else { return }
        islandController.viewModel.openFull(section: section)
        islandController.present()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settingsStore: settingsStore,
                chat: chatManager,
                providers: providers,
                browserManager: { [weak self] in self?.browserManagerInstance }
            )
        }
        settingsWindowController?.present()
    }

    private func detachChat() {
        if let detachedChatController {
            detachedChatController.present()
            return
        }
        let controller = DetachedChatWindowController(
            chatManager: chatManager,
            settingsStore: settingsStore,
            actions: makeActions()
        )
        detachedChatController = controller
        controller.present()
    }

    private func detachBrowser() {
        if let detachedBrowserController {
            detachedBrowserController.present()
            return
        }
        let browserSettings = settingsStore.settings.browser
        let dataStore: WKWebsiteDataStore = browserSettings.detachedWindowUsesSeparateSession
            ? .nonPersistent()
            : .default()
        let manager = BrowserManager(
            searchEngine: browserSettings.searchEngine,
            dataStore: dataStore,
            homepage: browserSettings.homepage
        )
        let controller = DetachedBrowserWindowController(browserManager: manager)
        detachedBrowserController = controller
        controller.present()
    }

    // MARK: - Screenshot flow

    private func captureScreen(replacing attachmentID: UUID?) {
        guard !captureInFlight, !quickAnswerInFlight else { return }
        captureInFlight = true
        Task { @MainActor in
            defer { captureInFlight = false }
            let screenshotSettings = settingsStore.settings.screenshot
            let options = CaptureOptions(
                displayID: screenshotSettings.displayID,
                excludeAllAppWindows: screenshotSettings.excludeAllAppWindows,
                includeCursor: false,
                format: screenshotSettings.format,
                saveLocally: screenshotSettings.saveLocally
            )
            do {
                let islandWindowNumber = islandController?.windowNumber ?? 0
                let additionalWindowNumbers = islandController?.additionalCaptureWindowNumbers ?? []
                let screenshot = try await screenshotService.capture(
                    options: options,
                    islandWindowNumber: islandWindowNumber,
                    additionalWindowNumbers: additionalWindowNumbers
                )
                if screenshotSettings.attachToChat || attachmentID != nil {
                    if let attachmentID {
                        chatManager.replaceAttachment(attachmentID, with: screenshot)
                    } else {
                        chatManager.attach(screenshot)
                    }
                    showIsland(section: .chat)
                    islandController?.viewModel.showToast("Screenshot attached — type a message to send it")
                } else {
                    // Neither attached nor kept: the capture has no owner, so do not leave a full-screen
                    // image on disk.
                    if CaptureDeliveryPolicy.deleteImmediately(
                        attachToChat: screenshotSettings.attachToChat,
                        isReplacement: attachmentID != nil,
                        saveLocally: screenshotSettings.saveLocally
                    ) {
                        try? FileManager.default.removeItem(at: screenshot.fileURL)
                    }
                    islandController?.viewModel.expand()
                    islandController?.viewModel.showToast("Screenshot captured")
                }
            } catch let error as ScreenshotError {
                islandController?.viewModel.expand()
                islandController?.viewModel.showToast(error.localizedDescription)
                if error == .permissionDenied {
                    openScreenRecordingSettings()
                }
            } catch {
                islandController?.viewModel.expand()
                islandController?.viewModel.showToast(error.localizedDescription)
            }
        }
    }

    private var composerIsAvailableForQuickAnswer: Bool {
        !chatManager.isPreparingSend && !chatManager.isStreaming
            && chatManager.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chatManager.pendingAttachments.isEmpty && chatManager.pendingDocuments.isEmpty
    }

    private enum QuickAnswerOutcome { case answered, skipped, failed }

    /// An explicit shortcut press authorizes this one screenshot upload, to the selected model.
    /// All captures share one "Quick Answers" chat; each request sends only its own screenshot.
    private func captureAndAnswer() {
        let mode = settingsStore.settings.screenshot.effectiveAnswerMode
        Task { @MainActor in _ = await runQuickAnswer(region: nil, mode: mode, quiet: false) }
    }

    /// Shared by the shortcut (whole display) and Watch Region (a chosen rectangle, `quiet`: a busy
    /// composer skips that change silently instead of opening the island with an error).
    private func runQuickAnswer(region: WatchTarget?, mode: AnswerMode, quiet: Bool) async -> QuickAnswerOutcome {
        guard !quickAnswerInFlight, !captureInFlight else { return .skipped }
        guard composerIsAvailableForQuickAnswer else {
            if !quiet {
                showQuickAnswerError("Finish the current reply or clear your draft and attachments before using Capture & Answer.")
            }
            return .skipped
        }
        let model = settingsStore.selectedModel
        guard model.supportsImages else {
            showQuickAnswerError("Select an image-capable model before using Capture & Answer.")
            return .failed
        }
        guard let key = settingsStore.apiKey(for: model.provider), !key.isEmpty else {
            showQuickAnswerError("Add your \(model.provider.displayName) API key in Settings first.")
            return .failed
        }
        quickAnswerInFlight = true
        defer { quickAnswerInFlight = false }
        islandController?.showAnswerProgress("Capturing…")
        let captureSettings = settingsStore.settings.screenshot
        do {
            let screenshot = try await screenshotService.capture(
                options: CaptureOptions(
                    displayID: region?.displayID ?? captureSettings.displayID,
                    excludeAllAppWindows: region != nil || captureSettings.excludeAllAppWindows,
                    includeCursor: false,
                    format: captureSettings.format,
                    saveLocally: captureSettings.saveLocally,
                    sourceRect: region?.rect
                ),
                islandWindowNumber: islandController?.windowNumber ?? 0,
                additionalWindowNumbers: islandController?.additionalCaptureWindowNumbers ?? []
            )
            let currentModel = settingsStore.selectedModel
            guard composerIsAvailableForQuickAnswer,
                  currentModel.id == model.id, currentModel.provider == model.provider else {
                if AttachmentSanitizer.isStrictlyInside(AppPaths.temporaryCapturesDirectory, screenshot.fileURL) {
                    try? FileManager.default.removeItem(at: screenshot.fileURL)
                }
                if quiet {
                    islandController?.hideAnswerProgress()
                } else {
                    showQuickAnswerError("Chat or model changed during capture. Nothing was sent; press the shortcut again when ready.")
                }
                return .skipped
            }
            chatManager.selectQuickAnswerConversation()
            let answerConversationID = chatManager.selectedConversationID
            chatManager.attach(screenshot)
            let previousCompletion = chatManager.completionPulse
            islandController?.showAnswerProgress("Thinking…")
            chatManager.send(text: mode.prompt)
            while chatManager.isPreparingSend || chatManager.isStreaming {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard chatManager.selectedConversationID == answerConversationID else {
                    islandController?.hideAnswerProgress()
                    return .skipped
                }
            }
            guard chatManager.selectedConversationID == answerConversationID else {
                islandController?.hideAnswerProgress()
                return .skipped
            }
            let completed = chatManager.completionPulse != previousCompletion
            let reply = chatManager.currentConversation.messages.last(where: { $0.role == .assistant && !$0.isError })?.text ?? ""
            if completed, mode != .frq, let letter = AnswerLetterParser.letter(in: reply) {
                // Multiple choice: just show the letter at the notch; the island stays closed.
                islandController?.showAnswerLetter(letter)
                return .answered
            }
            // Long answer: pop the full chat open, then return to normal after 20 idle seconds.
            islandController?.beginAnswerPopup()
            showIsland(section: .chat)
            if !completed {
                islandController?.hideAnswerProgress()
                if chatManager.errorMessage == nil {
                    islandController?.viewModel.showToast("Answer stopped before completion.")
                }
                return .failed
            }
            return .answered
        } catch {
            showQuickAnswerError(error.localizedDescription)
            if let captureError = error as? ScreenshotError, captureError == .permissionDenied {
                openScreenRecordingSettings()
            }
            return .failed
        }
    }

    // MARK: - Watch Region

    /// One shortcut: pick a region, then every time it changes and settles it is captured and answered.
    /// Starting is the consent; it keeps sending until stopped (same shortcut, menu, sleep or quit).
    private func toggleWatch() {
        if regionWatcher.isWatching {
            stopWatching(toast: "Stopped watching.")
            return
        }
        guard !quickAnswerInFlight, !captureInFlight else { return }
        guard screenshotService.hasScreenRecordingPermission() else {
            _ = screenshotService.requestScreenRecordingPermission()
            showWatchToast("Allow Screen Recording for NotchAI, then try again.")
            return
        }
        let model = settingsStore.selectedModel
        guard model.supportsImages else {
            showWatchToast("Select an image-capable model before using Watch Region.")
            return
        }
        guard let key = settingsStore.apiKey(for: model.provider), !key.isEmpty else {
            showWatchToast("Add your \(model.provider.displayName) API key in Settings first.")
            return
        }
        Task { @MainActor in await beginWatching() }
    }

    private func beginWatching() async {
        let startMode = settingsStore.settings.screenshot.effectiveAnswerMode
        guard let picked = await RegionPicker.pick(mode: startMode) else { return }
        guard let number = picked.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let target = WatchTarget(
            displayID: number.uint32Value,
            rect: RegionGeometry.displayLocal(rect: picked.rect, screenFrame: picked.screen.frame),
            mode: picked.mode
        )
        do {
            let filter = try await screenshotService.makeWatchFilter(
                displayID: target.displayID,
                islandWindowNumber: islandController?.windowNumber ?? 0,
                additionalWindowNumbers: islandController?.additionalCaptureWindowNumbers ?? []
            )
            consecutiveWatchFailures = 0
            regionWatcher.start(
                target: target,
                filter: filter,
                watchedPID: picked.previousApp?.processIdentifier ?? 0,
                isBusy: { [weak self] in
                    guard let self else { return true }
                    return self.quickAnswerInFlight || self.captureInFlight
                },
                onChange: { [weak self] in
                    guard let self else { return }
                    switch await self.runQuickAnswer(region: target, mode: target.mode, quiet: true) {
                    case .answered: self.consecutiveWatchFailures = 0
                    case .skipped: break
                    case .failed:
                        self.consecutiveWatchFailures += 1
                        if self.consecutiveWatchFailures >= 3 {
                            self.stopWatching(toast: "Stopped watching after repeated errors.")
                        }
                    }
                },
                onError: { [weak self] error in
                    self?.stopWatching(toast: "Stopped watching: \(error.localizedDescription)")
                }
            )
            islandController?.setWatchBadge("Watch · \(target.mode.title)")
            watchMenuItem?.title = "Stop Watching"
            showWatchToast("Watching for changes (\(target.mode.title)). Press ⌃⌥⌘6 to stop.")
        } catch {
            showWatchToast(error.localizedDescription)
        }
    }

    private func stopWatching(toast: String?) {
        regionWatcher.stop()
        islandController?.setWatchBadge(nil)
        watchMenuItem?.title = "Watch Region…"
        if let toast { showWatchToast(toast) }
    }

    private func showWatchToast(_ message: String) {
        islandController?.viewModel.expand()
        islandController?.viewModel.showToast(message)
    }

    @objc private func toggleWatchAction() { toggleWatch() }

    private func showQuickAnswerError(_ message: String) {
        islandController?.hideAnswerProgress()
        chatManager.errorMessage = message
        islandController?.viewModel.isPinned = true
        showIsland(section: .chat)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Settings side effects

    private func apply(settings: AppSettings) {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        applyAppearance(settings.appearance)
        applyLaunchAtLogin(settings.launchAtLogin)
        browserManagerInstance?.searchEngine = settings.browser.searchEngine
        browserManagerInstance?.homepage = settings.browser.homepage
        registerShortcutsIfNeeded(settings.screenshot)
        islandController?.reposition()
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            Log.app.error("launch-at-login update failed: \(error.localizedDescription)")
        }
    }

    private func observeShortcutRecording() {
        let center = NotificationCenter.default
        shortcutObservers.append(center.addObserver(forName: .notchAIShortcutRecordingBegan, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingShortcut = true
                self.shortcutManager.unregister()
                self.answerShortcutManager.unregister()
                self.watchShortcutManager.unregister()
                self.watchRegistered = false
                self.lastShortcut = nil
                self.lastAnswerShortcut = nil
            }
        })
        shortcutObservers.append(center.addObserver(forName: .notchAIShortcutRecordingEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingShortcut = false
                self.registerShortcutsIfNeeded(self.settingsStore.settings.screenshot)
            }
        })
    }

    private func registerShortcutsIfNeeded(_ settings: ScreenshotSettings) {
        guard !recordingShortcut else { return }
        if !watchRegistered {
            watchRegistered = (try? watchShortcutManager.register(.defaultWatch) { [weak self] in
                self?.toggleWatch()
            }) != nil
        }
        let answer = settings.isAnswerShortcutEnabled ? settings.effectiveAnswerShortcut : nil
        guard lastShortcut != settings.shortcut || lastAnswerShortcut != answer else { return }
        shortcutManager.unregister()
        answerShortcutManager.unregister()
        lastShortcut = nil
        lastAnswerShortcut = nil
        do {
            try shortcutManager.register(settings.shortcut) { [weak self] in
                self?.captureScreen(replacing: nil)
            }
            lastShortcut = settings.shortcut
            if let answer {
                guard answer != settings.shortcut else {
                    islandController?.viewModel.showToast("Capture & Answer needs a different shortcut from Capture.")
                    return
                }
                try answerShortcutManager.register(answer) { [weak self] in
                    self?.captureAndAnswer()
                }
                lastAnswerShortcut = answer
            }
        } catch {
            islandController?.viewModel.expand()
            islandController?.viewModel.showToast(error.localizedDescription)
            Log.app.error("shortcut registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Status item and menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "NotchAI")
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "NotchAI")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NotchAI"
        }
        let menu = NSMenu()
        addItem(to: menu, title: "Open NotchAI", action: #selector(openIslandChatAction))
        addItem(to: menu, title: "Capture Screen", action: #selector(captureFromMenuAction))
        addItem(to: menu, title: "Watch Region…", action: #selector(toggleWatchAction))
        watchMenuItem = menu.items.last
        menu.addItem(.separator())
        addItem(to: menu, title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        // Editing menu keeps standard ⌘C/⌘V/⌘A working in the chat composer and browser address bar.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        for (title, selector, key) in [
            ("Undo", "undo:", "z"),
            ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a"),
        ] {
            let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            item.target = nil
            editMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    @objc private func openIslandChatAction() {
        showIsland(section: .chat)
    }

    @objc private func captureFromMenuAction() {
        captureScreen(replacing: nil)
    }

    @objc private func openSettingsAction() {
        openSettings()
    }
}
