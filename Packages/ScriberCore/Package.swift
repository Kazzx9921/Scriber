// swift-tools-version: 5.9
import PackageDescription

// Platform-neutral on purpose (Foundation only, no AVFoundation/UIKit) so `swift test` runs on macOS.
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
