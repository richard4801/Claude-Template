// swift-tools-version:5.9
import PackageDescription

// Pure logic for the MUSE Mac app: models, pricing, prompt engine, API client protocol,
// an in-process fake backend and the HTTP client. No SwiftUI/AppKit, so it builds and tests on Linux too.
let package = Package(
    name: "MuseCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MuseCore", targets: ["MuseCore"])],
    targets: [
        .target(name: "MuseCore"),
        .testTarget(name: "MuseCoreTests", dependencies: ["MuseCore"], resources: [.copy("Fixtures")]),
    ]
)
