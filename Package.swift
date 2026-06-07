// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "bgbgone-app",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.99.0"),
        // Auto-update. Deliberate third-party exception — Apple ships no updater for
        // Developer-ID (non-App-Store) apps. See docs/superpowers/specs/2026-06-07-sparkle-auto-update-design.md
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "bgbgone-app",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "./Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BgBgOneAppTests",
            dependencies: [
                "bgbgone-app",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests",
            // Fixtures are accessed via `#filePath` (source-tree relative), not bundled.
            // Excluding stops the SwiftPM "unhandled file" warning without copying.
            exclude: ["fixtures"]
        ),
    ]
)
