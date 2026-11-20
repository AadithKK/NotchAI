import AppKit
import Foundation
import PDFKit

/// A document the user gave the chat. Only its extracted text is kept; the original file is never
/// copied or uploaded, and the text is sent to the selected provider only when the user presses Send.
struct ChatDocument: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var text: String
    /// Characters in the source before truncation.
    var originalCharacterCount: Int

    var isTruncated: Bool { originalCharacterCount > text.count }

    init(id: UUID = UUID(), name: String, text: String, originalCharacterCount: Int? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.originalCharacterCount = originalCharacterCount ?? text.count
    }
}

enum DocumentTextError: LocalizedError, Equatable {
    case tooLarge(String)
    case notAFile(String)
    case unreadable(String)
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name): return "\(name) is larger than 25 MB."
        case .notAFile(let name): return "\(name) is a folder; add the files inside it instead."
        case .unreadable(let name): return "\(name) isn't a supported document. Use PDF, Word, RTF, or a text or code file."
        case .noText(let name): return "\(name) has no readable text (a scanned PDF needs OCR first)."
        }
    }
}

enum DocumentTextExtractor {
    static let maxFileBytes = 25 * 1024 * 1024
    /// About 30k tokens per document; keeps a few documents plus a conversation inside model limits.
    static let maxCharacters = 120_000
    static let maxDocumentsPerMessage = 5

    private static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "odt"]

    static func extract(from url: URL) throws -> ChatDocument {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw DocumentTextError.notAFile(name) }
        if let size = values?.fileSize, size > maxFileBytes { throw DocumentTextError.tooLarge(name) }

        let ext = url.pathExtension.lowercased()
        let raw: String
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw DocumentTextError.unreadable(name) }
            raw = pdf.string ?? ""
        } else if richTextExtensions.contains(ext) {
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw DocumentTextError.unreadable(name)
            }
            raw = attributed.string
        } else {
            guard let data = try? Data(contentsOf: url) else { throw DocumentTextError.unreadable(name) }
            guard let decoded = decodePlainText(data) else { throw DocumentTextError.unreadable(name) }
            raw = decoded
        }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DocumentTextError.noText(name) }
        return ChatDocument(name: name, text: String(text.prefix(maxCharacters)), originalCharacterCount: text.count)
    }

    /// Text files only: reject data with NUL bytes (binary) before trying common encodings.
    static func decodePlainText(_ data: Data) -> String? {
        if data.prefix(4096).contains(0) {
            // UTF-16 text legitimately contains NULs; accept it only with a byte-order mark.
            let bom = data.prefix(2)
            guard bom == Data([0xFF, 0xFE]) || bom == Data([0xFE, 0xFF]) else { return nil }
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

extension ChatMessage {
    /// The text sent to the model: attached document text first, then what the user typed.
    var providerText: String {
        guard let documents, !documents.isEmpty else { return text }
        var parts = ["The user attached these documents. Use them to answer.\n"]
        for document in documents {
            let note = document.isTruncated ? " (truncated to the first \(document.text.count) characters)" : ""
            parts.append("<document name=\"\(document.name)\"\(note)>\n\(document.text)\n</document>\n")
        }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: "\n")
    }
}
