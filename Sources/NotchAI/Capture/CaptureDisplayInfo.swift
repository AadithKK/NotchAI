import CoreGraphics
import Foundation

/// One capturable display, surfaced to Settings so the user can choose the capture display.
struct CaptureDisplayInfo: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Pixel dimensions of a display in its native framebuffer resolution.
struct CapturePixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    var isValid: Bool { width > 0 && height > 0 }
}

/// Deterministic display selection and sizing rules.
///
/// Kept free of ScreenCaptureKit and AppKit so the fallback behavior that protects capture from a
/// stale `CaptureOptions.displayID` setting can be unit tested offline.
enum CaptureDisplayResolver {
    enum Resolution: Equatable, Sendable {
        /// The display the caller asked for is available.
        case exact(CGDirectDisplayID)
        /// The requested display was nil or no longer available; the main display is used instead.
        case fallbackToMain(CGDirectDisplayID)
        /// No display can be captured.
        case unavailable
    }

    /// Resolves which display to capture.
    ///
    /// Product rule: prefer the requested display, otherwise fall back to `CGMainDisplayID()`. When
    /// the main display is not in the enumerated display list either, capture reports
    /// `.displayUnavailable` instead of guessing at a display the user did not choose.
    static func resolve(
        requested: CGDirectDisplayID?,
        available: [CGDirectDisplayID],
        mainDisplayID: CGDirectDisplayID
    ) -> Resolution {
        if let requested, available.contains(requested) {
            return .exact(requested)
        }
        if available.contains(mainDisplayID) {
            return .fallbackToMain(mainDisplayID)
        }
        return .unavailable
    }

    /// Native framebuffer size for a display.
    ///
    /// `CGDisplayPixelsWide`/`CGDisplayPixelsHigh` report the real framebuffer (Retina) size and are
    /// preferred. Some headless or transitional display states report 0; in that case the pixel size
    /// is derived from the point size and backing scale so capture never silently drops to 1x.
    static func nativePixelSize(
        displayPixelWidth: Int,
        displayPixelHeight: Int,
        pointWidth: Int,
        pointHeight: Int,
        backingScaleFactor: CGFloat
    ) -> CapturePixelSize? {
        if displayPixelWidth > 0, displayPixelHeight > 0 {
            return CapturePixelSize(width: displayPixelWidth, height: displayPixelHeight)
        }
        guard pointWidth > 0, pointHeight > 0, backingScaleFactor > 0, backingScaleFactor.isFinite else {
            return nil
        }
        let size = CapturePixelSize(
            width: Int((CGFloat(pointWidth) * backingScaleFactor).rounded()),
            height: Int((CGFloat(pointHeight) * backingScaleFactor).rounded())
        )
        return size.isValid ? size : nil
    }
}
