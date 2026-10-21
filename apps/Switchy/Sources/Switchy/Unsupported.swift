#if !canImport(SwiftUI)
// The app is macOS only; elsewhere the package still builds so MNGCore and its tests run (CI on Linux).
@main
enum Unsupported {
    static func main() {
        print("Switchy is a macOS app. On this platform only the MNGCore library and its tests build.")
    }
}
#endif
