import CoreGraphics
import Foundation

/// Result of one full-display capture.
struct CapturedScreenshot: Sendable, Identifiable {
    let id: UUID
    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let displayName: String
    let createdAt: Date
}

struct CaptureOptions: Sendable {
    var displayID: CGDirectDisplayID?
    var excludeAllAppWindows: Bool = false
    var includeCursor: Bool = false
    var format: ScreenshotFormat = .png
    /// When true the encoded file is kept under `AppPaths.screenshotsDirectory` until the user deletes
    /// it; otherwise it lives in `AppPaths.temporaryCapturesDirectory` and the conversation removes it
    /// when the attachment or conversation is cleared.
    var saveLocally: Bool = false
    /// Display-local rectangle in points (top-left origin) to capture instead of the whole display.
    var sourceRect: CGRect?
}

/// Decides whether a freshly captured file has no owner (not attached to a chat, not kept on disk).
enum CaptureDeliveryPolicy {
    static func deleteImmediately(attachToChat: Bool, isReplacement: Bool, saveLocally: Bool) -> Bool {
        !(attachToChat || isReplacement) && !saveLocally
    }
}

enum ScreenshotError: LocalizedError, Equatable {
    case permissionDenied
    case displayUnavailable
    case contentUnavailable(String)
    case captureFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required. Open System Settings → Privacy & Security → Screen Recording and enable NotchAI."
        case .displayUnavailable:
            return "The selected display is not available anymore."
        case let .contentUnavailable(message):
            return "ScreenCaptureKit could not enumerate content: \(message)"
        case let .captureFailed(message):
            return "Screenshot failed: \(message)"
        case .encodingFailed:
            return "The screenshot could not be encoded."
        }
    }
}

/// Deterministic exclusion policy, separated from ScreenCaptureKit so it is unit-testable.
enum CaptureFilterLogic {
    struct WindowInfo: Equatable, Sendable {
        let windowNumber: CGWindowID
        let ownerPID: pid_t
    }

    /// Window ids ScreenCaptureKit must exclude: always our island window, optionally every window
    /// this app owns (e.g. detached browser/chat windows) when the user asks for that.
    static func exclusions(
        ourPID: pid_t,
        islandWindowNumber: CGWindowID,
        additionalWindowNumbers: [CGWindowID] = [],
        excludeAllOwnedWindows: Bool,
        windows: [WindowInfo]
    ) -> [CGWindowID] {
        let alwaysExcluded = Set([islandWindowNumber] + additionalWindowNumbers)
        return windows
            .filter { window in
                if alwaysExcluded.contains(window.windowNumber) { return true }
                return excludeAllOwnedWindows && window.ownerPID == ourPID
            }
            .map(\.windowNumber)
            .sorted()
    }
}
