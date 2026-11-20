import Foundation

/// Filesystem locations owned by NotchAI. Everything stays on this Mac; nothing here is uploaded.
enum AppPaths {
    private static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("NotchAI", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    /// Captures the user asked to keep on disk.
    static let screenshotsDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    /// Captures owned by a conversation; removed when the attachment or chat is cleared.
    static let temporaryCapturesDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("Screenshots-Session", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    static let conversationsFile: URL = appSupportDirectory.appendingPathComponent("conversations.json")
    static let browserHistoryFile: URL = appSupportDirectory.appendingPathComponent("browser-history.json")
}
