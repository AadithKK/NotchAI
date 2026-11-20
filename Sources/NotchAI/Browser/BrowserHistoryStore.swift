import Foundation
import os

/// One page visit, newest first in the history list and in the JSON file on disk.
struct BrowserHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var url: String
    var title: String
    var date: Date

    init(id: UUID = UUID(), url: String, title: String, date: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
    }

    /// A title worth showing in the popover, falling back to the host.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: url)?.host ?? url
    }
}

/// Newest-first browsing history capped at `maximumEntries`, persisted as a single JSON file.
///
/// Loading is tolerant: a missing or corrupt file produces an empty history instead of an error,
/// so a damaged file can never keep the browser from opening. Saves are atomic, so the file on disk
/// is always either the previous version or a complete new one.
final class BrowserHistoryStore {
    /// One store per process so two browser windows never overwrite each other's history.
    static let shared = BrowserHistoryStore()

    static let maximumEntries = 200
    static let fileName = "browser-history.json"

    let fileURL: URL
    private(set) var entries: [BrowserHistoryEntry] = []

    init(directory: URL = AppPaths.appSupportDirectory) {
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.entries = Self.load(from: fileURL)
    }

    /// Adds one visit, trims to `maximumEntries` (dropping the oldest), persists, and returns the
    /// updated newest-first list.
    @discardableResult
    func record(_ entry: BrowserHistoryEntry) -> [BrowserHistoryEntry] {
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        save()
        return entries
    }

    /// Re-reads the file, tolerating a missing or corrupt one.
    @discardableResult
    func load() -> [BrowserHistoryEntry] {
        entries = Self.load(from: fileURL)
        return entries
    }

    func clear() {
        entries = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Log.browser.error("Browser history could not be cleared: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.browser.error("Browser history could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL) -> [BrowserHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
            return Array(decoded.prefix(maximumEntries))
        } catch {
            Log.browser.error("Browser history could not be read; starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
