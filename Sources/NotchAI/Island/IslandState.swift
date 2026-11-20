import Foundation

/// The three island presentations.
enum IslandState: String, CaseIterable, Sendable {
    /// Pill wrapped around the camera notch (or a small pill on notchless displays).
    case collapsed
    /// Quick controls for AI, browser and capture.
    case expanded
    /// Full chat or browser content.
    case full
}
