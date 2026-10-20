#if canImport(SwiftUI)
import AppKit
import MNGCore
import SwiftUI

/// One tile of the game menu.
enum HomeItem: Identifiable, Equatable {
    case app(LibraryApp)
    case building(Job)
    case add

    var id: String {
        switch self {
        case .app(let a): "app:\(a.path)"
        case .building(let j): "job:\(j.id)"
        case .add: "add"
        }
    }

    var title: String {
        switch self {
        case .app(let a): a.name
        case .building(let j): "Building \((j.output.map { ($0 as NSString).lastPathComponent } ?? "your game").replacingOccurrences(of: ".app", with: ""))"
        case .add: "Add a game"
        }
    }
}

/// The game menu: a console-style home screen. The selected tile is large with a glowing border; its title and actions
/// sit beside it, the other tiles follow in a row, and the backdrop is the selected game's own art.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var controllers = ControllerInput()
    @State private var selection = 0
    @State private var detailsFor: LibraryApp?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    var items: [HomeItem] {
        let building = model.activeJobs.filter { job in !model.library.contains { $0.path == job.output } }
        return model.macApps.map(HomeItem.app) + building.map(HomeItem.building) + [.add]
    }

    var selected: HomeItem { items[min(selection, items.count - 1)] }

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Backdrop(image: selectedArt)
            VStack(alignment: .leading, spacing: 0) {
                TopBar(controllers: controllers).padding(.horizontal, 56).padding(.top, 34)
                Spacer(minLength: 24)
                if case .unavailable(let why) = model.connection {
                    AgentOffCard(reason: why).padding(.horizontal, 56)
                    Spacer(minLength: 24)
                } else {
                    shelf
                    Spacer(minLength: 24)
                }
                BottomBar(controllers: controllers, page: selection, pages: items.count) { move($0) }
                    .padding(.horizontal, 56).padding(.bottom, 30)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            if dropTargeted { DropHint() }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        }
        .frame(minWidth: 1100, minHeight: 680)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; model.start(); bindController() }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { options(); return .handled }
        .onChange(of: items.count) { _, count in selection = min(selection, max(0, count - 1)) }
        .dropDestination(for: URL.self) { urls, _ in
            model.setupFiles = urls
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $detailsFor) { app in GameCardView(app: app).environmentObject(model) }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: selection)
    }

    private var selectedArt: NSImage? {
        if case .app(let a) = selected { return model.art[a.path] ?? MockLibrary.art(for: a.path) }
        return nil
    }

    // The selected tile, its title and actions, and the row of the tiles after it.
    private var shelf: some View {
        let all = items
        let start = min(selection, all.count - 1)
        return HStack(alignment: .bottom, spacing: 22) {
            Marker(show: selection == 0 && !model.macApps.isEmpty)
            ZStack(alignment: .bottomLeading) {
                TileView(item: all[start], art: art(all[start]), large: true)   // items always holds the Add tile
                    .id(all[start].id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                    .onTapGesture(count: 2) { activate() }
                    .onTapGesture { options() }
            }
            VStack(alignment: .leading, spacing: 18) {
                TitleBlock(item: selected, details: details(selected), onPlay: activate, onOptions: options)
                    .animation(nil, value: selection)   // swap the title; the strip carries the motion
                GeometryReader { geo in
                    // One strip of every tile, shifted by one step per selection: the row glides instead of
                    // inserting and removing views. Tiles outside the visible slots are faded out, not removed.
                    let step = Theme.tile + 22
                    let slots = max(1, Int((geo.size.width + 22) / step))
                    ZStack(alignment: .bottomLeading) {
                        ForEach(Array(all.enumerated()), id: \.element.id) { index, item in
                            let slot = index - start - 1
                            TileView(item: item, art: art(item), large: false)
                                .offset(x: CGFloat(slot) * step)
                                .opacity(slot >= 0 && slot < slots ? 1 : 0)
                                .onTapGesture { selection = index }
                        }
                    }
                    .frame(width: geo.size.width, height: Theme.tile, alignment: .bottomLeading)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                 .init(color: .black, location: 0.9),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                }
                .frame(height: Theme.tile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.leading, 40)
    }

    private func art(_ item: HomeItem) -> NSImage? {
        if case .app(let a) = item { return model.art[a.path] ?? MockLibrary.art(for: a.path) }
        return nil
    }

    private func details(_ item: HomeItem) -> AppDetails? {
        if case .app(let a) = item { return model.details[a.path] }
        return nil
    }

    private func move(_ delta: Int) {
        selection = max(0, min(items.count - 1, selection + delta))
    }

    private func activate() {
        switch selected {
        case .app(let a):
            if a.missing == true { model.rebuild(a) } else { model.play(a) }
        case .building: model.panel = .builds
        case .add: model.setupFiles = []
        }
    }

    private func options() {
        switch selected {
        case .app(let a): detailsFor = a
        case .building: model.panel = .builds
        case .add: model.setupFiles = []
        }
    }

    private func bindController() {
        controllers.onMove = { move($0) }
        controllers.onPrimary = { activate() }
        controllers.onOptions = { options() }
    }
}

// MARK: - pieces

/// The selected game's art filling the window, softened, with a teal wash from the left so text stays readable.
/// With no game art to show, the bundled wallpaper sits behind the menu instead.
struct Backdrop: View {
    var image: NSImage?

    /// Shipped with the app: the collage behind the menu until a selected game has cover art.
    static let wallpaper: NSImage? = Bundle.module.image(forResource: "DefaultBackground")

    private var showsWallpaper: Bool { image == nil && Backdrop.wallpaper != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Theme.deepTeal, Theme.teal, Theme.tealLight], startPoint: .bottomLeading,
                               endPoint: .topTrailing)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width * 0.72, height: geo.size.height)
                        .clipped()
                        .blur(radius: 14)
                        .opacity(0.85)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity)
                        .id(ObjectIdentifier(image))
                } else if let wallpaper = Backdrop.wallpaper {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 2)
                        .scaleEffect(1.04)          // hide the blur's soft edge
                } else {
                    Clouds()
                }
                wash
                LinearGradient(colors: [.clear, Theme.deepTeal.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: image.map(ObjectIdentifier.init))
    }

    /// Darkens the left half so the menu stays readable: strongest over game art, lighter over the wallpaper so the
    /// collage still reads.
    private var wash: some View {
        ZStack {
            if showsWallpaper {
                Color.black.opacity(0.30)
                LinearGradient(stops: [.init(color: Theme.deepTeal.opacity(0.95), location: 0),
                                       .init(color: Theme.deepTeal.opacity(0.90), location: 0.32),
                                       .init(color: Theme.teal.opacity(0.72), location: 0.55),
                                       .init(color: Theme.teal.opacity(0.10), location: 0.86)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: Theme.deepTeal.opacity(0.75), location: 0),
                                       .init(color: Theme.deepTeal.opacity(0.20), location: 0.14),
                                       .init(color: .clear, location: 0.30)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(stops: [.init(color: Theme.deepTeal.opacity(0.96), location: 0),
                                       .init(color: Theme.teal.opacity(0.72), location: 0.38),
                                       .init(color: Theme.teal.opacity(0.08), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}

/// Soft drifting light for the backdrop when a game has no art yet.
struct Clouds: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                for i in 0..<7 {
                    let phase = Double(i) * 0.9
                    let x = size.width * (0.45 + 0.5 * (0.5 + 0.5 * sin(t / 40 + phase)))
                    let y = size.height * (0.15 + 0.1 * Double(i) + 0.03 * cos(t / 30 + phase))
                    let r = size.width * (0.12 + 0.03 * Double(i % 3))
                    g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r * 0.45, width: r * 2, height: r * 0.9)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.16), .clear]),
                                                 center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                }
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controllers: ControllerInput

    var body: some View {
        HStack(spacing: 30) {
            Avatar(count: model.activeJobs.count, profile: model.profile) { model.panel = .profile }
            Rectangle().fill(.white.opacity(0.35)).frame(width: 2, height: 48)
            BarButton(symbol: "hammer.fill", color: Theme.iconBuilds, label: "Builds", dot: !model.activeJobs.isEmpty) {
                model.panel = .builds
            }
            BarButton(symbol: "puzzlepiece.extension.fill", color: Theme.iconMods, label: "Mods") { model.panel = .mods }
            BarButton(symbol: "plus.rectangle.on.rectangle", color: Theme.iconAdd, label: "Add a game") { model.setupFiles = [] }
            BarButton(symbol: "stethoscope", color: .white, label: "Diagnostics") { model.panel = .diagnostics }
            BarButton(symbol: "gearshape.fill", color: .white, label: "Settings") { model.panel = .settings }
            BarButton(symbol: "power", color: .white, label: "Quit") { NSApp.terminate(nil) }
            AgentPill()
            Spacer()
            Clock()
            if let battery = controllers.battery {
                HStack(spacing: 6) {
                    Text("\(battery.percent)%").font(.launcher(30, .medium))
                    Image(systemName: battery.symbol).font(.system(size: 26)).symbolRenderingMode(.multicolor)
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

struct Avatar: View {
    var count: Int
    var profile: Profile
    var showsCount = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if showsCount {
                    Text(count > 0 ? "\(count)" : " ")
                        .font(.launcher(15, .bold)).foregroundStyle(Theme.success)
                }
                ZStack {
                    Circle().fill(LinearGradient(colors: [Theme.tealLight, Theme.teal], startPoint: .top, endPoint: .bottom))
                    Text(profile.initials).font(.launcher(26, .bold)).foregroundStyle(.white)
                }
                .frame(width: 78, height: 78)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "\(count) build(s) running · Profile" : "\(profile.displayName) · Profile")
        .accessibilityLabel("Profile for \(profile.displayName)")
        .accessibilityHint("Opens your profile and settings")
    }
}

struct BarButton: View {
    var symbol: String
    var color: Color
    var label: String
    var dot = false
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0)))
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(Theme.selection).frame(width: 9, height: 9).offset(x: 2, y: -2) }
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The agent's state as a pill: on (orange) when connected; tap to install it when it is not running.
struct AgentPill: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let on = model.connection == .connected
        Button { if !on { model.installAgent() } } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "bolt.horizontal.fill" : "bolt.horizontal")
                Text(model.installing ? "Starting…" : on ? "On" : "Off")
            }
            .font(.launcher(22, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(Capsule().fill(on ? Theme.statusPill : Color.gray.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(on ? "The background agent is running" : "The background agent is not running: click to install it")
    }
}

struct Clock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.launcher(32, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// The small tab beside the first tile: the most recently built game.
struct Marker: View {
    var show: Bool
    var body: some View {
        VStack {
            if show {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.selection)
                    .frame(width: 34, height: 40)
                    .overlay(Image(systemName: "chevron.down").font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.deepTeal))
                    .help("Most recently built")
            }
            Spacer()
        }
        .frame(width: 34, height: Theme.selectedTile + 16)
    }
}

struct TileView: View {
    var item: HomeItem
    var art: NSImage?
    var large: Bool
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        let size = large ? Theme.selectedTile : Theme.tile
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous))
            .overlay {
                if large {
                    RoundedRectangle(cornerRadius: Theme.tileCorner + 6, style: .continuous)
                        .strokeBorder(Theme.selection, lineWidth: 7)
                        .padding(-10)
                        .shadow(color: Theme.selection.opacity(glow ? 0.95 : 0.45), radius: glow ? 18 : 8)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .padding(large ? 10 : 0)
            .onAppear {
                guard !reduceMotion else { glow = true; return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever()) { glow = true }
            }
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .app(let app):
            ZStack(alignment: .bottomLeading) {
                if let art {
                    Image(nsImage: art).resizable().scaledToFill()
                } else {
                    GeneratedCover(title: app.name, subtitle: app.displayVersion)
                }
                if app.missing == true || app.stale == true {
                    Label(app.missing == true ? "Missing" : "Game files changed", systemImage: "exclamationmark.triangle.fill")
                        .font(.launcher(large ? 15 : 11, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.red))
                        .padding(10)
                }
            }
        case .building(let job):
            ZStack {
                LinearGradient(colors: [Theme.card, Theme.cardRaised], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 12) {
                    ProgressRing(value: job.progress ?? 0, lineWidth: large ? 12 : 8)
                        .frame(width: large ? 120 : 70, height: large ? 120 : 70)
                    Text(job.currentTitle ?? (job.status == "queued" ? "Waiting to start" : "Starting"))
                        .font(.launcher(large ? 17 : 12, .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }
            }
        case .add:
            ZStack {
                Color.white.opacity(0.08)
                RoundedRectangle(cornerRadius: Theme.tileCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(6)
                VStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: large ? 64 : 40, weight: .light))
                    Text("Add a game").font(.launcher(large ? 20 : 14, .medium))
                }
                .foregroundStyle(.white)
            }
        }
    }
}

/// Cover art drawn from the title when the game's own icon is not available.
struct GeneratedCover: View {
    var title: String
    var subtitle: String
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: 0x6FC7D6), Color(hex: 0x2A7F99), Color(hex: 0x123C4D)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            Circle().fill(.white.opacity(0.18)).frame(width: 220).offset(x: 140, y: -170)
            Circle().fill(.white.opacity(0.10)).frame(width: 160).offset(x: -40, y: -60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.launcher(26, .heavy)).foregroundStyle(.white).lineLimit(3).minimumScaleFactor(0.5)
                Text(subtitle).font(.launcher(15, .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(18)
        }
    }
}

struct TitleBlock: View {
    var item: HomeItem
    var details: AppDetails?
    var onPlay: () -> Void
    var onOptions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.title)
                .font(.launcher(54, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                // No gradient mask: on this SDK it double-draws the last glyph of the shadowed text.
                // lineLimit(1) still truncates long game titles.
            HStack(spacing: 34) {
                KeyHint(key: "return", label: primaryLabel, action: onPlay)
                KeyHint(key: "space", label: "Options", action: onOptions)
                if let details {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                        Text(details.displayVersion)
                        if let seeded = details.shadersSeeded {
                            Text("·").opacity(0.6)
                            Text("\(seeded.formatted()) shaders ready")
                        }
                    }
                    .font(.launcher(24, .medium))
                    .foregroundStyle(Theme.success)
                }
            }
        }
    }

    private var primaryLabel: String {
        switch item {
        case .app(let a): a.missing == true ? "Rebuild" : "Play"
        case .building: "Progress"
        case .add: "Start"
        }
    }
}

/// A keyboard hint: the key in a round badge, then what it does. Clicking does the same.
struct KeyHint: View {
    var key: String      // "return" or "space"
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: key == "return" ? "return" : "space")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.deepTeal)
                }
                .frame(width: 34, height: 34)
                Text(label).font(.launcher(30, .regular)).foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(key) key")
    }
}

/// A clickable step arrow for the library strip; it calls the same move() the keyboard and controller use.
struct StepButton: View {
    var symbol: String
    var enabled: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.35))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(enabled && hover ? 0.28 : 0.14)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(symbol == "chevron.left" ? "Previous game" : "Next game")
        .accessibilityLabel(symbol == "chevron.left" ? "Previous game" : "Next game")
    }
}

struct BottomBar: View {
    @ObservedObject var controllers: ControllerInput
    var page: Int
    var pages: Int
    var onStep: (Int) -> Void = { _ in }
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StepButton(symbol: "chevron.left", enabled: page > 0) { onStep(-1) }
                    HStack(spacing: 5) {
                        ForEach(0..<max(pages, 1), id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(i == page ? Theme.selection : .white.opacity(0.35))
                                .frame(width: 13, height: 13)
                        }
                    }
                    StepButton(symbol: "chevron.right", enabled: page < pages - 1) { onStep(1) }
                }
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white)
                    .help(controllers.names.isEmpty ? "No controller connected" : controllers.names.joined(separator: ", "))
            }
            Spacer()
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: controllers.names.isEmpty ? "link" : "checkmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.deepTeal)
                }
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if !controllers.names.isEmpty { Circle().fill(Theme.success).frame(width: 9, height: 9).offset(x: 3, y: -3) }
                }
                Text(controllers.names.first ?? "Connect a controller").font(.launcher(30, .regular)).foregroundStyle(.white)
            }
        }
    }
}

struct ProgressRing: View {
    var value: Double
    var lineWidth: CGFloat
    var tint: Color = Theme.selection
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: value)
            Text("\(Int((value * 100).rounded()))%").font(.launcher(lineWidth * 2, .bold)).foregroundStyle(.white)
        }
    }
}

struct AgentOffCard: View {
    @EnvironmentObject var model: AppModel
    var reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The background agent isn't running").font(.launcher(40, .bold)).foregroundStyle(.white)
            Text("It builds your game in the background and keeps going when this window closes. "
                 + "Install it once and it starts at every login.")
                .font(.launcher(20, .regular)).foregroundStyle(Theme.textSecondary).frame(maxWidth: 720, alignment: .leading)
            HStack(spacing: 16) {
                Button { model.installAgent() } label: {
                    Label(model.installing ? "Installing…" : "Install the agent", systemImage: "bolt.horizontal.fill")
                        .font(.launcher(20, .semibold)).padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Capsule().fill(Theme.statusPill)).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.installing)
                Button { Task { await model.connectOnce() } } label: {
                    Text("Try again").font(.launcher(20, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            Text(reason).font(.launcher(13)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.leading, 40)
    }
}

struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(Theme.selection, style: StrokeStyle(lineWidth: 5, dash: [16, 10]))
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.deepTeal.opacity(0.7)))
            .overlay(Text("Drop your game, update and keys").font(.launcher(40, .bold)).foregroundStyle(.white))
            .padding(40)
            .allowsHitTesting(false)
    }
}
#endif
