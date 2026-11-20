import AppKit
import SwiftUI
import XCTest
@testable import NotchAI

@MainActor
final class NotchJoinTests: XCTestCase {
    private func model(state: IslandState) -> IslandViewModel {
        let model = IslandViewModel()
        model.pillWidth = 179
        model.pillHeight = 32
        model.isNotchDisplay = true
        model.setState(state)
        model.contentRevealed = true
        return model
    }

    private func anchorBitmap(state: IslandState) throws -> NSBitmapImageRep {
        let view = IslandAnchorView(viewModel: model(state: state))
            .frame(width: 179, height: 32)
            .background(Color(red: 0.46, green: 0.50, blue: 0.58))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    func testOpenAnchorFillsRoundedCornerWedges() throws {
        for state in [IslandState.expanded, .full] {
            let bitmap = try anchorBitmap(state: state)
            for x in [1, bitmap.pixelsWide - 2] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB))
                XCTAssertLessThan(color.redComponent, 0.01, "Open anchor must fill the bottom corner at x=\(x)")
                XCTAssertLessThan(color.greenComponent, 0.01)
                XCTAssertLessThan(color.blueComponent, 0.01)
            }
        }
    }

    func testCollapsedAnchorKeepsRoundedCorners() throws {
        let bitmap = try anchorBitmap(state: .collapsed)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.redComponent, 0.2)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.01)
    }

    func testRenderCompleteJoin() throws {
        let model = model(state: .expanded)
        let suite = "NotchAI.join.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(keychain: FakeKeychain(), defaults: defaults)
        let chat = ChatManager(store: InMemoryChatStore(), providers: AIProviderRegistry(
            deepSeek: FakeProvider(id: .deepSeek), gemini: FakeProvider(id: .gemini)), selectionDefaults: defaults)
        let browser = BrowserManager()
        let view = VStack(spacing: 0) {
            IslandAnchorView(viewModel: model)
                .frame(width: 179, height: 32)
                .frame(width: 360)
            IslandContentView(viewModel: model, actions: IslandActions())
                .environmentObject(settings).environmentObject(chat).environmentObject(browser)
                .frame(width: 360, height: IslandGeometry.expandedSize.height)
        }
        .overlay(alignment: .top) {
            NotchShoulderShape().fill(.black)
                .frame(width: 179 + 2 * IslandGeometry.shoulderRadius,
                       height: IslandGeometry.shoulderRadius + IslandGeometry.shoulderOverlap)
                .offset(y: 32 - IslandGeometry.shoulderRadius)
        }
        .background(Color(red: 0.46, green: 0.50, blue: 0.58))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/notchai-complete-join.png"))
        // The old screenshot had desktop-colored wedges within the housing's bottom corners.
        // Sample both sides and both rows around the anchor/content seam, now all opaque black.
        for x in [183, 190, 530, 536] {
            for y in [60, 63, 64, 66] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertLessThan(color.redComponent, 0.01, "Visible seam at (\(x), \(y))")
                XCTAssertLessThan(color.greenComponent, 0.01)
                XCTAssertLessThan(color.blueComponent, 0.01)
            }
        }
    }
}
