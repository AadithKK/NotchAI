import Foundation
import SwiftUI

enum IslandSection: String, CaseIterable, Sendable {
    case chat
    case browser

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .browser: return "Browser"
        }
    }
}

/// Owns island presentation state, transient messages and the completion badge pulse.
@MainActor
final class IslandViewModel: ObservableObject {
    @Published private(set) var state: IslandState = .collapsed
    @Published var section: IslandSection = .chat
    @Published var isPinned = false
    @Published var toast: String?
    /// Set by the window controller from the current screen.
    @Published var isNotchDisplay = true
    @Published var pillWidth: CGFloat = IslandGeometry.collapsedPillSize.width
    @Published var pillHeight: CGFloat = IslandGeometry.collapsedPillSize.height
    /// False for the first frame after a show, then true; drives the interior-only reveal.
    @Published var contentRevealed = false
    /// Footprint the shell grows from when it reveals: the notch on first open, the previous panel
    /// size when switching between expanded and full.
    @Published var revealFrom = CGSize(width: 200, height: 4)

    var onLayoutChange: ((IslandState) -> Void)?
    var onActivationChange: ((Bool) -> Void)?

    private var toastWork: DispatchWorkItem?

    func setState(_ next: IslandState) {
        guard state != next else { return }
        state = next
        onLayoutChange?(next)
        onActivationChange?(next == .full)
    }

    func collapse() {
        isPinned = false
        setState(.collapsed)
    }

    func expand() {
        guard state == .collapsed else { return }
        setState(.expanded)
    }

    func openFull(section: IslandSection? = nil) {
        if let section {
            self.section = section
        }
        setState(.full)
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}
