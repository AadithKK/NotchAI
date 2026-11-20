import Foundation

/// Hover timing rules for the island.
enum IslandHoverPolicy {
    /// The pointer must rest on the notch this long before the panel opens.
    static let openDwell: TimeInterval = 1.0
    /// The pointer must leave the anchor+panel this long before the expanded panel closes.
    static let closeDelayExpanded: TimeInterval = 0.08
    /// Full chat/browser closes when the pointer is away unless typing, transient UI or pinning holds it.
    static let closeDelayFull: TimeInterval = 0.15
}

/// Pure dwell tracker so the "rest on the notch for a second" rule is unit-testable.
struct HoverDwellTracker {
    private(set) var startedAt: Date?

    /// Returns true exactly when the dwell threshold is first reached while continuously inside.
    mutating func shouldOpen(inside: Bool, now: Date, dwell: TimeInterval = IslandHoverPolicy.openDwell) -> Bool {
        guard inside else {
            startedAt = nil
            return false
        }
        guard let startedAt else {
            self.startedAt = now
            return false
        }
        guard now.timeIntervalSince(startedAt) >= dwell else { return false }
        // Fire once; a new open requires leaving and re-entering.
        self.startedAt = nil
        return true
    }

    mutating func reset() {
        startedAt = nil
    }
}
