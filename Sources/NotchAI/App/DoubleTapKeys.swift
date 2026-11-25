import AppKit

/// Recognizes a fast double-tap of one of two trigger letters, without storing or logging anything the
/// user types: only the trigger letters and timestamps are compared.
///
/// A double-tap counts only when the second tap follows within `window` AND the first tap came after a
/// pause of at least `idleBefore` with no other key, so "ahh", "shh" and normal typing do not fire.
/// After a fire, taps are ignored for `lockout` so "hhh" or key mashing cannot fire twice.
struct DoubleTapDetector {
    var triggers: Set<String> = ["h", "j"]
    var window: TimeInterval = 0.25
    var idleBefore: TimeInterval = 0.6
    var lockout: TimeInterval = 1.0

    private var lastKeyTime: TimeInterval = -.infinity
    private var first: (key: String, time: TimeInterval, wasIdle: Bool)?
    private var lockedUntil: TimeInterval = -.infinity

    /// Feed every key press (lowercased character); returns the trigger letter when it double-tapped.
    mutating func ingest(_ key: String, now: TimeInterval) -> String? {
        let wasIdle = now - lastKeyTime >= idleBefore
        defer { lastKeyTime = now }
        if now < lockedUntil { first = nil; return nil }
        if let tap = first, tap.key == key, now - tap.time <= window {
            first = nil
            guard tap.wasIdle else { return nil }
            lockedUntil = now + lockout
            return key
        }
        first = triggers.contains(key) ? (key, now, wasIdle) : nil
        return nil
    }
}

/// Global key listener for the double-tap shortcuts, built on a listen-only CGEventTap, which needs
/// exactly the Input Monitoring permission and nothing else. Until that permission is granted it
/// retries every two seconds, so allowing it works immediately, with no relaunch.
@MainActor
final class DoubleTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var detector = DoubleTapDetector()
    private var onTrigger: ((String) -> Void)?
    private var askedForPermission = false

    var isInstalled: Bool { tap != nil }
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    func setEnabled(_ enabled: Bool, onTrigger: @escaping (String) -> Void) {
        self.onTrigger = onTrigger
        if enabled {
            guard tap == nil else { return }
            if !install() { startRetrying() }
        } else {
            retry?.invalidate(); retry = nil
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            tap = nil; source = nil
        }
    }

    private func startRetrying() {
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                if self.install() { self.retry?.invalidate(); self.retry = nil }
            }
        }
    }

    private func install() -> Bool {
        if !Self.hasPermission {
            if !askedForPermission { askedForPermission = true; _ = CGRequestListenEventAccess() }
            return false
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DoubleTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event) // listen-only: never swallow or alter keys
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        detector = DoubleTapDetector()
        Log.app.info("double-tap key listener installed")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]),
              !NSApp.isActive, // typing inside NotchAI itself is never a shortcut
              let key = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return }
        if let fired = detector.ingest(key, now: ProcessInfo.processInfo.systemUptime) {
            Log.app.info("double-tap fired: \(fired, privacy: .public)")
            onTrigger?(fired)
        }
    }
}
