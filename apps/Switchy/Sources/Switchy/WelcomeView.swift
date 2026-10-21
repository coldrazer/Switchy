#if canImport(SwiftUI)
import AppKit
import SwiftUI

/// First run: what the app needs, in the order it needs it. Every row is a live check, not a static list.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    private var agentReady: Bool { model.connection == .connected }
    private var toolsReady: Bool { model.status?.toolchainReady ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Switchy").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Four checks and you are ready to build your own copy.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            step(done: model.repository != nil, title: "The Switchy source",
                 detail: model.repository?.path ?? model.sourceNote
                    ?? "Download it, or choose a checkout you already have.") {
                HStack(spacing: 8) {
                    if model.repository == nil {
                        Button(model.downloading ? "Downloading…" : "Download source") { model.downloadSource() }
                            .disabled(model.downloading)
                    }
                    Button("Choose folder…") {
                        if let url = model.chooseRepository() {
                            model.setRepository(url)
                            model.installAgent()
                        }
                    }
                }
            }
            step(done: agentReady, title: "The background agent",
                 detail: agentReady ? "Running." : "Installs at login and keeps builds going when the window closes.") {
                Button(agentReady ? "Reinstall" : "Install agent") { model.installAgent() }
                    .disabled(model.installing || model.repository == nil)
            }
            step(done: toolsReady, title: "Build tools",
                 detail: toolsReady ? "Everything is installed." :
                    "Missing: " + (model.status?.missingTools.joined(separator: ", ") ?? "checking…")) {
                Button("Check again") { Task { await model.refreshAll() } }
            }
            step(done: !model.library.isEmpty, title: "A game",
                 detail: model.library.isEmpty ? "Your own dump, its update and your keys."
                    : "\(model.library.count) game(s) in the library.") {
                Button("Add a game") {
                    model.finishWelcome()
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        model.setupFiles = []
                    }
                }
            }
            Spacer()
            HStack {
                Text("The source download is the only network call; keys and game files never leave this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { model.finishWelcome() }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 680, height: 500)
        .messageAlert()
        .task { await model.refreshAll() }
    }

    private func step<Action: View>(done: Bool, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            action()
        }
    }
}
#endif
