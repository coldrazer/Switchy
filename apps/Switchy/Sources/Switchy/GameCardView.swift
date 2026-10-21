#if canImport(SwiftUI)
import AppKit
import MNGCore
import SwiftUI

/// Options for one game, as a dark card on white: cover with a verification ribbon, badges, real figures, Play.
struct GameCardView: View {
    var app: LibraryApp
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    private var details: AppDetails? { model.details[app.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(app.name).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            card
            HStack(spacing: 12) {
                SecondaryButton(title: "Rebuild", symbol: "arrow.clockwise") { model.rebuild(app); dismiss() }
                SecondaryButton(title: "Show in Finder", symbol: "folder") { model.showInFinder(app.path) }
                SecondaryButton(title: "Mods", symbol: "puzzlepiece.extension") { dismiss(); model.panel = .mods }
                SecondaryButton(title: "Game settings", symbol: "slider.horizontal.3") { dismiss(); model.panel = .settings }
                Spacer()
                SecondaryButton(title: "Remove from library", symbol: "trash", destructive: true) { confirmForget = true }
            }
        }
        .padding(28)
        .frame(width: 860)
        .background(Theme.panelBackground)
        .confirmationDialog("Remove \(app.name) from the library?", isPresented: $confirmForget) {
            Button("Remove", role: .destructive) { model.forget(app); dismiss() }
        } message: {
            Text("The app itself stays where it is; delete it in Finder if you want the space back.")
        }
    }

    private var card: some View {
        HStack(spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 18) {
                Text(app.name).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(2)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Pill(text: "v\(app.displayVersion)")
                        Pill(text: "Native ARM64")
                        Pill(text: "Metal 4")
                        Pill(text: modsLabel, filled: false)
                    }
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1)
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            StatTile(title: "Built", value: Date(timeIntervalSince1970: app.built)
                                .formatted(date: .abbreviated, time: .omitted), style: .plain)
                            StatTile(title: "Saves", value: details.map { "\($0.saveFiles)" } ?? "–", style: .blue)
                        }
                        HStack(spacing: 12) {
                            StatTile(title: "Startup shaders", value: details?.shadersSeeded.map { $0.formatted() } ?? "–",
                                     style: .red)
                            StatTile(title: "Shader cache", value: details.map { "\($0.shaderCacheFiles.formatted()) files" } ?? "–",
                                     style: .plain)
                        }
                    }
                }
                Spacer(minLength: 0)
                PlayButton(title: app.missing == true ? "REBUILD" : "PLAY NOW") {
                    if app.missing == true { model.rebuild(app) } else { model.play(app) }
                    dismiss()
                }
            }
            .padding(22)
        }
        .frame(height: 420)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var modsLabel: String {
        guard let d = details else { return "Mods" }
        if d.modsState == "manual" { return "Hand-made mods" }
        return d.modsEnabled == 0 ? "No mods" : "\(d.modsEnabled) mod\(d.modsEnabled == 1 ? "" : "s")"
    }

    private var cover: some View {
        VStack(spacing: 0) {
            Group {
                if let art = model.art[app.path] {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    GeneratedCover(title: app.name, subtitle: app.displayVersion)
                }
            }
            .frame(width: 250, height: 370)
            .clipped()
            HStack(spacing: 8) {
                Image(systemName: app.stale == true || app.missing == true ? "exclamationmark.triangle.fill" : "checkmark")
                Text(app.missing == true ? "App missing: rebuild" :
                        app.stale == true ? "Game files changed: rebuild" : "Built from verified game data")
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 250, height: 50)
            .background(Theme.red)
        }
    }
}

struct StatTile: View {
    enum Style { case plain, blue, red }
    var title: String
    var value: String
    var style: Style
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .frame(width: 150, height: 78)
        .background(RoundedRectangle(cornerRadius: 12).fill(style == .red ? Theme.red : style == .plain ? Theme.cardRaised : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style == .blue ? Theme.statBlue : .clear, lineWidth: 2))
    }
}

struct PlayButton: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                Image(systemName: "play.fill")
            }
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(Capsule().fill(LinearGradient(colors: [Theme.red, Theme.redDark], startPoint: .leading, endPoint: .trailing)))
            .shadow(color: Theme.red.opacity(hover ? 0.7 : 0.4), radius: hover ? 18 : 10)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut(.defaultAction)
    }
}

struct SecondaryButton: View {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(destructive ? Theme.red : Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Color(hex: 0xF1F2F4)))
        }
        .buttonStyle(.plain)
    }
}
#endif
