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

/// Global key listener for the double-tap shortcuts. Needs the Input Monitoring permission; it only
/// sees keys pressed in other apps (typing inside NotchAI never reaches it).
@MainActor
final class DoubleTapMonitor {
    private var monitor: Any?
    private var detector = DoubleTapDetector()
    private var onTrigger: ((String) -> Void)?

    var isInstalled: Bool { monitor != nil }
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    func setEnabled(_ enabled: Bool, onTrigger: @escaping (String) -> Void) {
        self.onTrigger = onTrigger
        if enabled, monitor == nil {
            if !Self.hasPermission { _ = CGRequestListenEventAccess() }
            detector = DoubleTapDetector()
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Held keys repeat, and chords (⌘H etc.) are never a double-tap.
        guard !event.isARepeat, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return }
        if let fired = detector.ingest(key, now: event.timestamp) { onTrigger?(fired) }
    }
}
