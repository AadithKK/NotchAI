import AppKit

extension ScreenMetrics {
    init(screen: NSScreen) {
        let hasNotch = screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            hasNotch: hasNotch,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            visibleFrame: screen.visibleFrame
        )
    }

    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(screen: screen)
    }

    static func mainScreenMetrics() -> ScreenMetrics {
        if let main = NSScreen.main {
            return metrics(for: main)
        }
        if let first = NSScreen.screens.first {
            return metrics(for: first)
        }
        return ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 0,
            hasNotch: false,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
    }
}

enum IslandScreenResolver {
    /// Resolve the screen the island should live on for the user's setting.
    static func screen(for choice: IslandScreenChoice) -> NSScreen {
        switch choice {
        case .main:
            return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
        case .active:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouse) }
                ?? NSScreen.main
                ?? NSScreen.screens[0]
        }
    }
}
