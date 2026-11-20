import CoreGraphics

/// Display facts needed to place the island, injected for testability.
struct ScreenMetrics: Equatable, Sendable {
    var frame: CGRect
    var safeAreaTop: CGFloat
    var hasNotch: Bool
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
    var visibleFrame: CGRect
}

/// Pure island placement math.
///
/// The interactive island uses an anchor matching the camera housing and a content panel below it.
/// Separate click-through windows draw the joining shoulders and status badge. Keeping content below
/// the menu bar means an open island never blocks menu-bar clicks. Hover is resolved from the global
/// cursor position in the window controller because the hardware notch cutout receives no mouse events.
enum IslandGeometry {
    static let collapsedPillSize = CGSize(width: 220, height: 36)
    static let expandedSize = CGSize(width: 360, height: 148)
    static let fullSize = CGSize(width: 560, height: 540)
    static let notchlessTopInset: CGFloat = 6
    static let shoulderRadius: CGFloat = 12
    static let shoulderOverlap: CGFloat = 1
    /// Small click-through window that shows the transient "response done" badge beside the pill.
    static let badgeSize = CGSize(width: 92, height: 20)
    static let badgeGap: CGFloat = 5
    /// Extra hover tolerance below and beside the anchor; the timer uses this, not a window hit area.
    static let hoverMarginBelow: CGFloat = 14
    static let hoverSideMargin: CGFloat = 20

    /// The physical camera housing area on a notch display, derived from the auxiliary top areas.
    static func notchRect(for screen: ScreenMetrics) -> CGRect? {
        guard screen.hasNotch,
              let left = screen.auxiliaryTopLeft,
              let right = screen.auxiliaryTopRight else { return nil }
        let minX = left.maxX
        let maxX = right.minX
        guard maxX > minX, screen.safeAreaTop > 0 else { return nil }
        return CGRect(
            x: minX,
            y: screen.frame.maxY - screen.safeAreaTop,
            width: maxX - minX,
            height: screen.safeAreaTop
        )
    }

    /// Black collapsed pill: exactly the camera housing on notch displays, or a small pill elsewhere.
    static func pillSize(for screen: ScreenMetrics) -> CGSize {
        if let notch = notchRect(for: screen) {
            return CGSize(width: notch.width, height: max(notch.height, 24))
        }
        return collapsedPillSize
    }

    static func panelSize(for state: IslandState, screen: ScreenMetrics) -> CGSize {
        switch state {
        case .collapsed: return pillSize(for: screen)
        case .expanded: return expandedSize
        case .full: return fullSize
        }
    }

    /// Top edge of the anchor/panel: screen top on notch displays, small inset on notchless displays.
    static func pillTop(for screen: ScreenMetrics) -> CGFloat {
        screen.frame.maxY - (screen.hasNotch ? 0 : notchlessTopInset)
    }

    /// Window frame of the always-visible notch anchor: exactly the pill, so it cannot intercept
    /// clicks beside the notch (the completion badge gets its own click-through window).
    static func anchorFrame(for screen: ScreenMetrics) -> CGRect {
        let pill = pillSize(for: screen)
        let top = pillTop(for: screen)
        return CGRect(
            x: (notchRect(for: screen)?.midX ?? screen.frame.midX) - pill.width / 2,
            y: top - pill.height,
            width: pill.width,
            height: pill.height
        )
    }

    /// Purely visual shoulders around the housing's bottom corners. This separate window is
    /// click-through; the interactive content still starts below the menu bar.
    static func shoulderFrame(for screen: ScreenMetrics) -> CGRect? {
        guard screen.hasNotch else { return nil }
        let anchor = anchorFrame(for: screen)
        return CGRect(x: anchor.minX - shoulderRadius,
                      y: anchor.minY - shoulderOverlap,
                      width: anchor.width + 2 * shoulderRadius,
                      height: shoulderRadius + shoulderOverlap)
    }

    /// Frame of the click-through completion badge, just to the right of the notch.
    static func badgeFrame(for screen: ScreenMetrics) -> CGRect {
        let anchor = anchorFrame(for: screen)
        return CGRect(
            x: anchor.maxX + badgeGap,
            y: anchor.midY - badgeSize.height / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )
    }

    /// Hover/home region used by the cursor monitor: the anchor plus a small margin below and to the
    /// sides, so pointing at the notch cutout or just under it opens the island.
    static func hoverRegion(for screen: ScreenMetrics) -> CGRect {
        let anchor = anchorFrame(for: screen)
        return CGRect(x: anchor.minX - hoverSideMargin,
                      y: anchor.minY - hoverMarginBelow,
                      width: anchor.width + 2 * hoverSideMargin,
                      height: anchor.height + hoverMarginBelow)
    }

    /// Content panel frame for expanded/full. Its top edge is exactly the anchor's bottom edge, which
    /// on a notch display is the menu-bar bottom — the panel never covers the menu bar.
    static func contentFrame(for state: IslandState, screen: ScreenMetrics) -> CGRect? {
        guard state != .collapsed else { return nil }
        let panel = panelSize(for: state, screen: screen)
        let width = min(panel.width, max(screen.frame.width - 16, 120))
        let top = pillTop(for: screen) - pillSize(for: screen).height
        let bottomMargin: CGFloat = 8
        let availableHeight = top - screen.frame.minY - bottomMargin
        let height = min(panel.height, max(availableHeight, 120))
        let centeredX = anchorFrame(for: screen).midX - width / 2
        let x = min(max(centeredX, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
