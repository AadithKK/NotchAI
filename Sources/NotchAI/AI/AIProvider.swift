import Foundation

/// Provider identity for the two supported backends.
enum AIProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepSeek
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        }
    }

    var keychainAccount: String {
        switch self {
        case .deepSeek: return "deepseek-api-key"
        case .gemini: return "gemini-api-key"
        }
    }
}

/// One selectable model. `supportsImages` is a documented capability, not a guess from the name.
struct AIModel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let displayName: String
    let provider: AIProviderID
    let supportsImages: Bool
    let note: String?

    init(id: String, displayName: String, provider: AIProviderID, supportsImages: Bool, note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.supportsImages = supportsImages
        self.note = note
    }

    /// Label used by selectors: "DeepSeek V4.1 Flash — Vision, screenshots supported".
    var label: String {
        guard let note else { return displayName }
        return "\(displayName) — \(note)"
    }
}

/// An image supplied inline to a provider as base64 data.
struct ProviderImage: Hashable, Sendable {
    let mimeType: String
    let base64: String
}

struct ProviderMessage: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String
    var images: [ProviderImage]

    init(role: Role, text: String, images: [ProviderImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

/// Incremental events yielded by a provider stream.
enum ProviderStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case reasoningDelta(String)
}

enum AIProviderError: LocalizedError, Equatable {
    case missingAPIKey(provider: AIProviderID)
    case invalidAPIKey(provider: AIProviderID)
    case unsupportedImages(modelID: String, provider: AIProviderID)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case cancelled
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            return "Add your \(provider.displayName) API key in Settings → AI Providers."
        case let .invalidAPIKey(provider):
            return "\(provider.displayName) rejected the API key. Check it in Settings → AI Providers."
        case let .unsupportedImages(modelID, provider):
            return "\(modelID) does not accept screenshots. Pick an image-capable model for \(provider.displayName) in Settings → AI Providers."
        case let .http(status, message):
            return "Provider returned HTTP \(status): \(message)"
        case let .invalidResponse(message):
            return "Unexpected provider response: \(message)"
        case .cancelled:
            return "Generation stopped."
        case let .network(message):
            return "Network error: \(message)"
        }
    }
}

/// Streaming chat provider contract. Implementations must not read credentials from anywhere but the
/// supplied `apiKey`, and must never change the requested model.
protocol AIProvider: Sendable {
    var id: AIProviderID { get }
    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error>
    func availableModels(apiKey: String) async throws -> [AIModel]
}

/// Documented model capabilities, used before live discovery and as the offline fallback.
enum AIModelCatalog {
    static let defaultDeepSeekModels: [AIModel] = [
        AIModel(
            id: "deepseek-flash",
            displayName: "DeepSeek V4.1 Flash",
            provider: .deepSeek,
            supportsImages: true,
            note: "Vision — screenshots supported"
        ),
        AIModel(
            id: "deepseek-v4-pro",
            displayName: "DeepSeek V4 Pro",
            provider: .deepSeek,
            supportsImages: false,
            note: "Text only — screenshots not supported"
        ),
    ]

    static let defaultGeminiModels: [AIModel] = [
        AIModel(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", provider: .gemini, supportsImages: true, note: "Current flagship Flash"),
        AIModel(id: "gemini-flash-latest", displayName: "Gemini Flash (latest)", provider: .gemini, supportsImages: true, note: "Rolling alias"),
        AIModel(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash Preview", provider: .gemini, supportsImages: true, note: "Preview"),
        AIModel(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", provider: .gemini, supportsImages: true, note: "Fast, low cost"),
        AIModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, supportsImages: true, note: "Previous generation"),
    ]

    static func defaults(for provider: AIProviderID) -> [AIModel] {
        switch provider {
        case .deepSeek: return defaultDeepSeekModels
        case .gemini: return defaultGeminiModels
        }
    }

    static func defaultModel(for provider: AIProviderID) -> AIModel {
        defaults(for: provider)[0]
    }

    /// Normalize a live-discovered identifier using the documented default when we have one.
    static func model(provider: AIProviderID, id: String) -> AIModel? {
        defaults(for: provider).first { $0.id == id }
    }
}

/// Holds the two provider implementations used by the chat manager.
@MainActor
final class AIProviderRegistry {
    let deepSeek: any AIProvider
    let gemini: any AIProvider

    init(deepSeek: any AIProvider = DeepSeekProvider(), gemini: any AIProvider = GeminiProvider()) {
        self.deepSeek = deepSeek
        self.gemini = gemini
    }

    func provider(for id: AIProviderID) -> any AIProvider {
        switch id {
        case .deepSeek: return deepSeek
        case .gemini: return gemini
        }
    }
}
