import AppKit
import CoreGraphics

/// One selectable capture display, derived without ScreenCaptureKit so Settings can list displays
/// before any permission prompts.
struct DisplayCatalogEntry: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let hasNotch: Bool
}

enum DisplayCatalog {
    static func displays() -> [DisplayCatalogEntry] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID = number?.uint32Value ?? CGMainDisplayID()
            var width = Int(CGDisplayPixelsWide(displayID))
            var height = Int(CGDisplayPixelsHigh(displayID))
            if width <= 0 || height <= 0 {
                let scale = screen.backingScaleFactor
                width = Int(screen.frame.width * scale)
                height = Int(screen.frame.height * scale)
            }
            return DisplayCatalogEntry(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: width,
                pixelHeight: height,
                hasNotch: screen.safeAreaInsets.top > 0
            )
        }
    }
}
