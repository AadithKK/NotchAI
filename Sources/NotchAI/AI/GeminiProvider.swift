import Foundation
import os

/// Google Gemini provider over the current Interactions API.
///
/// Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/interactions` with
/// `x-goog-api-key` and `Api-Revision: 2026-05-20`. Streams SSE `step.delta` events when
/// `stream: true` is combined with `?alt=sse`.
struct GeminiProvider: AIProvider {
    static let baseURL = URL(string: "https://generativelanguage.googleapis.com")!

    /// Pinned Interactions API revision; documented shape for this app's payloads.
    static let apiRevision = "2026-05-20"

    /// `POST` target for interactions. Streaming requests append `?alt=sse`.
    static func interactionsURL(streaming: Bool) -> URL {
        let base = baseURL.appendingPathComponent("v1beta/interactions")
        guard streaming, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return components.url ?? base
    }

    /// Credentials belong in the request header, never in a URL or its diagnostics.
    static func modelsURL(apiKey: String) -> URL {
        baseURL.appendingPathComponent("v1beta/models")
    }

    let id: AIProviderID = .gemini

    func stream(model: AIModel, messages: [ProviderMessage], systemPrompt: String?, apiKey: String) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Log.ai.error("Gemini request rejected: no API key configured.")
            return ProviderSSE.failed(.missingAPIKey(provider: .gemini))
        }

        let body: Data
        do {
            body = try GeminiWire.requestBody(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                stream: true
            )
        } catch let error as AIProviderError {
            // Capability errors are rejected synchronously, before any network call.
            Log.ai.error("Gemini request rejected before network: \(error.localizedDescription, privacy: .public)")
            return ProviderSSE.failed(error)
        } catch {
            Log.ai.error("Gemini request body could not be encoded: \(error.localizedDescription, privacy: .public)")
            return ProviderSSE.failed(.invalidResponse("The request could not be encoded as JSON."))
        }

        var request = URLRequest(url: Self.interactionsURL(streaming: true))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiRevision, forHTTPHeaderField: "Api-Revision")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body

        Log.ai.debug("Gemini streaming request: model=\(model.id, privacy: .public), messages=\(messages.count, privacy: .public)")
        return ProviderSSE.eventStream(
            request: request,
            provider: .gemini,
            mapPayload: { payload in try GeminiWire.parseStreamEvent(payload) }
        )
    }

    func availableModels(apiKey: String) async throws -> [AIModel] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIProviderError.missingAPIKey(provider: .gemini)
        }

        var request = URLRequest(url: Self.modelsURL(apiKey: key))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("Google did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderSupport.httpError(status: http.statusCode,
                body: String(decoding: data, as: UTF8.self), provider: .gemini)
        }
        let discovered = GeminiWire.models(fromListBody: data)
        guard !discovered.isEmpty else {
            throw AIProviderError.invalidResponse("Google returned no compatible chat models. Try refreshing again later.")
        }
        return discovered
    }
}
