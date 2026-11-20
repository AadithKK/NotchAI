import Foundation
import os

// MARK: - SSE primitives

/// Minimal Server-Sent Events parsing shared by both providers.
///
/// The providers only need the `data:` payloads of a stream: OpenAI-style JSON chunks for DeepSeek
/// and Interactions events for Gemini. Everything else (comments, `event:`/`id:`/`retry:` fields,
/// blank dispatch lines) is skipped.
enum SSESupport {
    /// The terminal payload used by OpenAI-compatible streams (and accepted defensively elsewhere).
    static let doneSentinel = "[DONE]"

    /// Returns the payload of an SSE `data:` line, or `nil` when the line carries no data.
    ///
    /// Accepts both `data: {json}` and `data:{json}` forms, strips a trailing CR, and ignores
    /// comments (`: keep-alive`), blank lines and non-`data` fields (`event:`, `id:`, `retry:`).
    static func dataPayload(from line: String) -> String? {
        var text = line
        // `AsyncLineSequence` normally strips line endings, but be defensive for CRLF streams.
        while let last = text.last, last == "\n" || last == "\r" {
            text.removeLast()
        }
        guard !text.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // SSE comments start with a colon.
        guard text.first != ":" else { return nil }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        guard String(text[text.startIndex..<colon]) == "data" else { return nil }
        var payload = String(text[text.index(after: colon)...])
        // The SSE grammar allows exactly one optional space after the colon.
        if payload.first == " " { payload.removeFirst() }
        payload = payload.trimmingCharacters(in: .newlines)
        return payload.isEmpty ? nil : payload
    }
}

// MARK: - Shared wire helpers

/// Small pure helpers shared by the DeepSeek and Gemini wire formats.
enum ProviderSupport {
    /// Extracts a human-readable message from an HTTP error body.
    ///
    /// Recognises the common `{"error":{"message":"…"}}` shape (used by both providers), a top-level
    /// `message`/`detail`, and falls back to the raw body when it is not JSON at all. Parsed JSON
    /// without a recognisable error shape returns `nil` so raw JSON is never shown to the user.
    static func errorMessage(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                if let message = message(fromErrorValue: dictionary["error"]) { return message }
                if let message = dictionary["message"] as? String { return normalizeMessage(message) }
                if let message = dictionary["detail"] as? String { return normalizeMessage(message) }
            }
            return nil
        }
        return normalizeMessage(trimmed)
    }

    /// Maps a non-2xx HTTP response onto the shared provider error type.
    ///
    /// Preserve Google's permission/billing detail instead of labelling every 403 a bad key.
    /// Authentication failures retain the actionable key message.
    static func httpError(status: Int, body: String, provider: AIProviderID) -> AIProviderError {
        let explicitBadKey = body.contains("API_KEY_INVALID") || body.localizedCaseInsensitiveContains("API key not valid")
        if status == 401 || (status == 403 && (provider != .gemini || explicitBadKey)) {
            return .invalidAPIKey(provider: provider)
        }
        let fallback = "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
        let message = errorMessage(from: body).map { truncated($0) } ?? fallback
        return .http(status: status, message: message)
    }

    /// Collapses whitespace and truncates to `maxLength` for display.
    static func truncated(_ text: String, maxLength: Int = 300) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    /// Turns a provider model identifier into a presentable label, e.g. `gemini-3.8-flash` →
    /// `Gemini 3.8 Flash`. Used only for models with no documented catalog metadata.
    static func humanizedID(_ id: String) -> String {
        id.split(separator: "-")
            .map { part -> String in
                guard let first = part.first else { return String(part) }
                if first.isNumber || first.isUppercase { return String(part) }
                return first.uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    /// True when the string is empty or only whitespace.
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func message(fromErrorValue value: Any?) -> String? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] {
            if let message = dictionary["message"] as? String { return normalizeMessage(message) }
            if let message = dictionary["detail"] as? String { return normalizeMessage(message) }
            return nil
        }
        if let message = value as? String { return normalizeMessage(message) }
        return nil
    }

    private static func normalizeMessage(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Streaming bridge

/// Bridges `URLSession.bytes(for:)` line iteration into an `AsyncThrowingStream`.
///
/// The provider-specific decoding lives in the `mapPayload` closure, so this type handles the parts
/// both providers share: the request, HTTP status mapping, SSE framing, `[DONE]`, cancellation and
/// network error normalisation.
enum ProviderSSE {
    /// How much of an error response body to read for the user-facing message.
    static let maxErrorBodyBytes = 8 * 1024

    /// A stream that fails immediately, without making any network request.
    static func failed(_ error: AIProviderError) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    /// Performs the request and yields decoded events until the stream ends, fails or is cancelled.
    static func eventStream(
        request: URLRequest,
        provider: AIProviderID,
        mapPayload: @escaping @Sendable (String) throws -> ProviderStreamEvent?
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Retry transient overload/connection failures only before any output has
                    // reached the caller. Never replay a partial answer or switch models.
                    var attempt = 0
                    while true {
                        var deliveredOutput = false
                        do {
                            try await run(request: request, provider: provider,
                                continuation: continuation, mapPayload: mapPayload,
                                deliveredOutput: &deliveredOutput)
                            break
                        } catch {
                            guard !deliveredOutput, attempt < 2, isTransient(error) else { throw error }
                            attempt += 1
                            try await Task.sleep(for: .seconds(Double(attempt)))
                        }
                    }
                    continuation.finish()
                } catch let error as AIProviderError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: AIProviderError.cancelled)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: AIProviderError.cancelled)
                } catch {
                    Log.ai.error("Provider stream failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: AIProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                // Cancelling this producer task cancels the URLSession byte-stream task it is
                // awaiting (URLSession's async request methods are cancellation aware), so a
                // cancelled consumer stops network work promptly and the producer then finishes
                // with `AIProviderError.cancelled`.
                task.cancel()
            }
        }
    }

    private static func run(
        request: URLRequest,
        provider: AIProviderID,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation,
        mapPayload: @Sendable (String) throws -> ProviderStreamEvent?,
        deliveredOutput: inout Bool
    ) async throws {
        try Task.checkCancellation()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("The provider response was not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = await limitedErrorBody(from: bytes, limit: maxErrorBodyBytes)
            throw ProviderSupport.httpError(status: http.statusCode, body: body, provider: provider)
        }
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            guard let payload = SSESupport.dataPayload(from: line) else { continue }
            if payload == SSESupport.doneSentinel { return }
            if let event = try mapPayload(payload) {
                deliveredOutput = true
                continuation.yield(event)
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? AIProviderError, case let .http(status, _) = error {
            return [500, 502, 503, 504].contains(status)
        }
        if let error = error as? URLError {
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code)
        }
        return false
    }

    private static func limitedErrorBody(from bytes: URLSession.AsyncBytes, limit: Int) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A partial error body is still better than no message at all.
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - DeepSeek wire format

/// Pure request/response shaping for DeepSeek's OpenAI-compatible chat completions API.
enum DeepSeekWire {
    /// Builds the JSON body for `POST /chat/completions`.
    ///
    /// Text-only user turns stay plain strings; user turns with images use the documented content
    /// array (`text` + `image_url` data URLs). Throws `unsupportedImages` when the selected model is
    /// not documented as image capable.
    static func requestBody(
        model: AIModel,
        messages: [ProviderMessage],
        systemPrompt: String?,
        stream: Bool
    ) throws -> Data {
        try validateImages(model: model, messages: messages, provider: .deepSeek)

        var wireMessages: [[String: Any]] = []
        if let systemPrompt, !ProviderSupport.isBlank(systemPrompt) {
            wireMessages.append(["role": "system", "content": systemPrompt])
        }
        for message in messages {
            switch message.role {
            case .assistant:
                // Assistant history is always plain text; the documented API has no image content
                // for assistant turns, so any images on them are not representable and are dropped.
                wireMessages.append(["role": "assistant", "content": message.text])
            case .user:
                guard !message.images.isEmpty else {
                    wireMessages.append(["role": "user", "content": message.text])
                    continue
                }
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty {
                    blocks.append(["type": "text", "text": message.text])
                }
                for image in message.images {
                    blocks.append([
                        "type": "image_url",
                        "image_url": ["url": dataURL(for: image)],
                    ])
                }
                wireMessages.append(["role": "user", "content": blocks])
            }
        }

        let body: [String: Any] = [
            "model": model.id,
            "messages": wireMessages,
            "stream": stream,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Decodes one `choices[0].delta` chunk into a stream event; `nil` for keep-alives/finish chunks.
    static func parseStreamChunk(_ data: String) -> ProviderStreamEvent? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != SSESupport.doneSentinel else { return nil }
        guard let payload = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else {
            return nil
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            return .textDelta(content)
        }
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            return .reasoningDelta(reasoning)
        }
        return nil
    }

    /// Maps a `GET /models` body onto selectable models, preferring documented catalog metadata.
    static func models(fromListBody data: Data) -> [AIModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let entries = dictionary["data"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var models: [AIModel] = []
        for entry in entries {
            guard let rawID = entry["id"] as? String else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            if let known = AIModelCatalog.model(provider: .deepSeek, id: id) {
                models.append(known)
            } else {
                models.append(AIModel(
                    id: id,
                    displayName: ProviderSupport.humanizedID(id),
                    provider: .deepSeek,
                    supportsImages: false,
                    note: "Discovered live — image support unverified"
                ))
            }
        }
        return models
    }

    /// Extracts a message from a DeepSeek error body (`{"error":{"message":"…"}}`).
    static func errorMessage(from body: String) -> String? {
        ProviderSupport.errorMessage(from: body)
    }

    private static func dataURL(for image: ProviderImage) -> String {
        "data:\(normalizedMimeType(image.mimeType));base64,\(image.base64)"
    }
}

// MARK: - Gemini wire format

/// Pure request/response shaping for Gemini's Interactions API.
enum GeminiWire {
    /// Model-id fragments for known non-chat Gemini models, which must never reach the selector.
    static let nonChatModelFragments = [
        "embedding", "veo", "lyria", "imagen", "tts", "image", "live", "transcribe",
        "robotics", "computer-use", "omni", "nano-banana", "gemma",
    ]

    /// Builds the JSON body for `POST /v1beta/interactions`.
    ///
    /// History is sent as an ordered array of steps (`user_input` / `model_output`) because the
    /// client owns the conversation when `store` is `false`. Throws `unsupportedImages` when the
    /// selected model is not documented as image capable.
    static func requestBody(
        model: AIModel,
        messages: [ProviderMessage],
        systemPrompt: String?,
        stream: Bool
    ) throws -> Data {
        try validateImages(model: model, messages: messages, provider: .gemini)

        var steps: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .assistant:
                steps.append([
                    "type": "model_output",
                    "content": [["type": "text", "text": message.text]],
                ])
            case .user:
                var content: [[String: Any]] = []
                if !message.text.isEmpty || message.images.isEmpty {
                    content.append(["type": "text", "text": message.text])
                }
                for image in message.images {
                    // Interactions API expects raw base64 plus an explicit MIME type.
                    content.append([
                        "type": "image",
                        "data": image.base64,
                        "mime_type": normalizedMimeType(image.mimeType),
                    ])
                }
                steps.append(["type": "user_input", "content": content])
            }
        }

        var body: [String: Any] = [
            "model": model.id,
            "input": steps,
            "stream": stream,
            "store": false,
        ]
        if let systemPrompt, !ProviderSupport.isBlank(systemPrompt) {
            body["system_instruction"] = systemPrompt
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Decodes one Interactions SSE event into a stream event.
    ///
    /// Only `step.delta` events with a `text` delta become text; completed/unknown events are
    /// ignored. Explicit error payloads throw so the caller can surface the provider's message.
    static func parseStreamEvent(_ data: String) throws -> ProviderStreamEvent? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != SSESupport.doneSentinel else { return nil }
        guard let payload = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any] else {
            // Non-JSON payloads (protocol keep-alives) are skipped rather than ending the stream.
            return nil
        }

        let eventType = dictionary["event_type"] as? String ?? ""
        if dictionary["error"] != nil || eventType == "error" || eventType == "interaction.failed" {
            let message = errorMessage(from: trimmed)
                ?? "Gemini reported a \(eventType.isEmpty ? "stream" : eventType) error."
            throw AIProviderError.invalidResponse(message)
        }

        guard eventType == "step.delta",
              let delta = dictionary["delta"] as? [String: Any],
              (delta["type"] as? String) == "text",
              let text = delta["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return .textDelta(text)
    }

    /// Maps a `GET /v1beta/models` body onto selectable chat models.
    ///
    /// Documented catalog entries keep their curated metadata; other Gemini chat models are exposed
    /// as multimodal (every Gemini model version accepts image input). Non-chat models are excluded.
    static func models(fromListBody data: Data) -> [AIModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let entries = dictionary["models"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var models: [AIModel] = []
        for entry in entries {
            guard let name = entry["name"] as? String else { continue }
            let stripped = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            let id = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seen.insert(id).inserted,
                  isChatModel(id: id, entry: entry) else {
                continue
            }
            if let known = AIModelCatalog.model(provider: .gemini, id: id) {
                models.append(known)
                continue
            }
            let apiDisplayName = (entry["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName: String
            if let apiDisplayName, !apiDisplayName.isEmpty {
                displayName = apiDisplayName
            } else {
                displayName = ProviderSupport.humanizedID(id)
            }
            models.append(AIModel(
                id: id,
                displayName: displayName,
                provider: .gemini,
                supportsImages: true,
                note: "Discovered live — multimodal"
            ))
        }
        return models
    }

    /// Extracts a message from a Gemini error body (`{"error":{"message":"…"}}`).
    static func errorMessage(from body: String) -> String? {
        ProviderSupport.errorMessage(from: body)
    }

    // MARK: Helpers

    private static func isChatModel(id: String, entry: [String: Any]) -> Bool {
        let lowered = id.lowercased()
        if nonChatModelFragments.contains(where: { lowered.contains($0) }) {
            return false
        }
        if let methods = entry["supportedGenerationMethods"] as? [String], !methods.isEmpty {
            return methods.contains("generateContent")
        }
        // Missing method metadata is unusual but not fatal; id filtering above still applies.
        return true
    }
}

// MARK: - Shared request validation

/// Rejects image attachments for models that are not documented as image capable.
///
/// This runs while the request body is being built, i.e. before any network call, so the caller can
/// report a capability error immediately and is never silently switched to another model.
private func validateImages(model: AIModel, messages: [ProviderMessage], provider: AIProviderID) throws {
    guard !model.supportsImages else { return }
    let hasImages = messages.contains { !$0.images.isEmpty }
    if hasImages {
        throw AIProviderError.unsupportedImages(modelID: model.id, provider: provider)
    }
}

/// Normalizes a provider image MIME type, defaulting to JPEG when the caller left it blank.
private func normalizedMimeType(_ mimeType: String) -> String {
    let trimmed = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "image/jpeg" : trimmed
}
