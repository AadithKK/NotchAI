import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Conversation surface used inside the full island and the detached chat window.
struct ChatView: View {
    @ObservedObject var chat: ChatManager
    @EnvironmentObject private var settings: SettingsStore
    var onCapture: () -> Void
    var onOpenSettings: () -> Void
    var onReplaceAttachment: ((UUID) -> Void)? = nil
    @FocusState private var composerFocused: Bool
    @State private var followsReply = true
    @State private var nearBottom = true
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            messageArea
            attachmentStrip
            documentStrip
            composer
            footer
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(IslandDesign.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(IslandDesign.accent.opacity(0.08))
                    .overlay(Label("Drop documents to attach", systemImage: "doc.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9)))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    @ViewBuilder
    private var documentStrip: some View {
        if !chat.pendingDocuments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chat.pendingDocuments) { document in
                        DocumentChip(document: document) { chat.removeDocument(document.id) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func chooseDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose documents to give the AI (PDF, Word, RTF, text or code)."
        guard panel.runModal() == .OK else { return }
        chat.addDocuments(from: panel.urls)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { chat.addDocuments(from: urls) }
        }
    }

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let messages = chat.currentConversation.messages
                let lastAssistantID = messages.last(where: { $0.role == .assistant })?.id
                if messages.isEmpty {
                    EmptyChatState(onSuggestion: { chat.draft = $0 }, onOpenSettings: onOpenSettings)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { message in
                            MessageRow(
                                message: message,
                                isLastAssistant: message.role == .assistant && message.id == lastAssistantID,
                                isBusy: chat.isStreaming || chat.isPreparingSend,
                                onCopy: { copy(message.text) },
                                onRegenerate: { chat.regenerate() }
                            )
                            .equatable()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 6)
                }
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 72
            } action: { _, isNearBottom in
                nearBottom = isNearBottom
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsReply = false }
                if phase == .idle { followsReply = nearBottom }
            }
            .overlay(alignment: .bottom) {
                if !followsReply && !chat.currentConversation.messages.isEmpty {
                    Button {
                        followsReply = true
                        scroll(proxy, animated: true)
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .help("Jump to the latest reply")
                }
            }
            .onChange(of: chat.currentConversation.messages.count) { _, _ in
                if chat.currentConversation.messages.last?.role == .user { followsReply = true }
                if followsReply { scroll(proxy, animated: false) }
            }
            .onChange(of: chat.currentConversation.messages.last?.text) { _, _ in
                if chat.isStreaming && followsReply { scroll(proxy, animated: false) }
            }
            .onChange(of: chat.selectedConversationID) { _, _ in
                followsReply = true
                scroll(proxy, animated: false)
            }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !chat.pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chat.pendingAttachments) { attachment in
                        AttachmentThumbnail(attachment: attachment) {
                            chat.removeAttachment(attachment.id)
                        } onReplace: {
                            onReplaceAttachment?(attachment.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 2)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onCapture) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.66))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Capture screen (island excluded)")

                Button(action: chooseDocuments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.66))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Attach documents (PDF, Word, text) — or drop them here")

                TextField("Ask anything…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($composerFocused)
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(1...4)
                    .padding(.vertical, 5)
                    .onSubmit { chat.sendDraft() }

                if chat.isStreaming {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.primary.opacity(0.82))
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button { chat.sendDraft() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canSend ? IslandDesign.accent : Color.primary.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send · ⌘Return")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(composerFocused ? IslandDesign.accent.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: 1)
            )

            if !chat.pendingAttachments.isEmpty && !chat.canAttachImages {
                Label(
                    "\(settings.selectedModel.displayName) does not accept screenshots. Pick an image-capable model.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.95, green: 0.66, blue: 0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage = chat.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                    Text(errorMessage).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Settings") { onOpenSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(IslandDesign.accent)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.5))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let status = chat.statusText {
                Circle().fill(IslandDesign.accent).frame(width: 5, height: 5)
                Text(status).lineLimit(1)
            } else {
                Text(settings.selectedModel.provider.displayName).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("⌘Return to send")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    private var canSend: Bool {
        !chat.isPreparingSend && !chat.isStreaming
            && (!chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingAttachments.isEmpty || !chat.pendingDocuments.isEmpty)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !chat.currentConversation.messages.isEmpty else { return }
        if animated && !reduceMotion && settings.settings.animationsEnabled {
            withAnimation(IslandDesign.hover) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

private struct MessageRow: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.isLastAssistant == rhs.isLastAssistant && lhs.isBusy == rhs.isBusy
    }
    let message: ChatMessage
    let isLastAssistant: Bool
    let isBusy: Bool
    var onCopy: () -> Void
    var onRegenerate: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { attachment in
                                AttachmentImage(attachment: attachment)
                                    .frame(width: 96, height: 60)
                            }
                        }
                    }
                    if let documents = message.documents, !documents.isEmpty {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(documents) { DocumentChip(document: $0, onRemove: nil) }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.94))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(IslandDesign.accent.opacity(0.16))
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if message.isError {
                    Label {
                        Text(message.text)
                            .font(.system(size: 12))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.5))
                    .textSelection(.enabled)
                } else if message.text.isEmpty && isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    MarkdownView(text: message.text.isEmpty ? " " : message.text)
                        .equatable()
                }
                if hovering || isLastAssistant {
                    HStack(spacing: 10) {
                        if let modelLabel = message.modelLabel {
                            Text(modelLabel.components(separatedBy: " — ").first ?? modelLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button {
                            onCopy()
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .frame(width: 26, height: 26)
                        }
                        .help(copied ? "Copied" : "Copy message")
                        .accessibilityLabel(copied ? "Copied" : "Copy message")
                        .task(id: copied) {
                            guard copied else { return }
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            guard !Task.isCancelled else { return }
                            copied = false
                        }
                        if isLastAssistant && !isBusy && !message.isError && !message.text.isEmpty {
                            Button(action: onRegenerate) {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 26, height: 26)
                            }
                            .help("Regenerate")
                            .accessibilityLabel("Regenerate response")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ImageAttachmentRef
    let onRemove: () -> Void
    let onReplace: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AttachmentImage(attachment: attachment)
                .frame(width: 78, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contextMenu {
                    Button("Replace with new capture", action: onReplace)
                    Button("Remove", action: onRemove)
                }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .background(Circle().fill(.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Remove screenshot")
        }
    }
}

private struct AttachmentImage: View {
    let attachment: ImageAttachmentRef
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: attachment) {
            preview = nil
            let url = attachment.fileURL
            let thumbnail = await Task.detached(priority: .utility) {
                guard AttachmentSanitizer.isInsideAllowedDirectory(url),
                      let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      info.isRegularFile == true,
                      let size = info.fileSize, size > 0, size <= 64 * 1024 * 1024,
                      let source = CGImageSourceCreateWithURL(url as CFURL,
                          [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 384,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let thumbnail {
                preview = NSImage(cgImage: thumbnail, size: .zero)
            }
        }
    }
}

private struct EmptyChatState: View {
    var onSuggestion: (String) -> Void
    var onOpenSettings: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    private let suggestions = [
        "Explain what is on my screen",
        "Summarize the page I am reading",
        "Write a spec for my next feature",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                BrandMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("How can I help?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.94))
                    Text("Ask anything, or capture your screen to add context.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestion(suggestion)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(IslandDesign.accent.opacity(0.8))
                            Text(suggestion)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.primary.opacity(0.78))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if !hasAnyCredential {
                Button(action: onOpenSettings) {
                    Label("Add an API key in Settings", systemImage: "key")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandDesign.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasAnyCredential: Bool {
        settings.keyPresence.values.contains(true)
    }
}


/// Compact file chip for a pending or sent document.
private struct DocumentChip: View {
    let document: ChatDocument
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(IslandDesign.accent)
            Text(document.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if document.isTruncated {
                Text("truncated").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(document.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
        .accessibilityLabel("Document \(document.name)")
    }
}
