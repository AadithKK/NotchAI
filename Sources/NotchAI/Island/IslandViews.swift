import SwiftUI

/// The always-visible notch anchor: a true-black pill that is exactly the camera housing. It has no
/// overhang and no controls, so it cannot swallow clicks beside the notch.
struct IslandAnchorView: View {
    @ObservedObject var viewModel: IslandViewModel

    var body: some View {
        IslandPanelBackground(shape: anchorShape, attachedToNotch: true)
            .frame(width: viewModel.pillWidth, height: viewModel.pillHeight)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.expand() }
            .accessibilityElement(children: .contain)
    }

    private var anchorShape: IslandShape {
        IslandShape(
            cornerRadius: viewModel.isNotchDisplay ? (viewModel.state == .collapsed ? IslandDesign.notchBottomRadius : 0) : viewModel.pillHeight / 2,
            squareTop: viewModel.isNotchDisplay
        )
    }
}

/// Small click-through green check that pops out beside the notch when a reply succeeds.
struct IslandCompletionBadge: View {
    var label = "Answered"
    /// Large bold label used for a multiple-choice answer letter.
    var prominent = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: prominent ? 14 : 10, weight: prominent ? .bold : .medium, design: prominent ? .rounded : .default))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(.black))
        .accessibilityLabel(label)
    }
}

/// Expanded/full content surface. It is a separate window whose top edge starts exactly at the
/// menu-bar bottom, so it can never intercept menu-bar clicks.
struct IslandContentView: View {
    @ObservedObject var viewModel: IslandViewModel
    let actions: IslandActions
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { settings.settings.animationsEnabled && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // The shell is opaque and never fades; it grows from the notch via the clip below.
                panelShape.fill(Color.black)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(viewModel.contentRevealed ? 1 : 0)
                    .offset(y: viewModel.contentRevealed || !animates ? 0 : -3)
                    .animation(animates ? .easeOut(duration: 0.2).delay(viewModel.contentRevealed ? 0.07 : 0) : nil,
                               value: viewModel.contentRevealed)
                if let toast = viewModel.toast {
                    toastView(toast)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(
                IslandRevealShape(
                    progress: viewModel.contentRevealed || !animates ? 1 : 0,
                    fromWidth: viewModel.revealFrom.width,
                    fromHeight: viewModel.revealFrom.height,
                    cornerRadius: IslandDesign.panelRadius(for: viewModel.state),
                    squareTop: viewModel.isNotchDisplay
                )
            )
            .animation(animates ? IslandDesign.reveal : nil, value: viewModel.contentRevealed)
            .animation(animates ? .easeOut(duration: 0.16) : nil, value: viewModel.toast)
        }
        .accessibilityElement(children: .contain)
        .environment(\.colorScheme, .dark)
    }

    private var panelShape: IslandShape {
        IslandShape(cornerRadius: IslandDesign.panelRadius(for: viewModel.state),
                    squareTop: viewModel.isNotchDisplay)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .expanded:
            ExpandedIslandContent(viewModel: viewModel, actions: actions)
        case .full:
            FullIslandContent(viewModel: viewModel, actions: actions)
        case .collapsed:
            EmptyView()
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Expanded content

private struct ExpandedIslandContent: View {
    @ObservedObject var viewModel: IslandViewModel
    let actions: IslandActions
    @EnvironmentObject private var chat: ChatManager
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(spacing: 8) {
                QuickAction(title: "Chat", subtitle: "Ask anything", systemImage: "bubble.left.and.bubble.right") {
                    viewModel.openFull(section: .chat)
                }
                QuickAction(title: "Browser", subtitle: "Browse quietly", systemImage: "globe") {
                    viewModel.openFull(section: .browser)
                }
                QuickAction(title: "Capture", subtitle: "Full screen", systemImage: "camera.viewfinder", accent: true) {
                    actions.capture()
                }
            }
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("NotchAI")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.94))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            IconButton(systemName: "gearshape", help: "Settings", action: actions.openSettings)
            IconButton(systemName: "chevron.up", help: "Collapse", action: viewModel.collapse)
        }
    }

    private var subtitle: String {
        if chat.isPreparingSend { return "Preparing screenshot…" }
        if chat.isStreaming { return "Generating…" }
        if settings.keyPresence[settings.selectedModel.provider] == true {
            return settings.selectedModel.displayName
        }
        return "Add an API key in Settings"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if settings.settings.screenshot.isAnswerShortcutEnabled {
                Label("Capture & Answer", systemImage: "sparkles")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ShortcutHint(text: settings.settings.screenshot.effectiveAnswerShortcut.displayString)
            } else {
                Text(lastSnippet)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ShortcutHint(text: settings.settings.screenshot.shortcut.displayString)
            }
        }
    }

    private var lastSnippet: String {
        guard let message = chat.currentConversation.messages.last else {
            return "Capture your screen or ask anything"
        }
        let text = String(message.text.prefix(120)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Screenshot attached" : text
    }
}

private struct QuickAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var accent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accent ? IslandDesign.accent : Color.primary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent ? IslandDesign.accent.opacity(0.12) : Color.primary.opacity(hovering ? 0.09 : 0.045))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(subtitle)
        .onHover { inside in
            withAnimation(IslandDesign.hover) { hovering = inside }
        }
    }
}

// MARK: - Full content

private struct FullIslandContent: View {
    @ObservedObject var viewModel: IslandViewModel
    let actions: IslandActions
    @EnvironmentObject private var chat: ChatManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var browser: BrowserManager
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.primary.opacity(0.06))
            Group {
                switch viewModel.section {
                case .chat:
                    ChatView(
                        chat: chat,
                        onCapture: actions.capture,
                        onOpenSettings: actions.openSettings,
                        onReplaceAttachment: actions.replaceAttachment
                    )
                case .browser:
                    BrowserView(manager: browser, onDetach: actions.detachBrowser, attachedToNotch: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
        }
        .padding(.horizontal, IslandDesign.fullPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .confirmationDialog(
            "Reset all conversations?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset all chats", role: .destructive) {
                chat.resetAllConversations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every conversation and its screenshots will be deleted from this Mac. Settings, API keys and saved copies are kept.")
        }
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                SectionPicker(selection: $viewModel.section)
                Spacer(minLength: 8)
                if viewModel.section == .chat {
                    Menu {
                        ForEach(chat.conversations) { conversation in
                            Button {
                                chat.selectConversation(conversation.id)
                            } label: {
                                if conversation.id == chat.selectedConversationID {
                                    Label(conversation.title, systemImage: "checkmark")
                                } else { Text(conversation.title) }
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Conversation history")
                    .disabled(chat.isStreaming || chat.isPreparingSend)
                    IconButton(systemName: "square.and.pencil", help: "New conversation", action: chat.newConversation)
                        .disabled(chat.isStreaming || chat.isPreparingSend)
                }
                IconButton(
                    systemName: viewModel.isPinned ? "pin.fill" : "pin",
                    help: viewModel.isPinned ? "Unpin island" : "Keep island open",
                    isActive: viewModel.isPinned,
                    action: { viewModel.isPinned.toggle() }
                )
                Menu {
                    Button("Settings…", systemImage: "gearshape", action: actions.openSettings)
                    Button("Open in a window", systemImage: "macwindow",
                           action: viewModel.section == .chat ? actions.detachChat : actions.detachBrowser)
                    if viewModel.section == .chat {
                        Divider()
                        Button("Reset all conversations…", systemImage: "trash", role: .destructive) {
                            showResetConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More options")
                IconButton(systemName: "chevron.up", help: "Collapse · Escape", action: viewModel.collapse)
            }
            if viewModel.section == .chat {
                HStack(spacing: 12) {
                    Text(chat.currentConversation.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ModelMenu()
                }
            }
        }
        .padding(.bottom, 12)
    }
}

private struct SectionPicker: View {
    @Binding var selection: IslandSection

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(IslandSection.allCases, id: \.self) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 150)
    }
}

private struct ModelMenu: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Menu {
            ForEach(AIProviderID.allCases) { provider in
                Section(provider.displayName) {
                    ForEach(settings.models(for: provider)) { model in
                        Button {
                            settings.select(model: model)
                        } label: {
                            if model.id == settings.selectedModel.id && model.provider == settings.selectedModel.provider {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(settings.selectedModel.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 190)
        .help("Choose model · \(settings.selectedModel.label)")
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var isActive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? IslandDesign.accent : Color.primary.opacity(hovering ? 1 : 0.65))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? IslandDesign.accent.opacity(0.15) : Color.primary.opacity(hovering ? 0.09 : 0.035))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { inside in
            withAnimation(IslandDesign.hover) { hovering = inside }
        }
    }
}
