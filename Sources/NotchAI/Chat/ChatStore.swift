import Foundation

/// Persistence seam for conversations, injectable so tests never touch the real file.
protocol ChatPersisting: AnyObject {
    func loadConversations() -> [Conversation]
    func saveConversations(_ conversations: [Conversation])
    func flush()
}

extension ChatPersisting {
    func flush() {}
}

/// Atomic JSON store under Application Support. Small, single-user history needs no database.
final class JSONChatStore: ChatPersisting {
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "NotchAI.chat.persistence", qos: .utility)
    /// Set when the previous load had to drop data; the next save backs the original file up first so
    /// one corrupt/unknown entry can never silently destroy the whole history.
    private var needsBackupBeforeSave = false

    init(fileURL: URL = AppPaths.conversationsFile) {
        self.fileURL = fileURL
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadConversations() -> [Conversation] {
        ioQueue.sync { loadOnQueue() }
    }

    private func loadOnQueue() -> [Conversation] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Present but unreadable: the history may still be intact. Arm a backup and never
                // overwrite it silently on the next save.
                needsBackupBeforeSave = true
                Log.chat.error("chat history exists but could not be read; it will be backed up before the next save: \(error.localizedDescription)")
            }
            return []
        }
        let decoder = Self.decoder()

        // Fast path: the whole file decodes cleanly.
        if let decoded = try? decoder.decode([Conversation].self, from: data) {
            needsBackupBeforeSave = false
            return decoded
        }

        // Salvage per entry so one unknown provider id / corrupt element keeps the other chats.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let elements = object as? [Any] else {
            needsBackupBeforeSave = true
            Log.chat.error("conversation file is not a JSON array; it will be backed up before the next save")
            return []
        }

        var conversations: [Conversation] = []
        var dropped = 0
        for element in elements {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let conversation = try? decoder.decode(Conversation.self, from: elementData) else {
                dropped += 1
                continue
            }
            conversations.append(conversation)
        }
        if dropped > 0 {
            needsBackupBeforeSave = true
            Log.chat.error("skipped \(dropped) unreadable conversation entr(y/ies); preserving the rest and backing up the original file")
        }
        return conversations
    }

    func saveConversations(_ conversations: [Conversation]) {
        // Value snapshots preserve ordering while encoding and disk writes leave the UI thread.
        ioQueue.async { [self] in saveOnQueue(conversations) }
    }

    func flush() { ioQueue.sync {} }

    private func saveOnQueue(_ conversations: [Conversation]) {
        guard let data = try? Self.encoder().encode(conversations) else { return }
        if needsBackupBeforeSave {
            guard backupExistingFile() else {
                Log.chat.error("refusing to overwrite unreadable chat history because a backup could not be created")
                return
            }
            needsBackupBeforeSave = false
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.chat.error("failed to persist conversations: \(String(describing: error))")
        }
    }

    @discardableResult
    private func backupExistingFile() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = "conversations.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)

        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            Log.chat.error("backed up unreadable conversations to \(backupURL.lastPathComponent)")
            return true
        } catch {
            // Recover an owner-readable copy when the file was made unreadable by a permission change.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            do {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
                Log.chat.error("recovered permissions and backed up conversations to \(backupURL.lastPathComponent)")
                return true
            } catch {
                Log.chat.error("could not back up conversations before save: \(error.localizedDescription)")
                return false
            }
        }
    }
}
