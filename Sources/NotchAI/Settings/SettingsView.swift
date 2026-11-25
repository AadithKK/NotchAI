import AppKit
import ServiceManagement
import SwiftUI

/// Native Settings window with General, AI Providers, Screenshots, Browser and Privacy sections.
struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var chat: ChatManager
    let providers: AIProviderRegistry
    let browserManager: () -> BrowserManager?

    var body: some View {
        TabView {
            GeneralSettingsView(settingsStore: settingsStore)
                .tabItem { Label("General", systemImage: "gearshape") }
            AIProviderSettingsView(settingsStore: settingsStore, providers: providers)
                .tabItem { Label("AI Providers", systemImage: "brain") }
            ScreenshotSettingsView(settingsStore: settingsStore)
                .tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }
            BrowserSettingsView(settingsStore: settingsStore, browserManager: browserManager)
                .tabItem { Label("Browser", systemImage: "globe") }
            PrivacySettingsView(settingsStore: settingsStore, chat: chat)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 700, height: 560)
        .padding(.top, 8)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch NotchAI at login", isOn: $settingsStore.settings.launchAtLogin)
                Toggle("Show Dock icon", isOn: $settingsStore.settings.showDockIcon)
                Text("NotchAI runs as a menu-bar agent with a floating island so it stays available without a main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Island") {
                Picker("Hover behavior", selection: $settingsStore.settings.hoverBehavior) {
                    ForEach(HoverBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                Picker("Place island on", selection: $settingsStore.settings.islandScreen) {
                    ForEach(IslandScreenChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Toggle("Animations", isOn: $settingsStore.settings.animationsEnabled)
            }
            Section("Appearance") {
                Picker("Theme", selection: $settingsStore.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Controls and panels follow this appearance; the notch anchor stays black.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Providers

private struct AIProviderSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let providers: AIProviderRegistry

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: Binding(
                    get: { settingsStore.selectedModel },
                    set: { settingsStore.select(model: $0) }
                )) {
                    ForEach(AIProviderID.allCases) { provider in
                        Section(provider.displayName) {
                            ForEach(settingsStore.models(for: provider)) { model in
                                Text(model.label).tag(model)
                            }
                        }
                    }
                }
                Text("Screenshots are only sent to models that document image input. Unsupported models are never substituted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(AIProviderID.allCases) { provider in
                Section(provider.displayName) {
                    ProviderCredentialRow(provider: provider, settingsStore: settingsStore, providers: providers)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderCredentialRow: View {
    let provider: AIProviderID
    @ObservedObject var settingsStore: SettingsStore
    let providers: AIProviderRegistry

    @State private var keyField = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(settingsStore.keyPresence[provider] == true ? "Key stored in Keychain — paste to replace" : "Paste \(provider.displayName) API key", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") { remove() }
                    .disabled(settingsStore.keyPresence[provider] != true)
            }

            HStack(spacing: 10) {
                Label(
                    settingsStore.keyPresence[provider] == true ? "Stored in macOS Keychain" : "No key stored",
                    systemImage: settingsStore.keyPresence[provider] == true ? "checkmark.seal.fill" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(settingsStore.keyPresence[provider] == true ? Color.green : Color.secondary)

                Button(testState == .testing ? "Testing…" : "Test connection") { test() }
                    .disabled(testState == .testing)

                Button("Refresh models") { refreshModels() }
                    .disabled(testState == .testing)

                Spacer()

                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
                case let .failure(message):
                    Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }
            .font(.caption)

            if let error = settingsStore.credentialError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(settingsStore.models(for: provider)) { model in
                    HStack(spacing: 6) {
                        Image(systemName: model.supportsImages ? "photo" : "text.alignleft")
                            .font(.system(size: 9))
                            .foregroundStyle(model.supportsImages ? Color.accentColor : Color.secondary)
                        Text(model.id).font(.system(size: 11, design: .monospaced))
                        Text(model.note ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        do {
            try settingsStore.saveAPIKey(keyField, for: provider)
            keyField = ""
            testState = .idle
        } catch {
            settingsStore.credentialError = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try settingsStore.removeAPIKey(for: provider)
            testState = .idle
        } catch {
            settingsStore.credentialError = error.localizedDescription
        }
    }

    private func effectiveKey() -> String? {
        let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return settingsStore.apiKey(for: provider)
    }

    private func test() {
        guard let key = effectiveKey(), !key.isEmpty else {
            testState = .failure("Add a key first")
            return
        }
        testState = .testing
        Task {
            do {
                let models = try await providers.provider(for: provider).availableModels(apiKey: key)
                settingsStore.setDiscoveredModels(models, for: provider)
                testState = .success("Connected · \(models.count) models")
            } catch {
                testState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func refreshModels() {
        guard let key = effectiveKey(), !key.isEmpty else {
            testState = .failure("Add a key first")
            return
        }
        testState = .testing
        Task {
            do {
                let models = try await providers.provider(for: provider).availableModels(apiKey: key)
                settingsStore.setDiscoveredModels(models, for: provider)
                testState = .success("\(models.count) models available")
            } catch {
                testState = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

// MARK: - Screenshots

private struct ScreenshotSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var displays: [DisplayCatalogEntry] = DisplayCatalog.displays()
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Display", selection: Binding(
                    get: { settingsStore.settings.screenshot.displayID },
                    set: { settingsStore.settings.screenshot.displayID = $0 }
                )) {
                    Text("Main display").tag(UInt32?.none)
                    ForEach(displays) { display in
                        Text("\(display.name) — \(display.pixelWidth)×\(display.pixelHeight)")
                            .tag(Optional(display.id))
                    }
                }
                Picker("Format", selection: $settingsStore.settings.screenshot.format) {
                    ForEach(ScreenshotFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Toggle("Attach capture to the current chat", isOn: $settingsStore.settings.screenshot.attachToChat)
                Toggle("Exclude other NotchAI windows (detached browser/chat)", isOn: $settingsStore.settings.screenshot.excludeAllAppWindows)
                Toggle("Keep a copy on disk", isOn: $settingsStore.settings.screenshot.saveLocally)
                Text("The island panel is always excluded from captures with ScreenCaptureKit's window filter, so the desktop behind it is captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                HStack {
                    Text("Global capture shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: $settingsStore.settings.screenshot.shortcut)
                }
                Text("Works even when the island is collapsed. Default is ⌃⌥⌘4.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Capture & Answer") {
                Toggle("Enable Capture & Answer shortcut", isOn: Binding(
                    get: { settingsStore.settings.screenshot.isAnswerShortcutEnabled },
                    set: { settingsStore.settings.screenshot.answerShortcutEnabled = $0 }
                ))
                HStack {
                    Text("Capture & Answer shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { settingsStore.settings.screenshot.effectiveAnswerShortcut },
                        set: { settingsStore.settings.screenshot.answerShortcut = $0 }
                    ))
                }
                .disabled(!settingsStore.settings.screenshot.isAnswerShortcutEnabled)
                Text("Pressing this shortcut immediately sends the selected display to your selected AI model for an answer. Default: ⌃⌥⌘5. Multiple-choice questions show just the answer letter beside the notch for 3 seconds. Longer answers open in chat and close again after 20 seconds without use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settingsStore.settings.screenshot.effectiveAnswerShortcut == settingsStore.settings.screenshot.shortcut {
                    Text("Choose different shortcuts for Capture and Capture & Answer.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Question mode & Watch Region") {
                Picker("Question type", selection: Binding(
                    get: { settingsStore.settings.screenshot.effectiveAnswerMode },
                    set: { settingsStore.settings.screenshot.answerMode = $0 }
                )) {
                    Text("Auto").tag(AnswerMode.auto)
                    Text("MCQ").tag(AnswerMode.mcq)
                    Text("FRQ").tag(AnswerMode.frq)
                }
                .pickerStyle(.segmented)
                Text("MCQ shows only the answer letter beside the notch. FRQ always opens a full written answer. Auto picks for you.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Watch Region (⌃⌥⌘6 or jj): the first time, your screen freezes and you drag a box around the question area. From then on, whenever that box changes and settles, NotchAI captures just it and answers, until you press the shortcut again. Press it once more to resume the same box; menu bar → Choose New Watch Region… picks a different one. Starting it is your permission to send those captures to your selected AI model; each one is billed to your API key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Double-tap keys") {
                Toggle("Fast double-tap: hh = answer, jj = Watch Region on/off", isOn: Binding(
                    get: { settingsStore.settings.screenshot.isDoubleTapEnabled },
                    set: { settingsStore.settings.screenshot.doubleTapKeysEnabled = $0 }
                ))
                Text("Press the letter twice very fast (under a quarter second) after a short pause. Typing slower, or inside words like “ahh”, does nothing. Needs Input Monitoring: NotchAI only compares those two letters and never records or sends what you type. The letters are still typed into the app in front, so use it where that is harmless. If it does nothing after you allow the permission, quit and reopen NotchAI.")
                    .font(.caption).foregroundStyle(.secondary)
                if settingsStore.settings.screenshot.isDoubleTapEnabled && !DoubleTapMonitor.hasPermission {
                    Text("Input Monitoring is not allowed yet. Open System Settings → Privacy & Security → Input Monitoring and enable NotchAI.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Screen Recording permission") {
                HStack(spacing: 10) {
                    Label(
                        hasPermission ? "Permission granted" : "Permission required to capture",
                        systemImage: hasPermission ? "checkmark.seal.fill" : "lock.fill"
                    )
                    .foregroundStyle(hasPermission ? Color.green : Color.orange)
                    Spacer()
                    Button("Request access") {
                        _ = CGRequestScreenCaptureAccess()
                        hasPermission = CGPreflightScreenCaptureAccess()
                    }
                    Button("Open System Settings") { openScreenRecordingSettings() }
                }
                Text("macOS requires Screen Recording approval once. If you rebuilt the app, macOS may ask again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            displays = DisplayCatalog.displays()
            hasPermission = CGPreflightScreenCaptureAccess()
        }
    }

    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut.displayString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 66, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
            Button(isRecording ? "Press keys… (Esc to cancel)" : "Record") {
                if isRecording { stop() } else { start() }
            }
            .disabled(isRecording)
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        NotificationCenter.default.post(name: .notchAIShortcutRecordingBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let modifiers = carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return nil }
            shortcut = KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        NotificationCenter.default.post(name: .notchAIShortcutRecordingEnded, object: nil)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyboardShortcut.commandModifier }
        if flags.contains(.shift) { modifiers |= KeyboardShortcut.shiftModifier }
        if flags.contains(.option) { modifiers |= KeyboardShortcut.optionModifier }
        if flags.contains(.control) { modifiers |= KeyboardShortcut.controlModifier }
        return modifiers
    }
}

// MARK: - Browser

private struct BrowserSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let browserManager: () -> BrowserManager?

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search engine", selection: $settingsStore.settings.browser.searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                TextField("Homepage", text: $settingsStore.settings.browser.homepage)
            }
            Section("Windows") {
                Toggle(
                    "Detached browser window uses a separate session",
                    isOn: $settingsStore.settings.browser.detachedWindowUsesSeparateSession
                )
                Text("Separate sessions keep cookies and sign-ins isolated from the in-island browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                HStack(spacing: 8) {
                    Button("Clear history") { browserManager()?.clearHistory() }
                    Button("Clear browsing data") {
                        Task { await browserManager()?.clearBrowsingData() }
                    }
                    Spacer()
                }
                Text("Clearing browsing data removes cookies, caches and local storage from every browser tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("WebKit privacy protections stay at their platform defaults. NotchAI adds no tracking and no proxy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var chat: ChatManager
    @State private var pendingAction: DestructiveAction?
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    private enum DestructiveAction: String, Identifiable {
        case clearChat
        case deleteScreenshots
        case removeCredentials
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Local data") {
                HStack {
                    Text("Conversations and screenshots are stored only in ~/Library/Application Support/NotchAI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Clear chat history", role: .destructive) { pendingAction = .clearChat }
                Button("Delete stored screenshot files", role: .destructive) { pendingAction = .deleteScreenshots }
                Button("Remove saved API credentials", role: .destructive) { pendingAction = .removeCredentials }
            }
            Section("Permissions") {
                HStack {
                    Label(
                        screenRecordingGranted ? "Screen Recording allowed" : "Screen Recording not granted",
                        systemImage: screenRecordingGranted ? "checkmark.seal.fill" : "lock.fill"
                    )
                    .foregroundStyle(screenRecordingGranted ? Color.green : Color.orange)
                    Spacer()
                    Button("Review") { openScreenRecordingSettings() }
                }
                HStack {
                    Label(loginItemLabel, systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Button("Review") { openLoginItemsSettings() }
                }
                Button("Refresh permission status") { screenRecordingGranted = CGPreflightScreenCaptureAccess() }
            }
            Section("About") {
                HStack {
                    BrandMark(size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NotchAI").font(.headline)
                        Text("Native macOS Dynamic Island assistant · \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button(confirmationButtonTitle(for: action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { _ in
            Text(confirmationMessage)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        return "v\(version)"
    }

    private var loginItemLabel: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Launch at login is enabled"
        case .requiresApproval: return "Launch at login needs approval"
        case .notRegistered: return "Launch at login is off"
        case .notFound: return "Launch at login unavailable in this build"
        @unknown default: return "Launch at login status unknown"
        }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .clearChat: return "Clear all chat history?"
        case .deleteScreenshots: return "Delete all stored screenshots?"
        case .removeCredentials: return "Remove saved API credentials?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch pendingAction {
        case .clearChat: return "Every conversation in NotchAI will be removed from this Mac."
        case .deleteScreenshots: return "Screenshot files captured by NotchAI will be deleted from disk."
        case .removeCredentials: return "The DeepSeek and Gemini keys will be removed from the macOS Keychain."
        case nil: return ""
        }
    }

    private func confirmationButtonTitle(for action: DestructiveAction) -> String {
        switch action {
        case .clearChat: return "Clear history"
        case .deleteScreenshots: return "Delete screenshots"
        case .removeCredentials: return "Remove credentials"
        }
    }

    private func perform(_ action: DestructiveAction) {
        switch action {
        case .clearChat:
            chat.clearAllHistory()
        case .deleteScreenshots:
            for directory in [AppPaths.screenshotsDirectory, AppPaths.temporaryCapturesDirectory] {
                if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    for url in contents { try? FileManager.default.removeItem(at: url) }
                }
            }
        case .removeCredentials:
            try? settingsStore.removeAllCredentials()
        }
        pendingAction = nil
    }

    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    private func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        if let url { NSWorkspace.shared.open(url) }
    }
}
