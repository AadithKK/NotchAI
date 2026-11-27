import AppKit
import Combine
import SwiftUI

/// Closures the island UI can invoke; owned by the app delegate so views stay free of app wiring.
struct IslandActions {
    var capture: () -> Void = {}
    var replaceAttachment: (UUID) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var detachChat: () -> Void = {}
    var detachBrowser: () -> Void = {}
    var quit: () -> Void = {}
}

final class IslandPanel: NSPanel {
    var acceptsKeyFocus = true
    override var canBecomeKey: Bool { acceptsKeyFocus }
    override var canBecomeMain: Bool { false }

    /// The anchor sits on the notch; do not let AppKit clamp it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class IslandHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch anchor and content panel, plus click-through shoulder and status windows.
/// Interactive content begins below the menu bar; decorative shoulders cannot consume clicks.
///
/// Hover is resolved from the global cursor position because the hardware notch cutout receives no
/// mouse events. That also gives reliable open and auto-close behavior over the cutout itself.
@MainActor
final class IslandWindowController {
    let viewModel = IslandViewModel()
    private(set) var anchorPanel: IslandPanel
    private(set) var contentPanel: IslandPanel
    private(set) var badgePanel: IslandPanel
    private(set) var shoulderPanel: IslandPanel

    private let settingsStore: SettingsStore
    private let chatManager: ChatManager
    private let browserManager: BrowserManager
    private let actions: IslandActions
    private var observers: [NSObjectProtocol] = []
    private var hoverTimer: Timer?
    private var cachedMetrics: ScreenMetrics
    private var lastKeyboardInteraction = Date.distantPast
    private var inputMonitor: Any?
    private var menuTrackingDepth = 0
    private var isSuspended = false
    private var requiresPointerExit = false
    private var outsideSince: Date?
    private var dwellTracker = HoverDwellTracker()
    private var badgeHideWork: DispatchWorkItem?
    private var completionCancellable: AnyCancellable?
    private var badgeGeneration = 0
    /// While set, the answer popup closes once the pointer and keyboard have been idle until this time.
    private var answerPopupDeadline: Date?
    /// Persistent "Watch · MCQ" label shown beside the notch while Watch Region is armed.
    private var watchLabel: String?
    var onSuspend: (() -> Void)?
    nonisolated static let answerPopupIdleTimeout: TimeInterval = 2

    var windowNumber: CGWindowID { CGWindowID(anchorPanel.windowNumber) }
    var contentWindowNumber: CGWindowID { CGWindowID(contentPanel.windowNumber) }
    var additionalCaptureWindowNumbers: [CGWindowID] {
        [contentWindowNumber, badgeWindowNumber, shoulderWindowNumber].filter { $0 != 0 }
    }
    var shoulderWindowNumber: CGWindowID { CGWindowID(shoulderPanel.windowNumber) }
    var badgeWindowNumber: CGWindowID { CGWindowID(badgePanel.windowNumber) }

    init(
        settingsStore: SettingsStore,
        chatManager: ChatManager,
        browserManager: BrowserManager,
        actions: IslandActions
    ) {
        self.settingsStore = settingsStore
        self.chatManager = chatManager
        self.browserManager = browserManager
        self.actions = actions

        let metrics = Self.metrics(for: settingsStore.settings.islandScreen)
        self.cachedMetrics = metrics
        let pill = IslandGeometry.pillSize(for: metrics)
        if viewModel.isNotchDisplay != metrics.hasNotch { viewModel.isNotchDisplay = metrics.hasNotch }
        if viewModel.pillWidth != pill.width { viewModel.pillWidth = pill.width }
        if viewModel.pillHeight != pill.height { viewModel.pillHeight = pill.height }

        let anchorFrame = IslandGeometry.anchorFrame(for: metrics)
        let initialContentFrame = IslandGeometry.contentFrame(for: .expanded, screen: metrics) ?? anchorFrame
        self.anchorPanel = Self.makePanel(frame: anchorFrame)
        self.contentPanel = Self.makePanel(frame: initialContentFrame)
        self.badgePanel = Self.makePanel(frame: CGRect(origin: .zero, size: IslandGeometry.badgeSize))
        self.shoulderPanel = Self.makePanel(frame: IslandGeometry.shoulderFrame(for: metrics) ?? anchorFrame)
        shoulderPanel.ignoresMouseEvents = true
        shoulderPanel.acceptsKeyFocus = false
        shoulderPanel.setAccessibilityElement(false)
        shoulderPanel.contentView = NSHostingView(rootView: NotchShoulderShape().fill(Color.black).accessibilityHidden(true))
        shoulderPanel.orderOut(nil)

        anchorPanel.contentView = NSHostingView(rootView: IslandAnchorView(viewModel: viewModel))

        let contentRoot = AnyView(
            IslandContentView(viewModel: viewModel, actions: actions)
                .environmentObject(settingsStore)
                .environmentObject(chatManager)
                .environmentObject(browserManager)
        )
        contentPanel.title = "NotchAI"
        contentPanel.contentView = IslandHostingView(rootView: contentRoot)
        contentPanel.alphaValue = 1
        contentPanel.orderOut(nil)

        badgePanel.ignoresMouseEvents = true
        badgePanel.acceptsKeyFocus = false
        badgePanel.contentView = NSHostingView(rootView: IslandCompletionBadge())
        badgePanel.orderOut(nil)

        anchorPanel.orderFrontRegardless()

        viewModel.onLayoutChange = { [weak self] state in
            self?.applyLayout(state: state, animated: true)
        }
        viewModel.onActivationChange = { [weak self] active in
            self?.setFullInteraction(active)
        }

        startHoverMonitor()
        observeScreenChanges()
        observeInteraction()

        completionCancellable = chatManager.$completionPulse
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.showCompletionBadge() }
            }
    }

    deinit {
        completionCancellable?.cancel()
        hoverTimer?.invalidate()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: - Placement

    func present() {
        anchorPanel.orderFrontRegardless()
        if viewModel.state != .collapsed {
            applyLayout(state: viewModel.state, animated: false)
        }
    }

    func hide() {
        anchorPanel.orderOut(nil)
        shoulderPanel.orderOut(nil)
        contentPanel.orderOut(nil)
        badgePanel.orderOut(nil)
    }

    func reposition(animated: Bool = true) {
        applyLayout(state: viewModel.state, animated: animated)
    }

    private func applyLayout(state: IslandState, animated: Bool) {
        guard !isSuspended else { return }
        let metrics = Self.metrics(for: settingsStore.settings.islandScreen)
        cachedMetrics = metrics
        let pill = IslandGeometry.pillSize(for: metrics)
        if viewModel.isNotchDisplay != metrics.hasNotch { viewModel.isNotchDisplay = metrics.hasNotch }
        if viewModel.pillWidth != pill.width { viewModel.pillWidth = pill.width }
        if viewModel.pillHeight != pill.height { viewModel.pillHeight = pill.height }

        let anchorFrame = IslandGeometry.anchorFrame(for: metrics)
        if anchorPanel.frame != anchorFrame { anchorPanel.setFrame(anchorFrame, display: true) }
        anchorPanel.orderFrontRegardless()
        if badgePanel.isVisible {
            badgePanel.setFrame(IslandGeometry.badgeFrame(for: metrics), display: true)
        }

        // Fill the housing's corner cutouts immediately at the AppKit layer, too, so a delayed
        // SwiftUI redraw cannot expose the old rounded edge for one frame during opening.
        anchorPanel.backgroundColor = state == .collapsed || !metrics.hasNotch ? .clear : .black
        if state == .collapsed {
            shoulderPanel.orderOut(nil)
            requiresPointerExit = IslandGeometry.hoverRegion(for: metrics).contains(NSEvent.mouseLocation)
            outsideSince = nil
            dwellTracker.reset()
            hideContentPanel(animated: animated)
        } else if let frame = IslandGeometry.contentFrame(for: state, screen: metrics) {
            if let shoulders = IslandGeometry.shoulderFrame(for: metrics) {
                shoulderPanel.setFrame(shoulders, display: true)
                shoulderPanel.orderFrontRegardless()
            } else {
                shoulderPanel.orderOut(nil)
            }
            // Order interactive content last; decoration must not become the apparent front window.
            showContentPanel(frame: frame, animated: animated)
        }
        Log.island.info(
            "island \(state.rawValue, privacy: .public) anchor=\(NSStringFromRect(self.anchorPanel.frame), privacy: .public) content=\(NSStringFromRect(self.contentPanel.frame), privacy: .public)"
        )
    }

    private func showContentPanel(frame: CGRect, animated: Bool) {
        let wasHidden = !contentPanel.isVisible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animationsEnabled = settingsStore.settings.animationsEnabled && !reduceMotion

        contentPanel.alphaValue = 1
        let resized = !wasHidden && contentPanel.frame.size != frame.size
        if wasHidden || resized {
            // Grow from the notch on open, or from the previous panel when switching expanded/full.
            // Reset without animation before the frame changes so no fully-revealed frame flashes.
            let previous = contentPanel.frame.size
            viewModel.revealFrom = wasHidden
                ? CGSize(width: viewModel.pillWidth + 2 * IslandGeometry.shoulderRadius, height: 4)
                : CGSize(width: min(previous.width, frame.width), height: min(previous.height, frame.height))
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) { viewModel.contentRevealed = false }
            contentPanel.setFrame(frame, display: false)
            contentPanel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.contentPanel.isVisible else { return }
                withAnimation(animationsEnabled ? IslandDesign.reveal : nil) {
                    self.viewModel.contentRevealed = true
                }
            }
        } else {
            if contentPanel.frame != frame { contentPanel.setFrame(frame, display: true) }
            contentPanel.orderFrontRegardless()
        }
    }

    private func hideContentPanel(animated: Bool) {
        // Requested behavior: close immediately when the pointer leaves, no lingering overlay.
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { viewModel.contentRevealed = false }
        contentPanel.orderOut(nil)
        contentPanel.alphaValue = 1
    }

    func showAnswerProgress(_ label: String) {
        guard !isSuspended else { return }
        badgeGeneration += 1
        badgeHideWork?.cancel()
        badgePanel.setFrame(IslandGeometry.badgeFrame(for: cachedMetrics), display: false)
        badgePanel.contentView = NSHostingView(rootView: IslandCompletionBadge(label: label))
        badgePanel.alphaValue = 1
        badgePanel.orderFrontRegardless()
    }

    func hideAnswerProgress() {
        badgeGeneration += 1
        badgeHideWork?.cancel()
        badgePanel.orderOut(nil)
        badgePanel.alphaValue = 1
        restoreWatchBadge()
    }

    func setWatchBadge(_ label: String?) {
        watchLabel = label
        if let label { showAnswerProgress(label) } else { hideAnswerProgress() }
    }

    private func restoreWatchBadge() {
        if let watchLabel { showAnswerProgress(watchLabel) }
    }

    /// Shows a multiple-choice answer letter beside the notch without opening the island.
    func showAnswerLetter(_ letter: String, visibleFor seconds: TimeInterval = 3) {
        guard !isSuspended else { return }
        showAnswerProgress(letter)
        badgePanel.contentView = NSHostingView(rootView: IslandCompletionBadge(label: letter, prominent: true))
        scheduleBadgeFade(after: seconds)
    }

    /// Keeps the full chat open for a long answer, then returns the island to normal after
    /// `answerPopupIdleTimeout` seconds without the pointer over it or any typing.
    /// Call before opening the island: the popup never pins and never takes focus from the user's app.
    func beginAnswerPopup() {
        viewModel.isPinned = false
        answerPopupDeadline = Date().addingTimeInterval(Self.answerPopupIdleTimeout)
    }

    private func showCompletionBadge() {
        showAnswerProgress("Answered")
        scheduleBadgeFade(after: 1.0)
    }

    private func scheduleBadgeFade(after delay: TimeInterval) {
        let generation = badgeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.badgeGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                self.badgePanel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.badgeGeneration == generation else { return }
                    self.badgePanel.orderOut(nil)
                    self.badgePanel.alphaValue = 1
                    self.restoreWatchBadge()
                }
            }
        }
        badgeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Only the full chat/browser takes keyboard focus; hover-expanded quick actions must not steal the
    /// user's current app focus.
    private func setFullInteraction(_ active: Bool) {
        if active {
            guard answerPopupDeadline == nil else { return }
            contentPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            if contentPanel.isKeyWindow { contentPanel.resignKey() }
            // Hand focus back to the user's app, unless Settings or a detached window is still open.
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.deactivate()
            }
        }
    }

    // MARK: - Hover monitor

    private func startHoverMonitor() {
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func pollHover() {
        guard !isSuspended else { return }
        let location = NSEvent.mouseLocation
        // Display facts change on display notifications, not ten times a second.
        if settingsStore.settings.islandScreen == .active,
           !cachedMetrics.frame.contains(location), viewModel.state == .collapsed {
            reposition(animated: false)
        }
        let hoverRegion = IslandGeometry.hoverRegion(for: cachedMetrics)
        let insidePanel = contentPanel.isVisible && contentPanel.frame.insetBy(dx: -6, dy: -6).contains(location)
        let hasTransientUI = menuTrackingDepth > 0 || NSApp.modalWindow != nil
            || (contentPanel.childWindows?.contains(where: { $0.isVisible }) ?? false)
        updateAnswerPopup(location: location, insidePanel: insidePanel, hoverRegion: hoverRegion, hasTransientUI: hasTransientUI)

        switch viewModel.state {
        case .collapsed:
            if requiresPointerExit {
                if !hoverRegion.contains(location) { requiresPointerExit = false }
                dwellTracker.reset()
                return
            }
            guard settingsStore.settings.hoverBehavior == .expand else { return }
            let inside = hoverRegion.contains(location) && !viewModel.isPinned
            if dwellTracker.shouldOpen(inside: inside, now: Date()) {
                dwellTracker.reset()
                viewModel.expand()
            }

        case .expanded:
            guard !viewModel.isPinned, !hasTransientUI else { outsideSince = nil; return }
            let inside = hoverRegion.contains(location) || insidePanel
            if inside {
                outsideSince = nil
            } else {
                collapseWhenOutside(IslandHoverPolicy.closeDelayExpanded)
            }

        case .full:
            // Key-window status alone used to latch the island open indefinitely. Keep it open
            // only for deliberate pinning, transient UI or active typing, then honor hover-away.
            let isTyping = contentPanel.isKeyWindow
                && Date().timeIntervalSince(lastKeyboardInteraction) < 1.5
            guard !viewModel.isPinned, !isTyping, !hasTransientUI, answerPopupDeadline == nil else {
                outsideSince = nil
                return
            }
            let inside = hoverRegion.contains(location) || insidePanel
            if inside {
                outsideSince = nil
            } else {
                collapseWhenOutside(IslandHoverPolicy.closeDelayFull)
            }
        }
    }

    private func updateAnswerPopup(location: NSPoint, insidePanel: Bool, hoverRegion: CGRect, hasTransientUI: Bool) {
        guard let deadline = answerPopupDeadline else { return }
        // The user unpinned, collapsed or left the full view: the popup no longer owns the island.
        guard viewModel.state == .full, !viewModel.isPinned else {
            answerPopupDeadline = nil
            return
        }
        let typing = Date().timeIntervalSince(lastKeyboardInteraction) < Self.answerPopupIdleTimeout
        let engaged = insidePanel || hoverRegion.contains(location) || hasTransientUI || typing
        answerPopupDeadline = Self.nextAnswerPopupDeadline(deadline, engaged: engaged, now: Date())
        if answerPopupDeadline == nil { viewModel.collapse() }
    }

    /// nil means close now; being engaged (pointer over it, typing) restarts the countdown.
    nonisolated static func nextAnswerPopupDeadline(_ deadline: Date, engaged: Bool, now: Date) -> Date? {
        if engaged { return now.addingTimeInterval(answerPopupIdleTimeout) }
        return now < deadline ? deadline : nil
    }

    private func collapseWhenOutside(_ delay: TimeInterval) {
        if outsideSince == nil { outsideSince = Date() }
        guard let outsideSince, Date().timeIntervalSince(outsideSince) >= delay else { return }
        self.outsideSince = nil
        viewModel.setState(.collapsed)
    }

    private func observeInteraction() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self, event.window === self.contentPanel else { return false }
                if event.keyCode == 53, self.menuTrackingDepth == 0 {
                    self.viewModel.collapse()
                    return true
                }
                self.lastKeyboardInteraction = Date()
                self.outsideSince = nil
                return false
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
                self.outsideSince = nil
            }
        })
    }

    private func suspend() {
        onSuspend?()
        isSuspended = true
        hoverTimer?.fireDate = .distantFuture
        dwellTracker.reset()
        outsideSince = nil
        viewModel.collapse()
        hide()
    }

    private func resume() {
        isSuspended = false
        dwellTracker.reset()
        outsideSince = nil
        lastKeyboardInteraction = .distantPast
        hoverTimer?.fireDate = Date()
        reposition(animated: false)
    }

    // MARK: - Screen observation

    private static func makePanel(frame: CGRect) -> IslandPanel {
        let panel = IslandPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        return panel
    }

    private static func metrics(for choice: IslandScreenChoice) -> ScreenMetrics {
        ScreenMetrics.metrics(for: IslandScreenResolver.screen(for: choice))
    }

    private func observeScreenChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
    }
}
