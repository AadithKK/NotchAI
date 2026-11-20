import AppKit
import SwiftUI
import WebKit

/// The mini browser: tab strip, address row, history popover and the live `WKWebView`.
///
/// It fills the island's full panel (560 × 540) or a detached window. Chrome follows the island's
/// solid-black island surface, native type, accent-colored focus and shared control tokens.
@MainActor
struct BrowserView: View {
    @ObservedObject var manager: BrowserManager
    /// Provided by the app when this view can be detached into its own window.
    var onDetach: (() -> Void)? = nil
    var attachedToNotch = false

    var body: some View {
        Group {
            if let tab = manager.selectedTab {
                BrowserSessionView(manager: manager, tab: tab, onDetach: onDetach, attachedToNotch: attachedToNotch)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            manager.ensureSelectedTab()
        }
    }
}

// MARK: - Session

private struct BrowserSessionView: View {
    @ObservedObject var manager: BrowserManager
    @ObservedObject var tab: BrowserTab
    let onDetach: (() -> Void)?
    let attachedToNotch: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var isShowingHistory = false
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            // Keep a stable slot so loading doesn't shift the page's viewport.
            ZStack {
                Color.clear
                if tab.isLoading { BrowserLoadingBar() }
            }
            .frame(height: 1.5)
            if let message = manager.lastError {
                errorBar(message)
                    .transition(.opacity)
            }
            content
        }
        .background(IslandDesign.panelDarkBase(colorScheme))
        .controlSize(.small)
        .tint(IslandDesign.accent)
        .animation(reduceMotion ? nil : IslandDesign.hover, value: tab.isLoading)
        .animation(reduceMotion ? nil : IslandDesign.hover, value: manager.lastError)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            tabStrip
            addressRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(BrowserChromeSurface())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.tabs) { item in
                        BrowserTabChip(
                            tab: item,
                            isSelected: item.id == manager.selectedTabID,
                            onSelect: { manager.selectTab(item.id) },
                            onClose: { manager.closeTab(item.id) }
                        )
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 26)
            .animation(reduceMotion ? nil : IslandDesign.hover, value: manager.selectedTabID)

            BrowserToolbarButton(systemName: "plus", help: "New tab") {
                manager.newTab()
            }

            if let onDetach {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1, height: 14)
                BrowserToolbarButton(systemName: "macwindow", help: "Open in a separate window", action: onDetach)
            }
        }
    }

    private var addressRow: some View {
        HStack(spacing: 3) {
            BrowserToolbarButton(systemName: "chevron.left", help: "Back", isEnabled: tab.canGoBack) {
                manager.goBack()
            }
            BrowserToolbarButton(systemName: "chevron.right", help: "Forward", isEnabled: tab.canGoForward) {
                manager.goForward()
            }
            BrowserToolbarButton(
                systemName: tab.isLoading ? "xmark" : "arrow.clockwise",
                help: tab.isLoading ? "Stop loading" : "Reload"
            ) {
                if tab.isLoading {
                    manager.stopLoading()
                } else {
                    manager.reload()
                }
            }

            addressField
                .padding(.leading, 3)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 3)

            BrowserToolbarButton(
                systemName: "clock.arrow.circlepath",
                help: "History",
                isActive: isShowingHistory
            ) {
                manager.refreshHistory()
                isShowingHistory.toggle()
            }
            .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                historyPopover
            }

            BrowserToolbarButton(systemName: "safari", help: "Open in the default browser") {
                manager.openInDefaultBrowser()
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: addressSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.38))
                .frame(width: 11)

            ZStack(alignment: .leading) {
                if manager.addressText.isEmpty {
                    Text("Search or enter a website")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.primary.opacity(0.3))
                        .allowsHitTesting(false)
                }
                TextField("", text: $manager.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .focused($isAddressFocused)
                    .onSubmit { manager.navigate(addressText: manager.addressText) }
                    .accessibilityLabel("Address and search")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: IslandDesign.cornerControl, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: IslandDesign.cornerControl, style: .continuous)
                .strokeBorder(
                    isAddressFocused ? IslandDesign.accent.opacity(0.5) : Color.primary.opacity(0.09),
                    lineWidth: isAddressFocused ? 2 : 1
                )
        )
    }

    private var addressSymbol: String {
        switch tab.url?.scheme?.lowercased() {
        case "https": return "lock.fill"
        case "http": return "lock.open"
        case "file": return "folder"
        case .some: return "globe"
        case nil: return "magnifyingglass"
        }
    }

    // MARK: Error + loading

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.5))

            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Button("Retry") { retry() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(IslandDesign.accent)
                .help("Try loading the page again")

            Button {
                manager.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    private func retry() {
        if tab.url != nil {
            manager.reload()
        } else {
            manager.navigate(addressText: manager.addressText)
        }
    }

    // MARK: Content

    private var content: some View {
        ZStack {
            BrowserWebViewContainer(webView: tab.webView)
            if showsStartPage {
                startPage
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IslandDesign.panelDarkBase(colorScheme))
    }

    private var showsStartPage: Bool {
        tab.url == nil && !tab.isLoading
    }

    private var startPage: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    BrandMark(size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready when you are")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.94))
                        Text("Search the web or open a page from the address bar.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    manager.loadHomepage()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "house")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IslandDesign.accent.opacity(0.85))
                        Text(homepageLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.primary.opacity(0.78))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: IslandDesign.cornerControl, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .help("Open the homepage from Settings")
            }
            .frame(maxWidth: 380, alignment: .leading)
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(attachedToNotch ? Color.black : Color(nsColor: .windowBackgroundColor))
    }

    private var homepageLabel: String {
        guard let host = BrowserURLResolver.resolve(manager.homepage, searchEngine: manager.searchEngine)?.host,
              !host.isEmpty else {
            return "Open homepage"
        }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "Open \(trimmed)"
    }

    // MARK: History popover

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if !manager.history.isEmpty {
                    Button("Clear") { manager.clearHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Clear browsing history")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            if manager.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No history yet")
                        .font(.system(size: 12, weight: .medium))
                    Text("Pages you visit will show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(manager.history) { entry in
                            BrowserHistoryRow(entry: entry) {
                                isShowingHistory = false
                                manager.navigate(addressText: entry.url)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .frame(height: min(CGFloat(manager.history.count) * 42 + 12, 300))
            }
        }
        .frame(width: 300)
    }
}

// MARK: - Chrome pieces

/// Chrome background: system material under a graphite tint, so the toolbar reads as the same
/// hardware as the island panel in both appearances and inside a detached window.
private struct BrowserChromeSurface: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.025))
    }
}

private struct BrowserToolbarButton: View {
    let systemName: String
    let help: String
    var isEnabled = true
    var isActive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { inside in
            withAnimation(IslandDesign.hover) { hovering = inside }
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        if !isEnabled { return Color.primary.opacity(0.22) }
        if isActive { return Color.primary.opacity(0.92) }
        return Color.primary.opacity(hovering ? 0.9 : 0.5)
    }

    private var fillOpacity: Double {
        if !isEnabled { return 0.02 }
        if isActive { return 0.10 }
        return hovering ? 0.09 : 0.04
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var showsClose: Bool { isSelected || hovering }

    var body: some View {
        Button(action: onSelect) {
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color.primary.opacity(isSelected ? 0.92 : 0.52))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 9)
                .padding(.trailing, 22)
                .padding(.vertical, 5)
                .frame(maxWidth: 150, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if showsClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("Close tab")
            }
        }
        .frame(height: 24)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : (hovering ? 0.06 : 0.0)))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected ? 0.08 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0), radius: 2, x: 0, y: 1)
        .onHover { inside in
            withAnimation(IslandDesign.hover) { hovering = inside }
        }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Indeterminate 1.5pt loading bar, drawn once and removed when the load finishes. No timer: the
/// animation is a single repeating SwiftUI animation, and Reduce Motion shows a static bar.
private struct BrowserLoadingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width * 0.26, 36)
            Capsule(style: .continuous)
                .fill(IslandDesign.accent.opacity(0.85))
                .frame(width: width, height: 1.5)
                .offset(
                    x: reduceMotion
                        ? (proxy.size.width - width) / 2
                        : phase * (proxy.size.width + width) - width
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .frame(height: 1.5)
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct BrowserHistoryRow: View {
    let entry: BrowserHistoryEntry
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(IslandDesign.hover) { hovering = inside }
        }
    }
}

// MARK: - Web view host

/// Hosts a tab's `WKWebView` inside SwiftUI without ever recreating it. Switching tabs re-parents
/// the existing web view into this container, so page state, scroll position and media survive.
private struct BrowserWebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        for subview in container.subviews where subview !== webView {
            subview.removeFromSuperview()
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        } else if webView.frame != container.bounds {
            webView.frame = container.bounds
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Void) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
