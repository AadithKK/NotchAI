import XCTest
@testable import NotchAI

// MARK: - Shared test helpers

private func jsonObject(from data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any], "Expected the request body to be a JSON object")
}

private func firstProviderError(
    from stream: AsyncThrowingStream<ProviderStreamEvent, Error>
) async -> AIProviderError? {
    do {
        for try await _ in stream {}
        return nil
    } catch let error as AIProviderError {
        return error
    } catch {
        return nil
    }
}

private func catalogModel(provider: AIProviderID, id: String) throws -> AIModel {
    try XCTUnwrap(AIModelCatalog.model(provider: provider, id: id), "Missing catalog model \(id)")
}

private let sampleImage = ProviderImage(mimeType: "image/jpeg", base64: "aGVsbG8=")

// MARK: - Mock networking

/// Intercepts `URLSession.shared` requests so provider streaming can be exercised end to end
/// against deterministic SSE responses, with no socket and no real API key.
private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URLRequest] = []
    /// When set, one SSE body is delivered but the load never finishes, simulating an open stream.
    static var hangingBody: String?
    static var onStartLoading: (() -> Void)?
    static var onStopLoading: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.onStartLoading?()

        if let hangingBody = Self.hangingBody {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if !hangingBody.isEmpty {
                client?.urlProtocol(self, didLoad: Data(hangingBody.utf8))
            }
            // Deliberately never call urlProtocolDidFinishLoading.
            return
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.onStopLoading?()
    }
}

private func mockSSEResponse(
    for request: URLRequest,
    status: Int = 200,
    body: String
) -> (HTTPURLResponse, Data) {
    let url = request.url ?? URL(string: "https://invalid.example")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
    )!
    return (response, Data(body.utf8))
}

/// URLSession usually moves `httpBody` into `httpBodyStream` before URLProtocol sees the request.
private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

/// Offline, deterministic coverage for the shared AI provider wire formats, capability rules and
/// stream parsing. No test performs a live network request or requires a real API key.
///
/// Everything lives in one class so `swift test --filter AIProviderTests` runs exactly this suite.
final class AIProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
        MockURLProtocol.requests = []
        MockURLProtocol.hangingBody = nil
        MockURLProtocol.onStartLoading = nil
        MockURLProtocol.onStopLoading = nil
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        MockURLProtocol.requests = []
        MockURLProtocol.hangingBody = nil
        MockURLProtocol.onStartLoading = nil
        MockURLProtocol.onStopLoading = nil
        super.tearDown()
    }

    // MARK: SSE payload extraction

    func testSSEDataPayloadWithSpaceIsExtracted() {
        XCTAssertEqual(SSESupport.dataPayload(from: "data: {\"choices\":[]}"), "{\"choices\":[]}")
    }

    func testSSEDataPayloadWithoutSpaceIsExtracted() {
        XCTAssertEqual(SSESupport.dataPayload(from: "data:{\"choices\":[]}"), "{\"choices\":[]}")
    }

    func testSSECommentLineIsIgnored() {
        XCTAssertNil(SSESupport.dataPayload(from: ": keep-alive"))
    }

    func testSSEEventLineIsIgnored() {
        XCTAssertNil(SSESupport.dataPayload(from: "event: message"))
    }

    func testSSEEmptyLineIsIgnored() {
        XCTAssertNil(SSESupport.dataPayload(from: ""))
    }

    func testSSENonDataFieldsAreIgnored() {
        XCTAssertNil(SSESupport.dataPayload(from: "id: 42"))
        XCTAssertNil(SSESupport.dataPayload(from: "retry: 1000"))
        XCTAssertNil(SSESupport.dataPayload(from: "data"))
    }

    func testSSEDoneSentinelIsReturned() {
        XCTAssertEqual(SSESupport.dataPayload(from: "data: [DONE]"), "[DONE]")
    }

    func testSSETrailingCarriageReturnIsStripped() {
        XCTAssertEqual(SSESupport.dataPayload(from: "data: {\"a\":1}\r"), "{\"a\":1}")
    }

    // MARK: DeepSeek request bodies

    func testDeepSeekTextOnlyBodyHasModelStreamAndSystemMessage() throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let data = try DeepSeekWire.requestBody(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: "You are concise.",
            stream: true
        )
        let body = try jsonObject(from: data)
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual(body["stream"] as? Bool, true)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are concise.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
    }

    func testDeepSeekTextOnlyBodyOmitsBlankSystemMessage() throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let data = try DeepSeekWire.requestBody(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: "   ",
            stream: true
        )
        let body = try jsonObject(from: data)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "system" })
    }

    func testDeepSeekMultiTurnHistoryUsesAssistantStrings() throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let data = try DeepSeekWire.requestBody(
            model: model,
            messages: [
                ProviderMessage(role: .user, text: "Hi"),
                ProviderMessage(role: .assistant, text: "Hello!"),
                ProviderMessage(role: .user, text: "How are you?"),
            ],
            systemPrompt: nil,
            stream: false
        )
        let body = try jsonObject(from: data)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "Hello!")
    }

    func testDeepSeekImageRequestBodyUsesContentArrayWithDataURL() throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let data = try DeepSeekWire.requestBody(
            model: model,
            messages: [
                ProviderMessage(role: .user, text: "What is on screen?", images: [sampleImage])
            ],
            systemPrompt: nil,
            stream: true
        )
        let body = try jsonObject(from: data)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)

        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "What is on screen?")
        XCTAssertEqual(content[1]["type"] as? String, "image_url")

        let imageURL = try XCTUnwrap((content[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertEqual(imageURL, "data:image/jpeg;base64,aGVsbG8=")
    }

    func testDeepSeekRequestBodyRejectsImagesForTextOnlyModel() throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-v4-pro")
        let messages = [ProviderMessage(role: .user, text: "Describe this", images: [sampleImage])]
        XCTAssertThrowsError(
            try DeepSeekWire.requestBody(model: model, messages: messages, systemPrompt: nil, stream: true)
        ) { error in
            XCTAssertEqual(
                error as? AIProviderError,
                AIProviderError.unsupportedImages(modelID: "deepseek-v4-pro", provider: .deepSeek)
            )
        }
    }

    func testDeepSeekStreamRejectsImagesForTextOnlyModelBeforeNetwork() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-v4-pro")
        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Describe this", images: [sampleImage])],
            systemPrompt: nil,
            apiKey: "test-key-not-real"
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(
            error,
            AIProviderError.unsupportedImages(modelID: "deepseek-v4-pro", provider: .deepSeek)
        )
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "Capability rejection must happen before any network call")
    }

    func testDeepSeekStreamRejectsMissingAPIKey() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hi")],
            systemPrompt: nil,
            apiKey: "   "
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(error, AIProviderError.missingAPIKey(provider: .deepSeek))
    }

    func testDeepSeekAvailableModelsRejectsBlankAPIKey() async {
        do {
            _ = try await DeepSeekProvider().availableModels(apiKey: "  ")
            XCTFail("Expected missingAPIKey")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, AIProviderError.missingAPIKey(provider: .deepSeek))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: DeepSeek stream chunks

    func testDeepSeekChunkParsesContentDelta() {
        XCTAssertEqual(
            DeepSeekWire.parseStreamChunk(#"{"choices":[{"delta":{"content":"Hi"}}]}"#),
            ProviderStreamEvent.textDelta("Hi")
        )
    }

    func testDeepSeekChunkParsesReasoningDelta() {
        XCTAssertEqual(
            DeepSeekWire.parseStreamChunk(#"{"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#),
            ProviderStreamEvent.reasoningDelta("thinking")
        )
    }

    func testDeepSeekChunkIgnoresDoneEmptyAndMalformedPayloads() {
        XCTAssertNil(DeepSeekWire.parseStreamChunk("[DONE]"))
        XCTAssertNil(DeepSeekWire.parseStreamChunk(#"{"choices":[{"delta":{}}]}"#))
        XCTAssertNil(DeepSeekWire.parseStreamChunk("not json"))
        XCTAssertNil(DeepSeekWire.parseStreamChunk(""))
    }

    func testDeepSeekErrorBodyMessageExtraction() {
        XCTAssertEqual(
            DeepSeekWire.errorMessage(from: #"{"error":{"message":"Invalid API key"}}"#),
            "Invalid API key"
        )
        XCTAssertNil(DeepSeekWire.errorMessage(from: "   "))
    }

    func testDeepSeekModelListMappingPrefersCatalogMetadata() throws {
        let fixture = #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"},{"id":"deepseek-v5-experimental"}]}"#
        let models = DeepSeekWire.models(fromListBody: Data(fixture.utf8))
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].supportsImages, true)
        XCTAssertEqual(models[1].supportsImages, false)
        XCTAssertEqual(models[2].id, "deepseek-v5-experimental")
        // Unknown ids cannot be guessed as vision capable; they must stay conservative.
        XCTAssertEqual(models[2].supportsImages, false)
        XCTAssertEqual(models[2].provider, .deepSeek)
    }

    func testDeepSeekDocumentedEndpointsAreUsed() {
        XCTAssertEqual(DeepSeekProvider.chatCompletionsURL.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(DeepSeekProvider.modelsURL.absoluteString, "https://api.deepseek.com/models")
    }

    // MARK: Gemini request bodies

    func testGeminiMultiTurnBodyUsesInteractionSteps() throws {
        let model = try catalogModel(provider: .gemini, id: "gemini-3.8-flash")
        let data = try GeminiWire.requestBody(
            model: model,
            messages: [
                ProviderMessage(role: .user, text: "Hi"),
                ProviderMessage(role: .assistant, text: "Hello!"),
                ProviderMessage(role: .user, text: "How are you?"),
            ],
            systemPrompt: "Be brief.",
            stream: true
        )
        let body = try jsonObject(from: data)
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["system_instruction"] as? String, "Be brief.")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["type"] as? String, "user_input")
        XCTAssertEqual(input[1]["type"] as? String, "model_output")
        XCTAssertEqual(input[2]["type"] as? String, "user_input")

        let userContent = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.count, 1)
        XCTAssertEqual(userContent[0]["type"] as? String, "text")
        XCTAssertEqual(userContent[0]["text"] as? String, "Hi")

        let assistantContent = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "Hello!")
    }

    func testGeminiSingleTextTurnUsesUserInputStep() throws {
        let model = try catalogModel(provider: .gemini, id: "gemini-3.8-flash")
        let data = try GeminiWire.requestBody(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: nil,
            stream: true
        )
        let body = try jsonObject(from: data)
        XCTAssertNil(body["system_instruction"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "user_input")

        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Hello")
    }

    func testGeminiImageBodyUsesBase64ImageContentBlock() throws {
        let model = try catalogModel(provider: .gemini, id: "gemini-3.8-flash")
        let data = try GeminiWire.requestBody(
            model: model,
            messages: [
                ProviderMessage(role: .user, text: "Describe this screenshot", images: [sampleImage])
            ],
            systemPrompt: nil,
            stream: true
        )
        let body = try jsonObject(from: data)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "user_input")

        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["data"] as? String, "aGVsbG8=")
        XCTAssertEqual(content[1]["mime_type"] as? String, "image/jpeg")
        // The Interactions API takes raw base64, not a data: URL.
        XCTAssertFalse((content[1]["data"] as? String ?? "").hasPrefix("data:"))
    }

    func testGeminiRequestBodyRejectsImagesForTextOnlyModel() {
        let textOnlyModel = AIModel(
            id: "gemini-text-only-test",
            displayName: "Gemini Text Only (test)",
            provider: .gemini,
            supportsImages: false
        )
        let messages = [ProviderMessage(role: .user, text: "Describe this", images: [sampleImage])]
        XCTAssertThrowsError(
            try GeminiWire.requestBody(model: textOnlyModel, messages: messages, systemPrompt: nil, stream: true)
        ) { error in
            XCTAssertEqual(
                error as? AIProviderError,
                AIProviderError.unsupportedImages(modelID: "gemini-text-only-test", provider: .gemini)
            )
        }
    }

    func testGeminiStreamRejectsImagesForTextOnlyModelBeforeNetwork() async {
        let textOnlyModel = AIModel(
            id: "gemini-text-only-test",
            displayName: "Gemini Text Only (test)",
            provider: .gemini,
            supportsImages: false
        )
        let stream = GeminiProvider().stream(
            model: textOnlyModel,
            messages: [ProviderMessage(role: .user, text: "Describe this", images: [sampleImage])],
            systemPrompt: nil,
            apiKey: "test-key-not-real"
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(
            error,
            AIProviderError.unsupportedImages(modelID: "gemini-text-only-test", provider: .gemini)
        )
        XCTAssertTrue(MockURLProtocol.requests.isEmpty, "Capability rejection must happen before any network call")
    }

    func testGeminiStreamRejectsMissingAPIKey() async {
        let model = AIModel(
            id: "gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash",
            provider: .gemini,
            supportsImages: true
        )
        let stream = GeminiProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hi")],
            systemPrompt: nil,
            apiKey: ""
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(error, AIProviderError.missingAPIKey(provider: .gemini))
    }

    func testGeminiAvailableModelsRejectsBlankAPIKey() async {
        do {
            _ = try await GeminiProvider().availableModels(apiKey: " ")
            XCTFail("Expected missingAPIKey")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, AIProviderError.missingAPIKey(provider: .gemini))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Gemini stream events

    func testGeminiStepDeltaTextEventParses() throws {
        let payload = #"{"event_type":"step.delta","delta":{"type":"text","text":"Hi"}}"#
        XCTAssertEqual(try GeminiWire.parseStreamEvent(payload), ProviderStreamEvent.textDelta("Hi"))
    }

    func testGeminiUnknownEventsAreIgnored() throws {
        XCTAssertNil(try GeminiWire.parseStreamEvent(#"{"event_type":"interaction.completed","interaction":{"id":"int_1"}}"#))
        XCTAssertNil(try GeminiWire.parseStreamEvent(#"{"event_type":"step.start"}"#))
        XCTAssertNil(try GeminiWire.parseStreamEvent("[DONE]"))
    }

    func testGeminiErrorEventThrows() {
        XCTAssertThrowsError(
            try GeminiWire.parseStreamEvent(#"{"error":{"message":"Quota exceeded"}}"#)
        ) { error in
            XCTAssertEqual(error as? AIProviderError, AIProviderError.invalidResponse("Quota exceeded"))
        }
        XCTAssertThrowsError(
            try GeminiWire.parseStreamEvent(#"{"event_type":"error","error":{"message":"Bad request"}}"#)
        ) { error in
            XCTAssertEqual(error as? AIProviderError, AIProviderError.invalidResponse("Bad request"))
        }
    }

    // MARK: Gemini model discovery

    func testGeminiModelListMappingKeepsOnlyChatModels() throws {
        let fixture = """
        {
          "models": [
            {"name": "models/gemini-3.8-flash", "displayName": "Gemini 3.8 Flash", "supportedGenerationMethods": ["generateContent", "countTokens"]},
            {"name": "models/text-embedding-004", "displayName": "Text Embedding 004", "supportedGenerationMethods": ["embedContent"]},
            {"name": "models/veo-3", "displayName": "Veo 3", "supportedGenerationMethods": ["predict"]},
            {"name": "models/gemini-2.0-flash-image", "displayName": "Gemini 2.0 Flash Image", "supportedGenerationMethods": ["generateContent"]}
          ]
        }
        """
        let models = GeminiWire.models(fromListBody: Data(fixture.utf8))
        XCTAssertEqual(models.count, 1)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.id, "gemini-3.8-flash")
        XCTAssertEqual(model.provider, .gemini)
        XCTAssertTrue(model.supportsImages)
        XCTAssertEqual(model.displayName, "Gemini 3.8 Flash")
    }

    func testGeminiModelListMapsUnknownChatModelAsMultimodal() throws {
        let fixture = #"{"models":[{"name":"models/gemini-9.9-flash","displayName":"Gemini 9.9 Flash","supportedGenerationMethods":["generateContent"]}]}"#
        let models = GeminiWire.models(fromListBody: Data(fixture.utf8))
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.id, "gemini-9.9-flash")
        XCTAssertEqual(model.provider, .gemini)
        XCTAssertTrue(model.supportsImages, "All Gemini model versions accept image input")
        XCTAssertEqual(model.displayName, "Gemini 9.9 Flash")
    }

    func testGeminiModelListReturnsEmptyForUnusableBodies() {
        XCTAssertTrue(GeminiWire.models(fromListBody: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(GeminiWire.models(fromListBody: Data(#"{"models":[]}"#.utf8)).isEmpty)
    }

    func testGeminiDocumentedEndpointAndSSEParameterAreUsed() {
        let interactions = GeminiProvider.interactionsURL(streaming: true)
        XCTAssertEqual(interactions.path, "/v1beta/interactions")
        let components = URLComponents(url: interactions, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "alt" }?.value, "sse")

        let models = GeminiProvider.modelsURL(apiKey: "test-key")
        let modelComponents = URLComponents(url: models, resolvingAgainstBaseURL: false)
        XCTAssertEqual(modelComponents?.path, "/v1beta/models")
        XCTAssertNil(modelComponents?.queryItems?.first { $0.name == "key" })
        XCTAssertEqual(GeminiProvider.apiRevision, "2026-05-20")
    }

    // MARK: End-to-end streaming over a mocked transport

    func testDeepSeekStreamSendsDocumentedRequestAndDeliversSSEEvents() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try jsonObject(from: bodyData)
            XCTAssertEqual(body["model"] as? String, "deepseek-flash")
            XCTAssertEqual(body["stream"] as? Bool, true)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["role"] as? String, "system")

            let sseBody = """
            data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}

            data: {"choices":[{"delta":{"content":"Hi"}}]}

            data: {"choices":[{"delta":{"content":" there"}}]}

            data: [DONE]

            """
            return mockSSEResponse(for: request, body: sseBody)
        }

        var events: [ProviderStreamEvent] = []
        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: "Be brief.",
            apiKey: "fake-key"
        )
        for try await event in stream { events.append(event) }

        XCTAssertEqual(
            events,
            [
                ProviderStreamEvent.reasoningDelta("thinking"),
                ProviderStreamEvent.textDelta("Hi"),
                ProviderStreamEvent.textDelta(" there"),
            ]
        )
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testDeepSeekStreamMapsUnauthorizedResponseToInvalidAPIKey() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        MockURLProtocol.handler = { request in
            mockSSEResponse(
                for: request,
                status: 401,
                body: #"{"error":{"message":"Authentication Fails"}}"#
            )
        }
        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: nil,
            apiKey: "fake-key"
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(error, AIProviderError.invalidAPIKey(provider: .deepSeek))
    }

    func testDeepSeekStreamMapsServerErrorToHTTPErrorWithProviderMessage() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        MockURLProtocol.handler = { request in
            mockSSEResponse(
                for: request,
                status: 429,
                body: #"{"error":{"message":"Rate limit reached for requests"}}"#
            )
        }
        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: nil,
            apiKey: "fake-key"
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(
            error,
            AIProviderError.http(status: 429, message: "Rate limit reached for requests")
        )
    }

    func testGeminiStreamSendsDocumentedRequestAndDeliversSSEEvents() async throws {
        let model = try catalogModel(provider: .gemini, id: "gemini-3.8-flash")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fake-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Api-Revision"), "2026-05-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try jsonObject(from: bodyData)
            XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertEqual(body["store"] as? Bool, false)

            let sseBody = """
            data: {"event_type":"step.start"}

            data: {"event_type":"step.delta","delta":{"type":"text","text":"Hi"}}

            data: {"event_type":"step.delta","delta":{"type":"text","text":" there"}}

            data: {"event_type":"interaction.completed","interaction":{"id":"int_1"}}

            """
            return mockSSEResponse(for: request, body: sseBody)
        }

        var events: [ProviderStreamEvent] = []
        let stream = GeminiProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: "Be brief.",
            apiKey: "fake-key"
        )
        for try await event in stream { events.append(event) }

        XCTAssertEqual(events, [ProviderStreamEvent.textDelta("Hi"), ProviderStreamEvent.textDelta(" there")])
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testGeminiStreamMapsForbiddenResponseToInvalidAPIKey() async throws {
        let model = try catalogModel(provider: .gemini, id: "gemini-3.8-flash")
        MockURLProtocol.handler = { request in
            mockSSEResponse(
                for: request,
                status: 403,
                body: #"{"error":{"message":"API key not valid"}}"#
            )
        }
        let stream = GeminiProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: nil,
            apiKey: "fake-key"
        )
        let error = await firstProviderError(from: stream)
        XCTAssertEqual(error, AIProviderError.invalidAPIKey(provider: .gemini))
    }

    // MARK: Cancellation

    func testCancellingConsumerStopsOpenStreamAndUnderlyingURLTask() async throws {
        let model = try catalogModel(provider: .deepSeek, id: "deepseek-flash")
        let started = expectation(description: "request started")
        let stopped = expectation(description: "URL task stopped")
        MockURLProtocol.hangingBody = """
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        """
        MockURLProtocol.onStartLoading = { started.fulfill() }
        MockURLProtocol.onStopLoading = { stopped.fulfill() }

        let stream = DeepSeekProvider().stream(
            model: model,
            messages: [ProviderMessage(role: .user, text: "Hello")],
            systemPrompt: nil,
            apiKey: "fake-key"
        )
        let consumerFinished = expectation(description: "consumer finished")
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation may surface as an error or as a normal end of iteration.
            }
            consumerFinished.fulfill()
        }

        await fulfillment(of: [started], timeout: 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        consumer.cancel()
        // The stream must end even though the response body never finishes, and the URLSession
        // task must be told to stop: `onTermination` cancels the producer task.
        await fulfillment(of: [consumerFinished, stopped], timeout: 3)
        _ = await consumer.value
    }
}
