// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAI",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "NotchAI", targets: ["NotchAI"])],
    targets: [
        .executableTarget(
            name: "NotchAI",
            path: "Sources/NotchAI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NotchAITests",
            dependencies: ["NotchAI"],
            path: "Tests/NotchAITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
