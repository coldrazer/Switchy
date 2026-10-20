// swift-tools-version:5.9
// Switchy.app: the SwiftUI client of the agent (docs/ultimate-app-blueprint.md, Phase 4).
//   swift build -c release && ./make_app.sh        -> build/Switchy.app
// MNGCore (models + the agent socket client) is Foundation only, so `swift test` also runs on Linux.
import PackageDescription

let package = Package(
    name: "Switchy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Switchy", targets: ["Switchy"])],
    targets: [
        .target(name: "MNGCore"),
        // DefaultBackground.png: the wallpaper behind the menu until a selected game has cover art.
        .executableTarget(name: "Switchy", dependencies: ["MNGCore"],
                          resources: [.process("Resources")]),
        .testTarget(name: "MNGCoreTests", dependencies: ["MNGCore"]),
    ]
)
