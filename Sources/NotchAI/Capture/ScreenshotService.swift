import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

/// Full-display capture built on ScreenCaptureKit.
///
/// The island is a distinct `NSPanel`; its window number is always excluded from the content filter,
/// so screenshots show the desktop behind the overlay instead of the overlay itself.
///
/// The filter is a display filter with *excluded windows* — never a crop or a blur — so the wallpaper,
/// menu bar and every other application's windows are captured exactly as they appear.
@MainActor
final class ScreenshotService {
    static let shared = ScreenshotService()

    // MARK: - Permission

    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the normal macOS Screen Recording prompt when permission is missing.
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Displays

    /// Displays that can be captured, used by Settings to choose the capture display.
    ///
    /// ScreenCaptureKit needs the Screen Recording grant for a complete list; without it the same
    /// information is read through CoreGraphics, so Settings can render the picker before the user
    /// has granted anything. This never triggers a TCC prompt.
    func availableDisplays() async throws -> [CaptureDisplayInfo] {
        if CGPreflightScreenCaptureAccess() {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = content.displays.map { display in
                    let pixels = nativePixelSize(for: display)
                        ?? CapturePixelSize(width: display.width, height: display.height)
                    return CaptureDisplayInfo(
                        id: display.displayID,
                        name: displayName(for: display.displayID),
                        pixelWidth: pixels.width,
                        pixelHeight: pixels.height
                    )
                }
                if !displays.isEmpty {
                    return displays
                }
            } catch {
                Log.capture.notice(
                    "ScreenCaptureKit display list unavailable, falling back to CoreGraphics: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return try coreGraphicsDisplays()
    }

    // MARK: - Capture

    /// Captures the selected display, excluding the island and — when requested — every window this
    /// app owns, at the display's native pixel resolution.
    ///
    /// The encoded image is written atomically. `saveLocally` captures go to
    /// `AppPaths.screenshotsDirectory` and are kept until the user deletes them; session captures go to
    /// `AppPaths.temporaryCapturesDirectory` and the conversation deletes them when the attachment or
    /// conversation is cleared.
    func capture(
        options: CaptureOptions,
        islandWindowNumber: CGWindowID,
        additionalWindowNumbers: [CGWindowID] = []
    ) async throws -> CapturedScreenshot {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard ensureScreenRecordingPermission() else {
            throw ScreenshotError.permissionDenied
        }

        let content = try await shareableContent()
        let display = try resolvedDisplay(in: content, requested: options.displayID)
        let excludedWindows = excludedWindows(
            in: content,
            islandWindowNumber: islandWindowNumber,
            additionalWindowNumbers: additionalWindowNumbers,
            excludeAllAppWindows: options.excludeAllAppWindows
        )
        Log.capture.debug(
            "Capturing display \(display.displayID, privacy: .public), excluding \(excludedWindows.count) window(s)"
        )

        // Display filter with excluded windows: the desktop behind the island is captured instead of
        // the island itself. There is deliberately no crop and no blur.
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        guard let pixelSize = nativePixelSize(for: display) else {
            throw ScreenshotError.captureFailed(
                "Could not determine the native resolution of display \(display.displayID)."
            )
        }
        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.captureResolution = .best
        configuration.showsCursor = options.includeCursor
        configuration.scalesToFit = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Log.capture.error(
                "ScreenCaptureKit capture failed: \(error.localizedDescription, privacy: .public)"
            )
            throw mapCaptureError(error)
        }

        // Encoding a 6K image takes long enough to matter for UI responsiveness; keep it off the main actor.
        let format = options.format
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try ScreenshotEncoding.data(for: image, format: format)
            }.value
        } catch let error as ScreenshotError {
            throw error
        } catch {
            Log.capture.error(
                "Screenshot encoding failed: \(error.localizedDescription, privacy: .public)"
            )
            throw ScreenshotError.encodingFailed
        }

        let capturedAt = Date()
        let id = UUID()
        let fileURL = try writeScreenshot(
            data,
            format: format,
            date: capturedAt,
            id: id,
            saveLocally: options.saveLocally
        )

        let elapsedMilliseconds = Int(((CFAbsoluteTimeGetCurrent() - startTime) * 1000).rounded())
        Log.capture.debug(
            "Captured \(image.width)x\(image.height) px from display \(display.displayID, privacy: .public) in \(elapsedMilliseconds) ms -> \(fileURL.lastPathComponent, privacy: .public)"
        )

        return CapturedScreenshot(
            id: id,
            fileURL: fileURL,
            pixelWidth: image.width,
            pixelHeight: image.height,
            displayName: displayName(for: display.displayID),
            createdAt: capturedAt
        )
    }

    // MARK: - Permission flow

    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        Log.capture.notice("Screen Recording permission is missing; requesting it.")
        guard CGRequestScreenCaptureAccess() else {
            Log.capture.error("Screen Recording permission was denied.")
            return false
        }
        return true
    }

    // MARK: - ScreenCaptureKit content

    private func shareableContent() async throws -> SCShareableContent {
        do {
            // `excludingDesktopWindows: false` keeps the wallpaper/desktop; `onScreenWindowsOnly: true`
            // enumerates exactly the windows the capture can actually contain.
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.capture.error(
                "Could not enumerate shareable content: \(error.localizedDescription, privacy: .public)"
            )
            throw mapContentError(error)
        }
    }

    private func resolvedDisplay(
        in content: SCShareableContent,
        requested: CGDirectDisplayID?
    ) throws -> SCDisplay {
        let available = content.displays
        let resolution = CaptureDisplayResolver.resolve(
            requested: requested,
            available: available.map(\.displayID),
            mainDisplayID: CGMainDisplayID()
        )
        switch resolution {
        case let .exact(displayID):
            guard let display = available.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotError.displayUnavailable
            }
            return display
        case let .fallbackToMain(displayID):
            if requested == nil {
                Log.capture.debug("Using the main display \(displayID, privacy: .public).")
            } else {
                Log.capture.notice(
                    "Requested display is unavailable; using the main display \(displayID, privacy: .public)."
                )
            }
            guard let display = available.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotError.displayUnavailable
            }
            return display
        case .unavailable:
            Log.capture.error("ScreenCaptureKit reported no capturable displays.")
            throw ScreenshotError.displayUnavailable
        }
    }

    /// Window numbers excluded by the shared policy, mapped back to the live `SCWindow` objects the
    /// content filter needs.
    private func excludedWindows(
        in content: SCShareableContent,
        islandWindowNumber: CGWindowID,
        additionalWindowNumbers: [CGWindowID],
        excludeAllAppWindows: Bool
    ) -> [SCWindow] {
        let infos = content.windows.map { window in
            CaptureFilterLogic.WindowInfo(
                windowNumber: window.windowID,
                ownerPID: window.owningApplication?.processID ?? 0
            )
        }
        let excludedIDs = CaptureFilterLogic.exclusions(
            ourPID: getpid(),
            islandWindowNumber: islandWindowNumber,
            additionalWindowNumbers: additionalWindowNumbers,
            excludeAllOwnedWindows: excludeAllAppWindows,
            windows: infos
        )
        guard !excludedIDs.isEmpty else { return [] }

        // The shared helper owns the exclusion policy. Map its window numbers back to SCWindows and
        // de-duplicate defensively so a repeated number is never handed to SCContentFilter twice.
        var windowsByID: [CGWindowID: SCWindow] = [:]
        for window in content.windows where windowsByID[window.windowID] == nil {
            windowsByID[window.windowID] = window
        }
        var seen = Set<CGWindowID>()
        var result: [SCWindow] = []
        for windowID in excludedIDs where seen.insert(windowID).inserted {
            if let window = windowsByID[windowID] {
                result.append(window)
            }
        }
        return result
    }

    // MARK: - Geometry and display names

    private func nativePixelSize(for display: SCDisplay) -> CapturePixelSize? {
        CaptureDisplayResolver.nativePixelSize(
            displayPixelWidth: Int(CGDisplayPixelsWide(display.displayID)),
            displayPixelHeight: Int(CGDisplayPixelsHigh(display.displayID)),
            pointWidth: display.width,
            pointHeight: display.height,
            backingScaleFactor: screen(for: display.displayID)?.backingScaleFactor ?? 1
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[Self.screenNumberKey] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        screen(for: displayID)?.localizedName ?? "Display"
    }

    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    // MARK: - CoreGraphics fallback

    private func coreGraphicsDisplays() throws -> [CaptureDisplayInfo] {
        var onlineCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &onlineCount) == .success else {
            throw ScreenshotError.captureFailed("Could not enumerate the connected displays.")
        }
        guard onlineCount > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        let capacity = onlineCount
        let error = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(capacity, buffer.baseAddress, &onlineCount)
        }
        guard error == .success else {
            throw ScreenshotError.captureFailed(
                "Could not enumerate the connected displays (CGError \(error.rawValue))."
            )
        }
        return displayIDs.prefix(Int(onlineCount)).map { displayID in
            CaptureDisplayInfo(
                id: displayID,
                name: displayName(for: displayID),
                pixelWidth: Int(CGDisplayPixelsWide(displayID)),
                pixelHeight: Int(CGDisplayPixelsHigh(displayID))
            )
        }
    }

    // MARK: - File output

    /// Writes the encoded capture with an atomic replace into the directory that owns its lifetime.
    private func writeScreenshot(
        _ data: Data,
        format: ScreenshotFormat,
        date: Date,
        id: UUID,
        saveLocally: Bool
    ) throws -> URL {
        let filename = ScreenshotFilename.make(date: date, id: id, format: format)
        let directory = saveLocally ? AppPaths.screenshotsDirectory : AppPaths.temporaryCapturesDirectory
        return try ScreenshotFileWriter.write(data, filename: filename, in: directory)
    }

    // MARK: - Error mapping

    private func screenCaptureErrorCode(_ error: Error) -> SCStreamError.Code? {
        if let streamError = error as? SCStreamError {
            return streamError.code
        }
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return nil }
        return SCStreamError.Code(rawValue: nsError.code)
    }

    private func mapContentError(_ error: Error) -> ScreenshotError {
        if let code = screenCaptureErrorCode(error) {
            switch code {
            case .userDeclined, .missingEntitlements:
                return .permissionDenied
            case .noDisplayList:
                return .displayUnavailable
            case .noCaptureSource:
                return .captureFailed("ScreenCaptureKit could not find anything to capture on that display.")
            default:
                break
            }
        }
        return .contentUnavailable(error.localizedDescription)
    }

    private func mapCaptureError(_ error: Error) -> ScreenshotError {
        if let code = screenCaptureErrorCode(error) {
            switch code {
            case .userDeclined, .missingEntitlements:
                return .permissionDenied
            case .noDisplayList, .noCaptureSource:
                return .displayUnavailable
            default:
                break
            }
        }
        return .captureFailed(error.localizedDescription)
    }
}
