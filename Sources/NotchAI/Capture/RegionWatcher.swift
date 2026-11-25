import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Display-local rectangle conversion for ScreenCaptureKit (points, top-left origin) from AppKit
/// global coordinates (bottom-left origin).
enum RegionGeometry {
    static func displayLocal(rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Grayscale thumbnails used only to notice that a region changed; they are never sent anywhere.
enum LuminanceSampler {
    static let side = 64

    static func pixels(from image: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: side * side)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? buffer : nil
    }
}

/// Decides when a watched region has changed *and settled*: a change must exceed `threshold` (so a
/// blinking caret or clock does not fire), then stay still for one more poll (so a half-loaded page is
/// not sent), and sends are at least `cooldown` apart to protect the API bill.
struct ChangeDetector {
    var threshold = 0.03
    var tolerance = 24
    var cooldown: TimeInterval = 4

    private var baseline: [UInt8]?
    private var previous: [UInt8]?
    private var pending = false
    private var lastFire = Date.distantPast

    static func changedFraction(_ a: [UInt8], _ b: [UInt8], tolerance: Int) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > tolerance { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Feed one sample; returns true when the region should be captured and answered now.
    mutating func ingest(_ sample: [UInt8], now: Date) -> Bool {
        defer { previous = sample }
        guard let baseline else {
            self.baseline = sample
            return false
        }
        let fromBaseline = Self.changedFraction(baseline, sample, tolerance: tolerance)
        if !pending {
            if fromBaseline > threshold { pending = true }
            return false
        }
        guard let previous,
              Self.changedFraction(previous, sample, tolerance: tolerance) <= threshold else { return false }
        if fromBaseline <= threshold {
            pending = false // it changed and changed back: nothing new to answer
            return false
        }
        guard now.timeIntervalSince(lastFire) >= cooldown else { return false }
        pending = false
        self.baseline = sample
        lastFire = now
        return true
    }
}

/// What Watch Region is looking at: a display-local rectangle plus the answer mode for this session.
struct WatchTarget: Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let mode: AnswerMode
}

/// Polls a screen region about once a second and calls `onChange` when it changes and settles.
@MainActor
final class RegionWatcher {
    private var task: Task<Void, Never>?
    var isWatching: Bool { task != nil }

    func start(
        target: WatchTarget,
        filter: SCContentFilter,
        watchedPID: pid_t,
        isBusy: @escaping () -> Bool,
        onChange: @escaping () async -> Void,
        onError: @escaping (Error) -> Void
    ) {
        stop()
        let ourPID = ProcessInfo.processInfo.processIdentifier
        task = Task {
            var detector = ChangeDetector()
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                if isBusy() { continue }
                // If the user switched to some other app the region shows different content; do not
                // send it. The watched app and NotchAI itself (the answer popup) are fine.
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front != watchedPID && front != ourPID { continue }
                do {
                    let pixels = try await ScreenshotService.shared.sampleLuminance(
                        filter: filter, sourceRect: target.rect
                    )
                    failures = 0
                    if detector.ingest(pixels, now: Date()) { await onChange() }
                } catch {
                    failures += 1
                    if failures >= 3 {
                        onError(error)
                        return
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
