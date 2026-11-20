import Foundation

/// A local screenshot attached to a message. Only the path is stored; the file stays on disk until
/// the user sends the message, and the bytes are only base64-encoded for that request.
struct ImageAttachmentRef: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let filePath: String
    let pixelWidth: Int
    let pixelHeight: Int
    let createdAt: Date

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    init(id: UUID = UUID(), fileURL: URL, pixelWidth: Int, pixelHeight: Int, createdAt: Date = Date()) {
        self.id = id
        self.filePath = fileURL.path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }
}

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var text: String
    var attachments: [ImageAttachmentRef]
    var modelLabel: String?
    var createdAt: Date
    var isError: Bool
    /// Documents attached to this message (extracted text). Optional so older saved chats decode.
    var documents: [ChatDocument]?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        attachments: [ImageAttachmentRef] = [],
        documents: [ChatDocument]? = nil,
        modelLabel: String? = nil,
        createdAt: Date = Date(),
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.documents = documents
        self.modelLabel = modelLabel
        self.createdAt = createdAt
        self.isError = isError
    }
}

struct Conversation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date
    var providerID: AIProviderID
    var modelID: String
    /// The single shared thread Capture & Answer writes into. Optional so older saved chats decode.
    var isQuickAnswer: Bool?

    init(
        id: UUID = UUID(),
        title: String = "New conversation",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerID: AIProviderID = .deepSeek,
        modelID: String = "deepseek-flash",
        isQuickAnswer: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.modelID = modelID
        self.isQuickAnswer = isQuickAnswer
    }
}
