#if canImport(SwiftUI)
import AppKit
import SwiftUI

@main
struct SwitchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Switchy") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add a Game…") { model.setupFiles = [] }.keyboardShortcut("n")
            }
            CommandMenu("Game") {
                Button("Builds") { model.panel = .builds }.keyboardShortcut("b")
                Button("Mods") { model.panel = .mods }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Diagnostics") { model.panel = .diagnostics }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.panel = .settings }.keyboardShortcut(",")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HomeView()
            .sheet(item: $model.panel) { section in PanelsView(section: section).environmentObject(model) }
            .sheet(isPresented: Binding(get: { model.setupFiles != nil }, set: { if !$0 { model.setupFiles = nil } })) {
                SetupAssistant(initialFiles: model.setupFiles ?? []).environmentObject(model)
            }
            .sheet(isPresented: $model.showWelcome) {
                WelcomeView().environmentObject(model)
            }
            .messageAlert()
            .onAppear { Notifier.request() }
    }
}

/// The app has one message channel; every screen that can raise one (the menu, panels, the welcome sheet) attaches this,
/// otherwise an error raised from inside a sheet would be invisible behind it.
struct MessageAlert: ViewModifier {
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Switchy", isPresented: Binding(get: { model.message != nil },
                                                       set: { if !$0 { model.message = nil } })) {
            Button("Copy details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.message ?? "", forType: .string)
                model.message = nil
            }
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

extension View {
    func messageAlert() -> some View { modifier(MessageAlert()) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app is a client: closing its window never stops a build, so quitting with the window is fine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
