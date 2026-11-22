// swift-tools-version: 5.9
import PackageDescription

// Platform-neutral on purpose (Foundation only, no UIKit/AppKit) so `swift test` runs on macOS. The one
// AVFoundation file (file transcription decoding/encoding) is guarded with `#if canImport(AVFoundation)`.
let package = Package(
    name: "ScriberCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScriberShared", targets: ["ScriberShared"]),
        .library(name: "ScriberCore", targets: ["ScriberCore"]),
    ],
    targets: [
        // Tiny, dependency-free. The keyboard extension links ONLY this.
        .target(name: "ScriberShared"),
        // Pipeline: STT, polish, zh-TW conversion, stores. Linked by the app, and by the keyboard for in-keyboard capture.
        .target(
            name: "ScriberCore",
            dependencies: ["ScriberShared"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "ScriberCoreTests", dependencies: ["ScriberCore", "ScriberShared"]),
    ]
)
