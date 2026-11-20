import Foundation

/// Writes encoded screenshots to disk.
///
/// Kept separate from `ScreenshotService` so file naming, directory creation and atomic replacement
/// can be unit tested without ScreenCaptureKit or a screen-recording grant.
enum ScreenshotFileWriter {
    /// Writes `data` to `directory/filename`, creating the directory when needed.
    ///
    /// The write is atomic: bytes go to a temporary sibling and are moved into place only after the
    /// full encoded image is available, so a partial file never appears in the screenshots directory.
    /// A pre-existing file with the same name is replaced.
    @discardableResult
    static func write(
        _ data: Data,
        filename: ScreenshotFilename,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(filename.fileName, isDirectory: false)
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            throw ScreenshotError.captureFailed("Could not save the screenshot: \(error.localizedDescription)")
        }
    }
}
