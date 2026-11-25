import AppKit
import Foundation

/// Observable settings with JSON persistence, Keychain-backed credentials and discovered model lists.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            onSettingsChanged?(settings)
        }
    }

    @Published private(set) var keyPresence: [AIProviderID: Bool] = [:]
    @Published private(set) var discoveredModels: [AIProviderID: [AIModel]] = [:]
    @Published var credentialError: String?

    /// Side effects that depend on settings (appearance, dock icon, launch at login, hot key).
    var onSettingsChanged: ((AppSettings) -> Void)?

    private let keychain: SecureKeyStoring
    private let defaults: UserDefaults
    private static let storageKey = "NotchAI.settings.v1"

    init(keychain: SecureKeyStoring = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        refreshKeyPresence()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
        // macOS may kill the app right after a permission grant; flush so the change survives it.
        defaults.synchronize()
    }

    func refreshKeyPresence() {
        var presence: [AIProviderID: Bool] = [:]
        for provider in AIProviderID.allCases {
            presence[provider] = !(apiKey(for: provider) ?? "").isEmpty
        }
        keyPresence = presence
    }

    func apiKey(for provider: AIProviderID) -> String? {
        keychain.value(for: provider.keychainAccount)
    }

    func saveAPIKey(_ value: String, for provider: AIProviderID) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try keychain.set(trimmed.isEmpty ? nil : trimmed, for: provider.keychainAccount)
        refreshKeyPresence()
    }

    func removeAPIKey(for provider: AIProviderID) throws {
        try keychain.set(nil, for: provider.keychainAccount)
        refreshKeyPresence()
    }

    func removeAllCredentials() throws {
        try keychain.removeAll()
        refreshKeyPresence()
    }

    func setDiscoveredModels(_ models: [AIModel], for provider: AIProviderID) {
        discoveredModels[provider] = models
    }

    /// Documented defaults first, then live-discovered models not already known.
    func models(for provider: AIProviderID) -> [AIModel] {
        var merged = AIModelCatalog.defaults(for: provider)
        for model in discoveredModels[provider] ?? [] where !merged.contains(where: { $0.id == model.id }) {
            merged.append(model)
        }
        return merged
    }

    var allModels: [AIModel] {
        AIProviderID.allCases.flatMap { models(for: $0) }
    }

    var selectedModel: AIModel {
        allModels.first { model in
            model.provider == settings.defaultProvider && model.id == settings.defaultModelID
        } ?? AIModelCatalog.defaultModel(for: settings.defaultProvider)
    }

    func select(model: AIModel) {
        settings.defaultProvider = model.provider
        settings.defaultModelID = model.id
    }

    func restoreDefaults() {
        settings = AppSettings()
    }
}
