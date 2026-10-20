#if canImport(SwiftUI)
import AppKit
import Foundation
import MNGCore

/// Ten fake tiles for exercising the menu carousel. They never reach the agent; the covers ship as mock-01…mock-10.
enum MockLibrary {
    static let names = ["Animal Crossing: New Horizons", "Donkey Kong Country: Tropical Freeze",
                        "Kirby and the Forgotten Land", "Mario Kart 8", "Metroid Dread",
                        "Pokémon Scarlet", "Splatoon 3", "Super Mario Odyssey",
                        "Super Smash Bros. Ultimate", "The Legend of Zelda: Tears of the Kingdom"]

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
