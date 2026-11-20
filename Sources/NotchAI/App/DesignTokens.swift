import SwiftUI

/// Island visual tokens shared by every island surface. See DESIGN.md.
enum IslandDesign {
    static let accent = Color.accentColor

    static let cornerExpanded: CGFloat = 20
    static let cornerFull: CGFloat = 22
    static let cornerCard: CGFloat = 12
    static let cornerControl: CGFloat = 8

    static let expandedPadding: CGFloat = 16
    static let fullPadding: CGFloat = 16

    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// Shell growth from the notch: quick, with a hint of settle.
    static let reveal = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let hover = Animation.easeOut(duration: 0.18)
    static let contentArrival = Animation.spring(response: 0.42, dampingFraction: 0.9)

    static func panelRadius(for state: IslandState) -> CGFloat {
        switch state {
        case .collapsed: return 100
        case .expanded: return cornerExpanded
        case .full: return cornerFull
        }
    }

    /// Collapsed notch shape: straight top edge merged with the hardware housing, rounded bottom.
    static let notchBottomRadius: CGFloat = 14

    /// The physical camera housing is black; the island must read as the same material on every
    /// appearance. No lighter glass, no hue.
    static let panelBlack = Color.black

    /// Legacy surface helper kept for in-island controls (browser toolbar, cards): always black so the
    /// island never drifts lighter than the hardware notch.
    static func panelDarkBase(_ scheme: ColorScheme) -> Color {
        Color.clear
    }
}

/// Island surface outline. The collapsed notch state has a straight top edge that merges with the
/// camera housing and rounded bottom corners; every other state is a fully rounded panel.
struct IslandShape: Shape {
    var cornerRadius: CGFloat
    var squareTop: Bool = false

    func path(in rect: CGRect) -> Path {
        guard squareTop else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        }
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        // Cubic corners (control points at 55% of the radius) read as continuous curvature, matching
        // the rounded-rect panels instead of the tighter look of a quadratic curve.
        let k = radius * 0.55
        path.addCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - k),
            control2: CGPoint(x: rect.maxX - k, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control1: CGPoint(x: rect.minX + k, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - k)
        )
        path.closeSubpath()
        return path
    }
}

/// Clips the island shell to a rectangle that grows from `from` (the notch footprint) to the full
/// panel, anchored at the top center. Only the clip animates: the content keeps its final layout, so
/// opening costs no per-frame SwiftUI/WebKit relayout.
struct IslandRevealShape: Shape {
    var progress: CGFloat
    var fromWidth: CGFloat
    var fromHeight: CGFloat
    var cornerRadius: CGFloat
    var squareTop: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(progress, 0)
        let w = min(rect.width, fromWidth + (rect.width - fromWidth) * t)
        let h = min(rect.height, fromHeight + (rect.height - fromHeight) * t)
        let box = CGRect(x: rect.midX - w / 2, y: rect.minY, width: max(w, 0), height: max(h, 0))
        return IslandShape(cornerRadius: cornerRadius, squareTop: squareTop).path(in: box)
    }
}

/// The transition lives at the housing's lower corners, not in a raised neck underneath it.
/// Vertical tangents meet the housing sides; horizontal tangents meet the content's top edge.
struct NotchShoulderShape: Shape {
    var radius: CGFloat = IslandGeometry.shoulderRadius
    var overlap: CGFloat = IslandGeometry.shoulderOverlap

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height)
        let baseline = rect.maxY - min(overlap, rect.height)
        let left = rect.minX + radius
        let right = rect.maxX - radius
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: baseline),
                          control: CGPoint(x: right, y: baseline))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: baseline))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY),
                          control: CGPoint(x: left, y: baseline))
        path.closeSubpath()
        return path
    }
}

/// Island surface: true black, matching the camera housing. The collapsed state has no border or
/// shadow so it disappears into the notch; panels get only a hairline and a soft offset shadow.
struct IslandPanelBackground: View {
    var shape: IslandShape
    var attachedToNotch: Bool = false

    var body: some View {
        if attachedToNotch {
            shape.fill(IslandDesign.panelBlack)
        } else {
            shape
                .fill(IslandDesign.panelBlack)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 10)
        }
    }
}

/// Brand mark: a small authored spark in a rounded square, no emoji.
struct BrandMark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(IslandDesign.accent.opacity(0.18))
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(IslandDesign.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ShortcutHint: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}
