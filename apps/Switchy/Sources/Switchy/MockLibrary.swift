#if canImport(SwiftUI)
import AppKit
import Foundation
import MNGCore

/// Ten fake tiles for exercising the menu carousel. They never reach the agent; the covers ship as mock-01…mock-10.
enum MockLibrary {
    static let names = ["Kart 9", "Hyrule Tales", "Pocket Pals", "Star Smash", "Bounty",
                        "Isle Life", "Ink Wars", "Kong Country", "Circuit", "Kingdom"]

    static let apps: [LibraryApp] = names.enumerated().map { index, name in
        LibraryApp(path: "mock://\(name).app", version: "v143", displayVersion: "1.4.3",
                   platform: "macos", built: 1_800_000_000 - Double(index) * 60)
    }

    private static var cache: [String: NSImage] = [:]

    static func art(for path: String) -> NSImage? {
        if let image = cache[path] { return image }
        guard let index = apps.firstIndex(where: { $0.path == path }) else { return nil }
        guard let image = Bundle.module.image(forResource: String(format: "mock-%02d", index + 1)) else { return nil }
        cache[path] = image
        return image
    }

    static func isMock(_ app: LibraryApp) -> Bool { app.path.hasPrefix("mock://") }
}
#endif
