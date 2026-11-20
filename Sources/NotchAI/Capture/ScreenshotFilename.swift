import Foundation

/// Deterministic screenshot file naming.
///
/// Format: `Screenshot-<yyyyMMdd-HHmmss>-<shortUUID>.<ext>`, for example
/// `Screenshot-20261106-143504-abcdef01.png`. The timestamp is local time; the short UUID keeps names
/// unique when two screenshots are taken within the same second.
struct ScreenshotFilename: Equatable, Sendable {
    static let prefix = "Screenshot"
    static let shortIdentifierLength = 8

    let stem: String
    let fileExtension: String

    var fileName: String { "\(stem).\(fileExtension)" }

    static func make(
        date: Date,
        id: UUID = UUID(),
        format: ScreenshotFormat,
        timeZone: TimeZone = .current
    ) -> ScreenshotFilename {
        ScreenshotFilename(
            stem: "\(prefix)-\(timestamp(for: date, timeZone: timeZone))-\(shortIdentifier(for: id))",
            fileExtension: fileExtension(for: format)
        )
    }

    static func timestamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// First eight characters of the UUID, lowercased for a filename-safe, case-insensitive-friendly id.
    static func shortIdentifier(for id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(shortIdentifierLength))
    }

    static func fileExtension(for format: ScreenshotFormat) -> String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpeg"
        }
    }
}
