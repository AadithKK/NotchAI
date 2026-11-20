import AppKit
import SwiftUI
import XCTest
@testable import NotchAI

/// Offscreen renders of the real island views. Shell screen capture needs Screen Recording approval;
/// ImageRenderer lets us inspect the notch anchor and content panel without a permission prompt.
@MainActor
final class IslandRenderTests: XCTestCase {
    func testRenderIslandStatesOffscreen() throws {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let metrics = ScreenMetrics.metrics(for: screen)
        let pill = IslandGeometry.pillSize(for: metrics)

        let viewModel = IslandViewModel()
        viewModel.isNotchDisplay = metrics.hasNotch
        viewModel.pillWidth = pill.width
        viewModel.pillHeight = pill.height

        let suite = "NotchAI.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(keychain: FakeKeychain(), defaults: defaults)
        let chat = ChatManager(
            store: InMemoryChatStore(),
            providers: AIProviderRegistry(
                deepSeek: FakeProvider(id: .deepSeek),
                gemini: FakeProvider(id: .gemini)
            )
        )
        let browser = BrowserManager()
        let actions = IslandActions()

        let directory = URL(fileURLWithPath: "/tmp/notchai-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render<V: View>(_ view: V, size: CGSize, name: String) throws {
            let wrapped = view
                .frame(width: size.width, height: size.height)
                .background(Color(red: 0.20, green: 0.23, blue: 0.28))
            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else {
                XCTFail("ImageRenderer produced no image for \(name)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("could not encode \(name)")
                return
            }
            let url = directory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            XCTAssertGreaterThan(png.count, 1_000, "render for \(name) is unexpectedly empty")
            print("RENDER \(name): \(url.path) \(Int(size.width))x\(Int(size.height))")
        }

        let anchorFrame = IslandGeometry.anchorFrame(for: metrics)
        try render(
            IslandAnchorView(viewModel: viewModel).environmentObject(chat),
            size: anchorFrame.size,
            name: "island-anchor"
        )

        viewModel.setState(.expanded)
        viewModel.isPinned = true
        viewModel.contentRevealed = true
        if let expandedFrame = IslandGeometry.contentFrame(for: .expanded, screen: metrics) {
            try render(
                IslandContentView(viewModel: viewModel, actions: actions)
                    .environmentObject(settings)
                    .environmentObject(chat)
                    .environmentObject(browser),
                size: expandedFrame.size,
                name: "island-expanded"
            )
        }

        viewModel.setState(.full)
        viewModel.isPinned = true
        viewModel.contentRevealed = true
        if let fullFrame = IslandGeometry.contentFrame(for: .full, screen: metrics) {
            try render(
                IslandContentView(viewModel: viewModel, actions: actions)
                    .environmentObject(settings)
                    .environmentObject(chat)
                    .environmentObject(browser),
                size: fullFrame.size,
                name: "island-full"
            )
        }
    }
}
