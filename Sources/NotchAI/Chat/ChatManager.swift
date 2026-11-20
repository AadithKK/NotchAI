import AppKit
import Foundation

/// Owns conversations, the composer state, streaming, regeneration and attachment handling.
@MainActor
final class ChatManager: ObservableObject {
    @Published private(set) var conversations: [Conversation]
    @Published private(set) var selectedConversationID: UUID
    @Published private(set) var isStreaming = false
    @Published private(set) var pendingAttachments: [ImageAttachmentRef] = []
    @Published private(set) var pendingDocuments: [ChatDocument] = []
    @Published private(set) var statusText: String?
    @Published var errorMessage: String?
    @Published var draft = ""
    @Published private(set) var isPreparingSend = false
    /// Incremented when a response finishes successfully; the collapsed island pops a transient
    /// "done" badge to the side instead of showing a permanent status dot.
    @Published private(set) var completionPulse = 0

    /// Resolved by the app from `SettingsStore` so the manager never owns credentials.
    var resolveModel: () -> AIModel = { AIModelCatalog.defaultModel(for: .deepSeek) }
    var resolveAPIKey: (AIProviderID) -> String? = { _ in nil }

    private let store: ChatPersisting
    private let providers: AIProviderRegistry
    private let selectionDefaults: UserDefaults
    private static let selectedConversationKey = "NotchAI.selectedConversationID"
    private var lastStreamingPersist = Date.distantPast
    private var streamTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    private var retryContext: (model: AIModel, apiKey: String, history: [ChatMessage])?
    private var stopRequested = false
    private var receivedText = false
    private var resetAfterPreparation = false
    private var pendingDelta = ""
    private var deltaFlushWork: DispatchWorkItem?

    init(
        store: ChatPersisting,
        providers: AIProviderRegistry,
        selectionDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.providers = providers
        self.selectionDefaults = selectionDefaults
        let loaded = store.loadConversations()
        if loaded.isEmpty {
            let conversation = Conversation()
            self.conversations = [conversation]
            self.selectedConversationID = conversation.id
        } else {
            self.conversations = loaded
            let stored = selectionDefaults.string(forKey: Self.selectedConversationKey)
                .flatMap(UUID.init(uuidString:))
            if let stored, loaded.contains(where: { $0.id == stored }) {
                self.selectedConversationID = stored
            } else {
                self.selectedConversationID = loaded[0].id
            }
        }
        persistSelection()
    }

    convenience init(store: ChatPersisting = JSONChatStore()) {
        self.init(
            store: store,
            providers: AIProviderRegistry(deepSeek: DeepSeekProvider(), gemini: GeminiProvider())
        )
    }

    // MARK: - Conversation access

    var currentConversation: Conversation {
        conversations.first { $0.id == selectedConversationID } ?? conversations[0]
    }

    var canAttachImages: Bool {
        resolveModel().supportsImages
    }

    private func updateCurrent(_ mutate: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }) else { return }
        mutate(&conversations[index])
        conversations[index].updatedAt = Date()
    }

    func newConversation() {
        guard !isStreaming, !isPreparingSend else { return }
        let model = resolveModel()
        let conversation = Conversation(providerID: model.provider, modelID: model.id)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        persist()
        persistSelection()
    }

    static let quickAnswerTitle = "Quick Answers"

    /// Selects the one shared Capture & Answer thread, creating it on first use, so repeated
    /// captures stay in a single chat instead of adding a conversation each time.
    func selectQuickAnswerConversation() {
        guard !isStreaming, !isPreparingSend else { return }
        if let existing = conversations.first(where: { $0.isQuickAnswer == true }) {
            selectedConversationID = existing.id
        } else {
            let model = resolveModel()
            let conversation = Conversation(
                title: Self.quickAnswerTitle, providerID: model.provider, modelID: model.id, isQuickAnswer: true
            )
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            persist()
        }
        persistSelection()
    }

    func selectConversation(_ id: UUID) {
        guard !isStreaming, !isPreparingSend, conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
        persistSelection()
    }

    func deleteConversation(_ id: UUID) {
        guard !isStreaming, !isPreparingSend else { return }
        removeConversationFiles(conversationID: id)
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        if !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations[0].id
        }
        persist()
        persistSelection()
    }

    func clearCurrentConversation() {
        guard !isStreaming, !isPreparingSend else { return }
        removeConversationFiles(conversationID: selectedConversationID)
        updateCurrent { conversation in
            conversation.messages = []
            conversation.title = "New conversation"
        }
        persist()
    }

    /// Called at app termination: an unsent composer attachment has no owner left, so remove its
    /// session capture rather than leaking a full-screen image on disk.
    func discardUnsentSessionCaptures() {
        discardPendingAttachments()
    }

    /// Settings → Privacy entry point; identical to the chat header's Reset action.
    func clearAllHistory() {
        resetAllConversations()
    }

    /// Deletes every conversation and its conversation-owned screenshots, then starts one fresh chat.
    /// Settings, API keys and "keep a copy" screenshots are untouched.
    func resetAllConversations() {
        if isPreparingSend {
            resetAfterPreparation = true
            statusText = "Resetting conversations…"
            return
        }
        deltaFlushWork?.cancel()
        deltaFlushWork = nil
        pendingDelta = ""
        if isStreaming {
            stopRequested = true
            streamTask?.cancel()
            streamTask = nil
            streamingAssistantID = nil
            isStreaming = false
            statusText = nil
        }
        for conversation in conversations {
            removeConversationFiles(conversationID: conversation.id)
        }
        let model = resolveModel()
        let fresh = Conversation(providerID: model.provider, modelID: model.id)
        conversations = [fresh]
        selectedConversationID = fresh.id
        discardPendingAttachments()
        pendingDocuments = []
        draft = ""
        errorMessage = nil
        statusText = nil
        persist()
        persistSelection()
    }

    /// Flush current in-memory conversations to disk (app termination, reset, manual save).
    func persistNow() {
        flushPendingDelta()
        persist()
        store.flush()
        persistSelection()
    }

    // MARK: - Attachments

    func attach(_ screenshot: CapturedScreenshot) {
        let ref = ImageAttachmentRef(
            fileURL: screenshot.fileURL,
            pixelWidth: screenshot.pixelWidth,
            pixelHeight: screenshot.pixelHeight,
            createdAt: screenshot.createdAt
        )
        pendingAttachments.append(ref)
    }

    func replaceAttachment(_ id: UUID, with screenshot: CapturedScreenshot) {
        let ref = ImageAttachmentRef(
            fileURL: screenshot.fileURL,
            pixelWidth: screenshot.pixelWidth,
            pixelHeight: screenshot.pixelHeight,
            createdAt: screenshot.createdAt
        )
        if let index = pendingAttachments.firstIndex(where: { $0.id == id }) {
            let old = pendingAttachments[index]
            pendingAttachments[index] = ref
            if isSessionCapture(old.fileURL) {
                try? FileManager.default.removeItem(at: old.fileURL)
            }
        } else {
            pendingAttachments.append(ref)
        }
    }

    func removeAttachment(_ id: UUID) {
        guard let ref = pendingAttachments.first(where: { $0.id == id }) else { return }
        pendingAttachments.removeAll { $0.id == id }
        if isSessionCapture(ref.fileURL) {
            try? FileManager.default.removeItem(at: ref.fileURL)
        }
    }

    // MARK: - Documents

    /// Extracts text from the files off the main thread and queues them for the next message.
    func addDocuments(from urls: [URL]) {
        let room = DocumentTextExtractor.maxDocumentsPerMessage - pendingDocuments.count
        guard room > 0 else {
            errorMessage = "You can attach up to \(DocumentTextExtractor.maxDocumentsPerMessage) documents per message."
            return
        }
        let batch = Array(urls.prefix(room))
        let skipped = urls.count - batch.count
        Task { [weak self] in
            var added: [ChatDocument] = []
            var problems: [String] = []
            for url in batch {
                do {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try DocumentTextExtractor.extract(from: url)
                    }.value
                    added.append(document)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            guard let self else { return }
            self.pendingDocuments.append(contentsOf: added)
            if skipped > 0 { problems.append("\(skipped) file(s) skipped: the limit is \(DocumentTextExtractor.maxDocumentsPerMessage) per message.") }
            if !problems.isEmpty { self.errorMessage = problems.joined(separator: " ") }
        }
    }

    func removeDocument(_ id: UUID) {
        pendingDocuments.removeAll { $0.id == id }
    }

    // MARK: - Sending and streaming

    func sendDraft() {
        send(text: draft)
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !isPreparingSend else { return }
        guard !trimmed.isEmpty || !pendingAttachments.isEmpty || !pendingDocuments.isEmpty else { return }

        let model = resolveModel()
        if !pendingAttachments.isEmpty && !model.supportsImages {
            errorMessage = AIProviderError.unsupportedImages(modelID: model.id, provider: model.provider).errorDescription
            return
        }
        guard let apiKey = resolveAPIKey(model.provider), !apiKey.isEmpty else {
            errorMessage = AIProviderError.missingAPIKey(provider: model.provider).errorDescription
            return
        }

        // Validate only this message's attachments. A historical attachment that is no longer readable
        // must never block a new send, and a rejected attachment must keep the composer intact.
        let attachments = pendingAttachments
        let conversationID = selectedConversationID
        isPreparingSend = true
        if !attachments.isEmpty { statusText = "Preparing screenshot…" }
        Task { [weak self] in
            guard let self else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                AttachmentSanitizer.preparedPayloads(for: attachments)
            }.value
            self.finishPreparingSend(
                text: trimmed,
                attachments: attachments,
                prepared: prepared,
                model: model,
                apiKey: apiKey,
                conversationID: conversationID
            )
        }
    }

    private func finishPreparingSend(
        text: String,
        attachments: [ImageAttachmentRef],
        prepared: (payloads: [ProviderImage], dropped: Int),
        model: AIModel,
        apiKey: String,
        conversationID: UUID
    ) {
        isPreparingSend = false
        statusText = nil
        // A confirmed reset wins over the pending send, including failed attachment validation.
        if resetAfterPreparation {
            resetAfterPreparation = false
            resetAllConversations()
            return
        }
        guard prepared.dropped == 0 else {
            errorMessage = "\(prepared.dropped) attachment(s) could not be sent. Only images inside NotchAI's capture folders, under 14 MB each and 19 MB total, are accepted. Remove or replace it and try again."
            return
        }
        guard conversations.contains(where: { $0.id == conversationID }) else {
            errorMessage = "That conversation was closed before the message could be sent."
            return
        }

        let documents = pendingDocuments
        pendingAttachments = []
        pendingDocuments = []
        draft = ""
        errorMessage = nil
        selectedConversationID = conversationID
        let userMessage = ChatMessage(
            role: .user, text: text, attachments: attachments, documents: documents.isEmpty ? nil : documents
        )
        updateCurrent { conversation in
            conversation.messages.append(userMessage)
            if conversation.messages.count == 1, conversation.isQuickAnswer != true {
                conversation.title = Self.title(from: text.isEmpty ? (documents.first?.name ?? text) : text)
            }
            conversation.providerID = model.provider
            conversation.modelID = model.id
        }
        persist()
        startStreaming(
            model: model,
            apiKey: apiKey,
            // Quick answers are independent questions: send only this screenshot and prompt, not every
            // earlier capture in the shared thread.
            history: currentConversation.isQuickAnswer == true ? [userMessage] : currentConversation.messages,
            latestUserPayloads: prepared.payloads
        )
    }

    func stop() {
        flushPendingDelta()
        stopRequested = true
        streamTask?.cancel()
        streamTask = nil
    }

    func regenerate() {
        guard !isStreaming, !isPreparingSend else { return }
        guard let last = currentConversation.messages.last else { return }
        guard currentConversation.messages.contains(where: { $0.role == .user }) else { return }

        let model = resolveModel()
        guard let apiKey = resolveAPIKey(model.provider), !apiKey.isEmpty else {
            errorMessage = AIProviderError.missingAPIKey(provider: model.provider).errorDescription
            return
        }

        // A completed reply is replaced. If the last turn is a user message (for example the user
        // stopped before the first token), keep all earlier assistant answers and just answer the
        // trailing user message again.
        if last.role == .assistant {
            updateCurrent { conversation in
                if let index = conversation.messages.lastIndex(where: { $0.id == last.id }) {
                    conversation.messages.remove(at: index)
                }
            }
            persist()
        }
        startStreaming(model: model, apiKey: apiKey, history: currentConversation.messages)
    }

    private func startStreaming(
        model: AIModel,
        apiKey: String,
        history: [ChatMessage],
        latestUserPayloads: [ProviderImage]? = nil
    ) {
        let provider = providers.provider(for: model.provider)
        let assistantID = UUID()
        streamingAssistantID = assistantID
        retryContext = (model, apiKey, history)
        stopRequested = false
        receivedText = false

        updateCurrent { conversation in
            conversation.messages.append(
                ChatMessage(id: assistantID, role: .assistant, text: "", modelLabel: model.label)
            )
        }

        isStreaming = true
        statusText = "\(model.displayName) is thinking…"
        errorMessage = nil

        streamTask = Task { [weak self] in
            guard let self else { return }
            // Reading and base64-encoding screenshots can take tens of milliseconds for large
            // captures; do it off the main actor before the network request starts. Only the newest
            // user message may fail the request; historical unreadable attachments are dropped.
            let providerMessages = await Self.providerMessages(
                from: history,
                latestUserPayloads: latestUserPayloads
            )
            if Task.isCancelled {
                self.finishStreaming(assistantID: assistantID, error: nil, cancelled: true)
                return
            }
            let stream = provider.stream(
                model: model,
                messages: providerMessages,
                systemPrompt: nil,
                apiKey: apiKey
            )
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    if case let .textDelta(delta) = event {
                        self.appendDelta(delta, to: assistantID)
                    }
                }
                self.finishStreaming(assistantID: assistantID, error: nil, cancelled: self.stopRequested || Task.isCancelled)
            } catch {
                if error is CancellationError || Task.isCancelled || self.stopRequested {
                    self.finishStreaming(assistantID: assistantID, error: nil, cancelled: true)
                } else {
                    self.finishStreaming(assistantID: assistantID, error: error)
                }
            }
        }
    }

    private func appendDelta(_ delta: String, to messageID: UUID) {
        guard streamingAssistantID == messageID, !delta.isEmpty else { return }
        receivedText = true
        pendingDelta += delta
        guard deltaFlushWork == nil else { return }
        // Coalesce network bursts into one UI update per frame budget, rather than rebuilding
        // markdown and scrolling for every token. Final/stop/termination paths flush immediately.
        let work = DispatchWorkItem { [weak self] in self?.flushPendingDelta() }
        deltaFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: work)
    }

    private func flushPendingDelta() {
        deltaFlushWork?.cancel()
        deltaFlushWork = nil
        guard !pendingDelta.isEmpty else { return }
        let delta = pendingDelta
        pendingDelta = ""
        guard let messageID = streamingAssistantID,
              let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        var conversation = conversations[index]
        conversation.messages[messageIndex].text += delta
        conversation.updatedAt = Date()
        conversations[index] = conversation
        if Date().timeIntervalSince(lastStreamingPersist) > 1.5 {
            lastStreamingPersist = Date()
            persist()
        }
    }

    private func finishStreaming(assistantID: UUID, error: Error?, cancelled: Bool = false) {
        // A late callback from a stream cancelled by a full chat reset has no message to settle.
        guard streamingAssistantID == assistantID else { return }
        flushPendingDelta()
        isStreaming = false
        statusText = nil
        streamTask = nil
        streamingAssistantID = nil
        stopRequested = false

        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            errorMessage = message
            updateCurrent { conversation in
                if let index = conversation.messages.lastIndex(where: { $0.role == .assistant && $0.text.isEmpty }) {
                    conversation.messages[index].text = message
                    conversation.messages[index].isError = true
                } else {
                    conversation.messages.append(
                        ChatMessage(role: .assistant, text: message, isError: true)
                    )
                }
            }
        } else if cancelled {
            // A user stop before the first token must not fabricate a model answer. Partial answers
            // are kept; an empty placeholder is removed.
            updateCurrent { conversation in
                if let index = conversation.messages.lastIndex(where: { $0.role == .assistant }),
                   conversation.messages[index].text.isEmpty {
                    conversation.messages.remove(at: index)
                }
            }
        } else if !receivedText {
            // A successful stream that produced no text is not an answer: remove the placeholder and
            // do not announce completion (or feed a fabricated turn back to the model later).
            updateCurrent { conversation in
                if let index = conversation.messages.lastIndex(where: { $0.role == .assistant && $0.text.isEmpty }) {
                    conversation.messages.remove(at: index)
                }
            }
            errorMessage = "The model finished without returning any text."
        } else {
            completionPulse += 1
        }
        receivedText = false
        persist()
    }

    // MARK: - Helpers

    private static func title(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 52 { return trimmed.isEmpty ? "New conversation" : trimmed }
        return String(trimmed.prefix(52)) + "…"
    }

    private static func providerMessages(
        from messages: [ChatMessage],
        latestUserPayloads: [ProviderImage]?
    ) async -> [ProviderMessage] {
        await Task.detached(priority: .userInitiated) {
            var result: [ProviderMessage] = []
            result.reserveCapacity(messages.count)
            var budget = AttachmentSanitizer.AttachmentBudget()
            if let latestUserPayloads {
                budget.reserve(latestUserPayloads)
            }

            for (index, message) in messages.enumerated() {
                if message.role == .user {
                    if index == messages.count - 1, let latestUserPayloads {
                        result.append(
                            ProviderMessage(role: .user, text: message.providerText, images: latestUserPayloads)
                        )
                    } else {
                        let prepared = budget.prepare(message.attachments)
                        result.append(
                            ProviderMessage(role: .user, text: message.providerText, images: prepared.payloads)
                        )
                    }
                } else if !message.text.isEmpty, !message.isError {
                    result.append(ProviderMessage(role: .assistant, text: message.text))
                }
            }
            return result
        }.value
    }

    private func removeConversationFiles(conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        for message in conversation.messages {
            for attachment in message.attachments where isSessionCapture(attachment.fileURL) {
                try? FileManager.default.removeItem(at: attachment.fileURL)
            }
        }
    }

    /// A capture is conversation-owned only when it lives in the session-temporary directory.
    /// "Keep a copy" captures stay until the user deletes them in Privacy settings. Containment is
    /// canonical (dot segments and symlinks resolved) so a crafted conversations.json cannot delete
    /// files outside the app-owned directory.
    private func isSessionCapture(_ url: URL) -> Bool {
        AttachmentSanitizer.isStrictlyInside(AppPaths.temporaryCapturesDirectory, url)
    }

    private func discardPendingAttachments() {
        for ref in pendingAttachments where isSessionCapture(ref.fileURL) {
            try? FileManager.default.removeItem(at: ref.fileURL)
        }
        pendingAttachments = []
    }

    private func persist() {
        store.saveConversations(conversations)
    }

    private func persistSelection() {
        selectionDefaults.set(selectedConversationID.uuidString, forKey: Self.selectedConversationKey)
    }
}
