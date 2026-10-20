#if canImport(SwiftUI)
import AppKit
import MNGCore
import SwiftUI
import UniformTypeIdentifiers

/// The management window: a red sidebar with the sections, white content.
struct PanelsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var section: AppModel.Panel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section.title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
                Group {
                    switch section {
                    case .library: LibrarySection()
                    case .builds: BuildsSection()
                    case .mods: ModsSection()
                    case .profile: ProfileSection()
                    case .settings: SettingsSection()
                    case .diagnostics: DiagnosticsSection()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.panelBackground)
        }
        .frame(width: 1020, height: 680)
        .environment(\.colorScheme, .light)
        .messageAlert()
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            ForEach(AppModel.Panel.allCases) { item in
                Button { section = item } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.system(size: 26, weight: .semibold))
                        Text(item.title).font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(section == item ? Theme.red : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 86)
                    .background(RoundedRectangle(cornerRadius: 14).fill(section == item ? Color.white : .clear))
                    .shadow(color: .black.opacity(section == item ? 0.15 : 0), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(model.connection == .connected ? "Agent — ACTIVE" : "Agent — OFF")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        }
        .padding(14)
        .frame(width: 190)
        .background(Theme.red)
    }
}

// MARK: - Library

struct LibrarySection: View {
    @EnvironmentObject var model: AppModel
    @State private var details: LibraryApp?
    @State private var search = ""

    private var apps: [LibraryApp] {
        guard !search.isEmpty else { return model.library }
        return model.library.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.displayVersion.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("Search games", text: $search)
                        .textFieldStyle(.plain).foregroundStyle(.white)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                if apps.isEmpty {
                    EmptyState(symbol: "square.grid.2x2", text: model.library.isEmpty
                        ? "No games yet. Add one from the game menu."
                        : "No game matches “\(search)”.")
                }
                ForEach(apps) { app in
                    HStack(spacing: 16) {
                        Group {
                            if let art = model.art[app.path] { Image(nsImage: art).resizable().scaledToFill() }
                            else { GeneratedCover(title: app.name, subtitle: app.displayVersion) }
                        }
                        .frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.name).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            HStack { Pill(text: "v\(app.displayVersion)"); Pill(text: app.platform == "ios" ? "iPhone / iPad" : "Mac") }
                            Text(app.path).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if app.platform == "macos" {
                            Button { details = app } label: { Text("Options").foregroundStyle(.white) }.buttonStyle(.bordered)
                            Button { model.play(app) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).tint(Theme.red)
                        } else {
                            Button { model.showInFinder(app.path) } label: { Text("Show IPA") }.buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .sheet(item: $details) { GameCardView(app: $0).environmentObject(model) }
    }
}

// MARK: - Builds

struct BuildsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            List(model.jobs, selection: $selected) { job in
                HStack(spacing: 10) {
                    StatusDot(status: job.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((job.output.map { ($0 as NSString).lastPathComponent }) ?? job.id)
                            .font(.system(size: 13, weight: .semibold))
                        Text(job.isActive ? (job.currentTitle ?? job.status.capitalized) : job.status.capitalized)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .tag(job.id)
            }
            .frame(width: 260)
            Divider()
            if let job = model.jobs.first(where: { $0.id == selected }) ?? model.jobs.first {
                JobDetail(job: job).id(job.id)
            } else {
                EmptyState(symbol: "hammer", text: "No builds yet.")
            }
        }
    }
}

struct StatusDot: View {
    var status: String
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
    private var color: Color {
        switch status {
        case "succeeded": Color.green
        case "failed": Theme.red
        case "running": Theme.statBlue
        case "queued": Color.orange
        default: Color.gray
        }
    }
}

struct JobDetail: View {
    var job: Job
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.output ?? job.id).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if job.isActive {
                    Button(role: .destructive) { model.cancel(job) } label: { Label("Cancel", systemImage: "stop.fill") }
                }
            }
            if let progress = job.progress {
                ProgressView(value: progress).tint(Theme.red)
            }
            if let error = job.error, job.status == "failed" {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.red)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(job.steps) { step in
                    HStack(spacing: 8) {
                        stepIcon(step.status).frame(width: 18)
                        Text(step.title).foregroundStyle(step.status == "skipped" ? .secondary : .primary)
                        Spacer()
                        if let s = step.started, let f = step.finished { Text(Format.duration(f - s)).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13))
                }
            }
            Text("Log").font(.system(size: 13, weight: .semibold))
            ScrollViewReader { proxy in
                ScrollView {
                    Text((model.logs[job.id] ?? []).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF4F5F7)))
                .onChange(of: model.logs[job.id]?.count ?? 0) { _, _ in proxy.scrollTo("end") }
            }
        }
        .padding(20)
        .onAppear { if model.logs[job.id] == nil { model.loadLog(job) } }
    }

    private var subtitle: String {
        let started = job.started.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "not started"
        let took = job.started.flatMap { s in job.finished.map { Format.duration($0 - s) } }
        return "\(job.status.capitalized) · started \(started)" + (took.map { " · took \($0)" } ?? "")
            + ((job.attempt ?? 1) > 1 ? " · attempt \(job.attempt!)" : "")
    }

    @ViewBuilder private func stepIcon(_ status: String) -> some View {
        switch status {
        case "done", "resumed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "running": ProgressView().controlSize(.small)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
        case "skipped": Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case "interrupted": Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        default: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mods

struct ModsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var version = "v143"
    static let versions = ["v0", "v112", "v121", "v143"]
    static let labels = ["v0": "1.0.0", "v112": "1.1.2", "v121": "1.2.1", "v143": "1.4.3"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Game version", selection: $version) {
                    ForEach(Self.versions, id: \.self) { Text(Self.labels[$0] ?? $0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                Button { addMod() } label: { Label("Add a mod folder…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
            }
            if model.mods?.folders[version]?.state == "manual" {
                HStack {
                    Label("A hand-made mods folder is in use for this version. Import it so mods can be managed here.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Import") { model.importMods(version) }
                }
                .font(.system(size: 13))
            }
            let mods = (model.mods?.mods ?? []).filter { $0.version == version }
            if mods.isEmpty {
                EmptyState(symbol: "puzzlepiece.extension",
                           text: "No mods for this version. A mod is a folder of files under their game paths; "
                               + "each one is checked against your game data before it is used.")
            } else {
                List(mods) { mod in
                    HStack {
                        Toggle("", isOn: Binding(get: { mod.enabled }, set: { model.enableMod(mod, $0) }))
                            .toggleStyle(.switch).labelsHidden().tint(Theme.red)
                        VStack(alignment: .leading) {
                            Text(mod.name).font(.system(size: 14, weight: .semibold))
                            Text("\(mod.files ?? 0) files · added \(Date(timeIntervalSince1970: mod.added).formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.removeMod(mod) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first else { return false }
            model.addMod(folder: folder, version: version)
            return true
        }
    }

    private func addMod() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a mod folder (files under their game paths, for example Sound/Resource/…)"
        if panel.runModal() == .OK, let url = panel.url { model.addMod(folder: url, version: version) }
    }
}

// MARK: - Profile

struct ProfileSection: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var saved = false

    private var draft: Profile { Profile(name: name, handle: handle, about: about) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    Avatar(count: 0, profile: draft, showsCount: false) {}
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.displayName)
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Text(handle.isEmpty ? "Local profile" : "@\(handle)")
                            .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Name") {
                        TextField("Your name", text: $name).frame(width: 320)
                    }
                    LabeledContent("Handle") {
                        TextField("optional", text: $handle).frame(width: 320)
                    }
                    LabeledContent("About") {
                        TextField("A line about you", text: $about, axis: .vertical)
                            .lineLimit(2...4)
                            .frame(width: 320)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Save changes") {
                        model.profile = draft
                        saved = true
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                    .disabled(draft == model.profile)
                    Button("Reset") {
                        name = ""; handle = ""; about = ""
                        model.profile = Profile()
                        saved = true
                    }
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.system(size: 12, weight: .semibold))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Label("This profile stays on this Mac", systemImage: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("It fills the menu avatar and the name shown in the app. It is not sent to the agent, to GitHub or anywhere else.")
                        .font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(28)
        }
        .onAppear { load() }
        .onChange(of: model.profile) { _, value in
            name = value.name; handle = value.handle; about = value.about
        }
        .onChange(of: name) { _, value in if value.count > 40 { name = String(value.prefix(40)) } }
        .onChange(of: handle) { _, value in if value.count > 24 { handle = String(value.prefix(24)) } }
        .onChange(of: about) { _, value in if value.count > 120 { about = String(value.prefix(120)) } }
    }

    private func load() {
        name = model.profile.name
        handle = model.profile.handle
        about = model.profile.about
    }
}

// MARK: - Settings

struct SettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Build") {
                PathRow(title: "Keys file", key: "keys", directory: false)
                PathRow(title: "Output folder", key: "output_dir", directory: true)
                PathRow(title: "Work folder", key: "work_dir", directory: true)
                PathRow(title: "Shared fonts (NSP only)", key: "shared_fonts", directory: true)
                PathRow(title: "Switchy folder", key: "repo", directory: true)
            }
            Section("Background") {
                FlagRow(title: "Resume a build after a restart", key: "resume_interrupted")
                FlagRow(title: "Notice when the game files change", key: "watch_inputs")
                FlagRow(title: "Rebuild automatically when they do", key: "auto_rebuild")
            }
            Section("Game") {
                ForEach(gameKeys, id: \.self) { name in GameSettingRow(name: name) }
            }
            Section("Agent") {
                LabeledContent("Status") {
                    if model.connection == .connected, let hello = model.hello {
                        Text("\(hello.agent) \(hello.version) · pid \(hello.pid)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("Off").foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 10) {
                    Button("Reveal log") { model.revealAgentLog() }
                    Button(model.installing ? "Working…" : "Reinstall") { model.installAgent() }
                        .disabled(model.installing)
                    Button("Restart") { model.restartAgent() }
                    Spacer()
                    Button("Remove agent", role: .destructive) { confirmRemove = true }
                        .disabled(model.connection != .connected)
                }
                Text("The agent is a per-user LaunchAgent. Removing it stops builds until it is installed again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version") { Text(model.appVersion).foregroundStyle(.secondary) }
                LabeledContent("Updates") {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let update = model.update {
                            HStack(spacing: 8) {
                                Text(update.isNewer ? "\(update.latest) is available" : "Up to date (\(update.latest))")
                                    .foregroundStyle(update.isNewer ? Theme.red : .secondary)
                                if update.isNewer { Button("Open release") { model.openUpdate() } }
                            }
                        } else {
                            Button("Check now") { Task { await model.checkForUpdates() } }
                        }
                        if let note = model.updateNote {
                            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 340, alignment: .trailing)
                        }
                    }
                }
                LabeledContent("Disk") {
                    if let disk = model.disk {
                        Text("\(Int(disk.freeGB)) GB free on \(disk.volume)").foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button("Reset all settings") { model.resetAllSettings() }
                    Button("Export settings…") { exportSettings() }
                    Button("Import settings…") { importSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .task { model.measureDisk() }
        .confirmationDialog("Remove the Switchy agent?", isPresented: $confirmRemove) {
            Button("Remove agent", role: .destructive) { model.uninstallAgent() }
        } message: {
            Text("Running builds stop and the app disconnects until the agent is installed again.")
        }
    }

    private var gameKeys: [String] { (model.settings?.game.keys).map { Array($0).sorted() } ?? [] }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Switchy-settings.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.exportSettings(to: url) }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.importSettings(from: url) }
    }
}

struct PathRow: View {
    var title: String
    var key: String
    var directory: Bool
    @EnvironmentObject var model: AppModel

    private var value: String? { model.settings?.settings[key]?.string }

    /// nil when the agent uses its own default, true when the path is there and is the right kind, false otherwise.
    private var valid: Bool? {
        guard let value else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue == directory
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let value {
                if valid == false {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(directory ? "That folder is not there" : "That file is not there")
                }
                Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 280, alignment: .trailing)
                Button("Show") { model.showInFinder(value) }
                Button("Reset") { model.setSettings([key: .null]) }
            } else {
                Text("Automatic").foregroundStyle(.secondary)
            }
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.message = directory ? "Choose the \(title.lowercased()) folder" : "Choose your \(title.lowercased())"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if key == "repo" { model.setRepository(url) } else { model.setSettings([key: .string(url.path)]) }
    }
}

struct FlagRow: View {
    var title: String
    var key: String
    @EnvironmentObject var model: AppModel
    var body: some View {
        Toggle(title, isOn: Binding(get: { model.settings?.settings[key]?.bool ?? false },
                                    set: { model.setSettings([key: .bool($0)]) }))
            .tint(Theme.red)
    }
}

struct GameSettingRow: View {
    var name: String
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    private var info: GameSettingInfo? { model.settings?.game[name] }
    private var current: String? { model.settings?.settings["game"]?[name]?.string }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name.replacingOccurrences(of: "_", with: " ").capitalized)
                Text(info?.description ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let values = info?.values {
                Picker("", selection: Binding(get: { current ?? "" },
                                              set: { model.setSettings(["game": [name: $0.isEmpty ? .null : .string($0)]]) })) {
                    Text("Default").tag("")
                    ForEach(values, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 160)
            } else {
                HStack(spacing: 8) {
                    TextField("Default", text: $text)
                        .frame(width: 150)
                        .onSubmit { commit() }
                    Button("Set") { commit() }
                        .disabled(text == (current ?? ""))
                }
            }
        }
        .onAppear { text = current ?? "" }
        .onChange(of: current) { _, value in text = value ?? "" }
    }

    private func commit() {
        model.setSettings(["game": [name: text.isEmpty ? .null : .string(text)]])
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var report: JSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.status {
                HStack(spacing: 12) {
                    Image(systemName: status.toolchainReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.toolchainReady ? .green : .orange).font(.system(size: 22))
                    Text(status.toolchainReady ? "This Mac has everything a build needs."
                         : "Missing for a build: " + status.missingTools.joined(separator: ", "))
                }
            }
            HStack {
                Button { Task { report = await model.diagnosticsReport() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Switchy-diagnostics.zip"
                    if panel.runModal() == .OK, let url = panel.url { model.exportDiagnostics(to: url) }
                } label: { Label("Export for a bug report…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).tint(Theme.red)
                Text("The archive has logs and this report — never your keys, saves or game data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(pretty(report))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF4F5F7)))
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
        .task { report = await model.diagnosticsReport() }
    }

    private func pretty(_ value: JSONValue?) -> String {
        guard let value else { return "Loading…" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct EmptyState: View {
    var symbol: String
    var text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Theme.red.opacity(0.8))
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
#endif
