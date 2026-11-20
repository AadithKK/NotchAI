import Foundation

/// Validates local screenshot attachments before their bytes are read or sent to a provider.
///
/// Conversations persist file paths, so a restored or edited history file must never be able to point
/// the app at an arbitrary local file: only images inside the app-owned capture directories are
/// accepted, only when their bytes look like a supported image, and only under the inline size cap.
enum AttachmentSanitizer {
    /// DeepSeek allows 32 MiB inline images; Gemini caps the whole inline request at 20 MB (base64
    /// expands by 4/3). One 14 MiB raw image encodes to ~18.7 MB and the aggregate encoded budget
    /// below keeps multi-attachment requests under Gemini's cap too.
    static let maximumRawImageBytes = 14 * 1024 * 1024
    /// Base64 characters allowed across one request's attachments (19 MiB raw encoded size).
    static let maximumTotalEncodedBytes = 19 * 1024 * 1024

    static var allowedDirectories: [URL] {
        [AppPaths.screenshotsDirectory, AppPaths.temporaryCapturesDirectory]
    }

    /// Canonical containment: standardized (`..` removed) plus symlink-resolved, compared against a
    /// directory prefix that requires the trailing separator, so `Screenshots-Session-backup` is not
    /// inside `Screenshots-Session` and a directory itself never matches.
    static func isStrictlyInside(_ directory: URL, _ fileURL: URL) -> Bool {
        let basePath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(basePath + "/")
    }

    static func isInsideAllowedDirectory(_ fileURL: URL) -> Bool {
        allowedDirectories.contains { isStrictlyInside($0, fileURL) }
    }

    static func payload(
        for ref: ImageAttachmentRef,
        maximumBytes: Int = maximumRawImageBytes
    ) -> ProviderImage? {
        let fileURL = ref.fileURL
        guard isInsideAllowedDirectory(fileURL) else { return nil }
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else { return nil }
        guard let data = try? Data(contentsOf: fileURL), data.count <= maximumBytes else { return nil }
        guard let mimeType = imageMimeType(for: data) else { return nil }
        return ProviderImage(mimeType: mimeType, base64: data.base64EncodedString())
    }

    /// One request-wide encoded budget. A single request may carry images from several messages, so the
    /// budget must be shared across the whole conversation slice, not reset per message.
    struct AttachmentBudget {
        var totalEncodedBytes: Int = AttachmentSanitizer.maximumTotalEncodedBytes
        private(set) var usedEncodedBytes = 0

        mutating func reserve(_ payloads: [ProviderImage]) {
            usedEncodedBytes += payloads.reduce(0) { $0 + $1.base64.utf8.count }
        }

        /// Reserve one already-encoded payload; false when it would exceed the request budget.
        mutating func reserve(_ payload: ProviderImage) -> Bool {
            let encodedBytes = payload.base64.utf8.count
            guard usedEncodedBytes + encodedBytes <= totalEncodedBytes else { return false }
            usedEncodedBytes += encodedBytes
            return true
        }

        mutating func prepare(_ refs: [ImageAttachmentRef]) -> (payloads: [ProviderImage], dropped: Int) {
            var payloads: [ProviderImage] = []
            var dropped = 0
            for ref in refs {
                guard let payload = AttachmentSanitizer.payload(for: ref) else {
                    dropped += 1
                    continue
                }
                let encodedBytes = payload.base64.utf8.count
                guard usedEncodedBytes + encodedBytes <= totalEncodedBytes else {
                    dropped += 1
                    continue
                }
                usedEncodedBytes += encodedBytes
                payloads.append(payload)
            }
            return (payloads, dropped)
        }
    }

    /// Sanitize a message's attachments as a batch: each image must be valid, inside the app-owned
    /// capture directories, under `maximumRawBytes`, and the combined base64 payload must stay under
    /// `maximumTotalEncodedBytes`. Attachments that fail any check are counted as dropped so the chat
    /// can surface an error instead of silently sending less than the user attached.
    static func preparedPayloads(
        for refs: [ImageAttachmentRef],
        maximumRawBytes: Int = maximumRawImageBytes,
        maximumTotalEncodedBytes: Int = maximumTotalEncodedBytes
    ) -> (payloads: [ProviderImage], dropped: Int) {
        var budget = AttachmentBudget(totalEncodedBytes: maximumTotalEncodedBytes)
        var payloads: [ProviderImage] = []
        var dropped = 0
        for ref in refs {
            // Encode once with the caller's raw cap; the budget only accounts for the result.
            guard let payload = payload(for: ref, maximumBytes: maximumRawBytes) else {
                dropped += 1
                continue
            }
            if budget.reserve(payload) {
                payloads.append(payload)
            } else {
                dropped += 1
            }
        }
        return (payloads, dropped)
    }

    static func imageMimeType(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 6 {
            let header = String(bytes: bytes[0..<6], encoding: .ascii)
            if header == "GIF87a" || header == "GIF89a" { return "image/gif" }
        }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return "image/webp"
        }
        return nil
    }
}
