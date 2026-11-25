import AppKit

struct PickedRegion {
    let rect: CGRect          // AppKit global coordinates
    let screen: NSScreen
    let mode: AnswerMode
    let previousApp: NSRunningApplication?
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var mode: AnswerMode
    var onFinish: (CGRect?, AnswerMode) -> Void = { _, _ in }
    private var start: CGPoint?
    private var current: CGPoint?

    init(frame: NSRect, mode: AnswerMode) {
        self.mode = mode
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let rect = selection, rect.width >= 24, rect.height >= 24 {
            onFinish(rect, mode)
        } else {
            start = nil; current = nil
            needsDisplay = true
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish(nil, mode)          // Esc
        case 48: mode = mode.next; needsDisplay = true // Tab
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        if let selection {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 2
            border.stroke()
        }
        let text = "Drag to select the question area  ·  Tab: mode (\(mode.title))  ·  Esc: cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attributes)
    }
}

/// Full-screen drag-to-select overlay for choosing the region Watch Region monitors.
@MainActor
enum RegionPicker {
    private static var panel: PickerPanel?

    static func pick(mode: AnswerMode) async -> PickedRegion? {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return nil }
        let previousApp = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { continuation in
            let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size), mode: mode)
            view.onFinish = { rect, chosenMode in
                panel.orderOut(nil)
                Self.panel = nil
                // Hand focus back so the watched app is frontmost again before the first baseline.
                previousApp?.activate()
                guard let rect else { continuation.resume(returning: nil); return }
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                continuation.resume(returning: PickedRegion(rect: global, screen: screen, mode: chosenMode, previousApp: previousApp))
            }
            panel.contentView = view
            Self.panel = panel
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
    }
}
