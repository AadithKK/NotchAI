import AppKit
import SwiftUI
import XCTest
@testable import NotchAI

/// Offscreen composite of the notch join: wallpaper, menu bar, hardware notch, shoulders and the
/// content shell at their real relative geometry. Writes PNGs for visual review; no permissions needed.
@MainActor
final class NotchJoinCompositeRenderTests: XCTestCase {
    func testRenderJoinComposites() throws {
        let notchW: CGFloat = 179, notchH: CGFloat = 32
        let shell = IslandGeometry.expandedSize
        let canvas = CGSize(width: 440, height: 190)

        func composite(squareTop: Bool, radius: CGFloat) -> some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.80), Color(red: 0.85, green: 0.70, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(Color.white.opacity(0.18)).frame(height: notchH).frame(maxHeight: .infinity, alignment: .top)
                // Content shell below the menu bar.
                IslandShape(cornerRadius: radius, squareTop: squareTop)
                    .fill(Color.black)
                    .frame(width: shell.width, height: shell.height)
                    .padding(.top, notchH)
                    .frame(maxHeight: .infinity, alignment: .top)
                // Hardware notch (square top, filled lower corners while open).
                Rectangle().fill(Color.black).frame(width: notchW, height: notchH)
                    .frame(maxHeight: .infinity, alignment: .top)
                // Shoulders around the housing's lower corners.
                NotchShoulderShape()
                    .fill(Color.black)
                    .frame(width: notchW + 2 * IslandGeometry.shoulderRadius,
                           height: IslandGeometry.shoulderRadius + IslandGeometry.shoulderOverlap)
                    .padding(.top, notchH - IslandGeometry.shoulderOverlap)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: canvas.width, height: canvas.height)
        }

        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCHAI_RENDER_DIR"] ?? "/tmp/notchai-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, square, radius) in [("join-A-rounded-top", false, CGFloat(20)), ("join-B-flat-top", true, CGFloat(20))] {
            let renderer = ImageRenderer(content: composite(squareTop: square, radius: radius))
            renderer.scale = 3
            let cg = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
