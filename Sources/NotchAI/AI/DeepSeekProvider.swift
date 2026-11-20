import Foundation
import os

/// DeepSeek OpenAI-compatible chat provider.
///
/// Endpoint: `POST https://api.deepseek.com/chat/completions` with `Authorization: Bearer`.
/// Documented vision model: `deepseek-flash` accepts `image_url` data URLs in user messages.
/// Legacy names (`deepseek-v4-flash`, `deepseek-v4-flash-vision-exp`) are served by the same model.
struct DeepSeekProvider: AIProvider {
    static let baseURL = URL(string: "https://api.deepseek.com")!

    /// `POST` target for streaming chat completions.
    static var chatCompletionsURL: URL { baseURL.appendingPathComponent("chat/completions") }

    /// `GET` target used for live model discovery.
    static var modelsURL: URL { baseURL.appendingPathComponent("models") }

    let id: AIProviderID = .deepSeek

    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Log.ai.error("DeepSeek request rejected: no API key configured.")
            return ProviderSSE.failed(.missingAPIKey(provider: .deepSeek))
        }

        let body: Data
        do {
            body = try DeepSeekWire.requestBody(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                stream: true
            )
        } catch let error as AIProviderError {
            // Capability errors are rejected synchronously, before any network call.
            Log.ai.error("DeepSeek request rejected before network: \(error.localizedDescription, privacy: .public)")
            return ProviderSSE.failed(error)
        } catch {
            Log.ai.error("DeepSeek request body could not be encoded: \(error.localizedDescription, privacy: .public)")
            return ProviderSSE.failed(.invalidResponse("The request could not be encoded as JSON."))
        }

        var request = URLRequest(url: Self.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body

        Log.ai.debug("DeepSeek streaming request: model=\(model.id, privacy: .public), messages=\(messages.count, privacy: .public)")
        return ProviderSSE.eventStream(
            request: request,
            provider: .deepSeek,
            mapPayload: { payload in DeepSeekWire.parseStreamChunk(payload) }
        )
    }

    func availableModels(apiKey: String) async throws -> [AIModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIProviderError.missingAPIKey(provider: .deepSeek)
        }

        var request = URLRequest(url: Self.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Log.ai.error("DeepSeek model discovery returned a non-HTTP response; using built-in models.")
                return AIModelCatalog.defaultDeepSeekModels
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIProviderError.invalidAPIKey(provider: .deepSeek)
            }
            guard (200..<300).contains(http.statusCode) else {
                Log.ai.error("DeepSeek model discovery failed with HTTP \(http.statusCode, privacy: .public); using built-in models.")
                return AIModelCatalog.defaultDeepSeekModels
            }
            let discovered = DeepSeekWire.models(fromListBody: data)
            guard !discovered.isEmpty else {
                Log.ai.error("DeepSeek model discovery returned no usable models; using built-in models.")
                return AIModelCatalog.defaultDeepSeekModels
            }
            return discovered
        } catch let error as AIProviderError {
            if case .invalidAPIKey = error { throw error }
            Log.ai.error("DeepSeek model discovery failed: \(error.localizedDescription, privacy: .public); using built-in models.")
            return AIModelCatalog.defaultDeepSeekModels
        } catch {
            Log.ai.error("DeepSeek model discovery failed: \(error.localizedDescription, privacy: .public); using built-in models.")
            return AIModelCatalog.defaultDeepSeekModels
        }
    }
}
