#if canImport(SwiftUI)
import AppKit
import MNGCore
import SwiftUI

/// The app's view of the agent: it connects, subscribes to events and keeps the library, jobs, mods and settings
/// current. The agent owns the state; nothing here is persisted except the repository location.
@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable { case connecting, connected, unavailable(String) }
    enum Panel: String, Identifiable, CaseIterable {
        case library, builds, mods, amiibo, profile, settings, diagnostics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: return "Library"
            case .builds: return "Builds"
            case .mods: return "Mods"
            case .amiibo: return "Amiibo"
            case .profile: return "Profile"
            case .settings: return "Settings"
            case .diagnostics: return "Diagnostics"
            }
        }
        var symbol: String {
            switch self {
            case .library: return "square.grid.2x2.fill"
            case .builds: return "hammer.fill"
            case .mods: return "puzzlepiece.extension.fill"
            case .amiibo: return "dot.radiowaves.left.and.right"
            case .profile: return "person.crop.circle.fill"
            case .settings: return "gearshape.fill"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    @Published var connection: Connection = .connecting
    @Published var hello: Hello?
    @Published var status: AgentStatus?
    @Published var library: [LibraryApp] = []
    @Published var details: [String: AppDetails] = [:]
    @Published var art: [String: NSImage] = [:]
    @Published var jobs: [Job] = []
    @Published var logs: [String: [String]] = [:]
    @Published var mods: ModsList?
    @Published var settings: SettingsReply?
    @Published var message: String?
    @Published var panel: Panel?
    @Published var setupFiles: [URL]?
    @Published var installing = false
    @Published var profile = Profile.load() {
        didSet { profile.save() }
    }
    @Published var update: UpdateCheck?
    @Published var disk: DiskInfo?
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: "welcomed")
    @Published var downloading = false
    /// Set when GitHub answers 404/403: the repository is private, so these two features cannot reach it yet.
    @Published var updateNote: String?
    @Published var sourceNote: String?
    /// Developer menu fixture: ten tiles that never reach the agent, for testing the carousel.
    @Published var showMockGames = UserDefaults.standard.bool(forKey: "showMockGames") {
        didSet { UserDefaults.standard.set(showMockGames, forKey: "showMockGames") }
    }

    private var client: AgentClient?
    private var started = false

    var activeJobs: [Job] { jobs.filter(\.isActive) }
    var macApps: [LibraryApp] {
        let real = library.filter { $0.platform == "macos" }
        let all = showMockGames ? real + MockLibrary.apps : real
        return all.sorted { $0.built > $1.built }
    }

    // MARK: connection

    func start() {
        guard !started else { return }
        started = true
        Task { await connectLoop() }
    }

    private func connectLoop() async {
        while true {
            if client == nil { await connectOnce() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func connectOnce() async {
        let c = AgentClient()
        do {
            try c.connect()
            c.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
            c.onClose = { [weak self] in
                Task { @MainActor in
                    self?.client = nil
                    self?.connection = .unavailable("The background agent stopped.")
                }
            }
            client = c
            try await c.subscribe()
            let greeting = try await c.hello()
            guard greeting.protocol >= 1 else {
                throw AgentError(code: "protocol", message: "The background agent is too old for this app. Reinstall it from Settings.")
            }
            hello = greeting
            connection = .connected
            await refreshAll()
        } catch {
            c.close()
            client = nil
            connection = .unavailable(error.localizedDescription)
        }
    }

    func refreshAll() async {
        guard let c = client else { return }
        do {
            async let s = c.status()
            async let l = c.library()
            async let j = c.jobs()
            async let m = c.mods()
            async let st = c.settings()
            status = try await s
            library = try await l
            jobs = try await j
            mods = try await m
            settings = try await st
            // Keep the app's checkout and the agent's repo setting in step.
            if let repo = settings?.settings["repo"]?.string, Self.isRepository(URL(fileURLWithPath: repo)) {
                UserDefaults.standard.set(repo, forKey: "repoPath")
            } else if let saved = UserDefaults.standard.string(forKey: "repoPath"), Self.isRepository(URL(fileURLWithPath: saved)) {
                setSettings(["repo": .string(saved)])
            }
            await refreshDetails()
        } catch { report(error) }
    }

    private func refreshDetails() async {
        guard let c = client else { return }
        for app in library {
            guard let d = try? await c.details(app: app.path) else { continue }
            details[app.path] = d
            if let icon = d.icon, art[app.path] == nil, let image = NSImage(contentsOfFile: icon) { art[app.path] = image }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .job(let job):
            let wasActive = jobs.first(where: { $0.id == job.id })?.isActive ?? false
            if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
            if wasActive, !job.isActive, !NSApp.isActive { Notifier.finished(job) }
            if !job.isActive { Task { self.status = try? await self.client?.status() } }
        case .log(let id, let line):
            var lines = logs[id] ?? []
            lines.append(line)
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
            logs[id] = lines
        case .library:
            Task { if let l = try? await client?.library() { library = l; await refreshDetails() } }
        case .mods:
            Task { mods = try? await client?.mods() }
        case .settings:
            Task { settings = try? await client?.settings() }
        case .other:
            break
        }
    }

    func report(_ error: Error) {
        message = (error as? AgentError)?.message ?? error.localizedDescription
    }

    private func perform(_ work: @escaping (AgentClient) async throws -> Void) {
        guard let c = client else { message = "The background agent is not running."; return }
        Task {
            do { try await work(c) } catch { report(error) }
        }
    }

    // MARK: actions

    func play(_ app: LibraryApp) {
        guard !MockLibrary.isMock(app) else {
            message = "That is a mock tile for the carousel test; there is no app behind it to launch."
            return
        }
        perform { try await $0.launch(app: app.path) }
    }
    func rebuild(_ app: LibraryApp) {
        guard !MockLibrary.isMock(app) else { message = "Mock tiles cannot be rebuilt."; return }
        perform { _ = try await $0.rebuild(app: app.path) }
    }
    func forget(_ app: LibraryApp) {
        guard !MockLibrary.isMock(app) else { message = "Mock tiles are not in the library; turn them off in Settings."; return }
        perform { try await $0.forget(app: app.path) }
    }
    func cancel(_ job: Job) { perform { _ = try await $0.cancel(job: job.id) } }
    func showInFinder(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func detect(_ urls: [URL]) async throws -> Detection {
        guard let c = client else { throw AgentError.unavailable("the agent is not running") }
        return try await c.detect(urls.map(\.path))
    }

    func build(game: String, update: String?, keys: String?) async throws -> Job {
        guard let c = client else { throw AgentError.unavailable("the agent is not running") }
        let job = try await c.submitBuild(game: game, update: update, keys: keys)
        if !jobs.contains(where: { $0.id == job.id }) { jobs.insert(job, at: 0) }
        return job
    }

    func loadLog(_ job: Job) { perform { c in let lines = try await c.log(job: job.id); await MainActor.run { self.logs[job.id] = lines } } }

    func setSettings(_ values: [String: JSONValue]) { perform { c in _ = try await c.setSettings(values); let s = try await c.settings(); await MainActor.run { self.settings = s } } }

    func addMod(folder: URL, version: String) {
        perform { c in
            let result = try await c.addMod(source: folder.path, version: version, name: nil)
            let m = try await c.mods()
            await MainActor.run {
                self.mods = m
                if let problem = result["apply_error"]?.string { self.message = "Added, but not enabled: \(problem)" }
            }
        }
    }
    func enableMod(_ mod: Mod, _ on: Bool) { perform { c in _ = try await c.enableMod(mod.id, on); let m = try await c.mods(); await MainActor.run { self.mods = m } } }
    func removeMod(_ mod: Mod) { perform { c in _ = try await c.removeMod(mod.id); let m = try await c.mods(); await MainActor.run { self.mods = m } } }
    func importMods(_ version: String) { perform { c in _ = try await c.importMods(version: version); let m = try await c.mods(); await MainActor.run { self.mods = m } } }

    func diagnosticsReport() async -> JSONValue? { try? await client?.diagnostics() }
    func exportDiagnostics(to url: URL) {
        perform { c in
            let path = try await c.exportDiagnostics(to: url.path)
            await MainActor.run { self.showInFinder(path) }
        }
    }

    // MARK: installing the agent

    /// The Switchy checkout: remembered, or found above this app (swift run / a build next to the repo).
    var repository: URL? {
        if let saved = UserDefaults.standard.string(forKey: "repoPath"), Self.isRepository(URL(fileURLWithPath: saved)) {
            return URL(fileURLWithPath: saved)
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if Self.isRepository(url) { return url }
        }
        return nil
    }

    static func isRepository(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("build_app.py").path) &&
            fm.fileExists(atPath: url.appendingPathComponent("mng_agent/__main__.py").path)
    }

    func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Switchy folder (the one with build_app.py)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard Self.isRepository(url) else { message = "\(url.path) has no build_app.py and mng_agent."; return nil }
        UserDefaults.standard.set(url.path, forKey: "repoPath")
        return url
    }

    static var pythonPath: String {
        ["/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var agentHomePath: String {
        hello?.home ?? NSHomeDirectory() + "/Library/Application Support/MacNativeGames/agent"
    }

    var agentLogPath: String { agentHomePath + "/agent.log" }

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomed")
        showWelcome = false
    }

    /// Fetches a fresh source tree from GitHub into Application Support, so the DMG works without a developer checkout.
    func downloadSource() {
        guard let url = URL(string: "https://github.com/coldrazer/Switchy/archive/refs/heads/main.tar.gz") else { return }
        downloading = true
        sourceNote = nil
        Task {
            defer { downloading = false }
            do {
                let (archive, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 404 || http.statusCode == 403 {
                    sourceNote = "The source download needs the public repository. Choose your local checkout instead."
                    return
                }
                guard http.statusCode == 200 else {
                    throw AgentError(code: "download", message: "GitHub returned HTTP \(http.statusCode).")
                }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Switchy", isDirectory: true)
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let staging = support.appendingPathComponent("download.tmp", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xzf", archive.path, "-C", staging.path]
                try tar.run()
                tar.waitUntilExit()
                guard tar.terminationStatus == 0,
                      let extracted = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                        .first(where: { Self.isRepository($0) }) else {
                    throw AgentError(code: "download", message: "The downloaded archive did not look like Switchy.")
                }
                let target = support.appendingPathComponent("Source", isDirectory: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: extracted, to: target)
                try? FileManager.default.removeItem(at: staging)
                setRepository(target)
                installAgent()
            } catch { report(error) }
        }
    }

    func installAgent() {
        guard let repo = repository ?? chooseRepository() else { return }
        installing = true
        // Installs (or reinstalls) the LaunchAgent from the checkout the app is using.
        runAgent(["-m", "mng_agent", "install", "--repo", repo.path])
    }

    func uninstallAgent() {
        runAgent(["-m", "mng_agent", "uninstall"]) { [weak self] ok in
            guard let self, ok else { return }
            self.client?.close()
            self.client = nil
            self.connection = .unavailable("The agent was removed. Use Install agent to bring it back.")
        }
    }

    func restartAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.macnativegames.agent"]
        do {
            try process.run()
            process.waitUntilExit()
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await connectOnce()
            }
        } catch { report(error) }
    }

    func revealAgentLog() {
        let url = URL(fileURLWithPath: agentLogPath)
        if FileManager.default.fileExists(atPath: agentLogPath) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: agentHomePath))
        }
    }

    /// Remembers the checkout for both the app (agent install) and the agent (builds, mods).
    func setRepository(_ url: URL) {
        guard Self.isRepository(url) else {
            message = "\(url.path) has no build_app.py and mng_agent."
            return
        }
        UserDefaults.standard.set(url.path, forKey: "repoPath")
        setSettings(["repo": .string(url.path)])
    }

    /// Everything back to the agent's defaults: no paths, the documented switches, no game overrides.
    func resetAllSettings() {
        var values: [String: JSONValue] = [:]
        for key in ["keys", "work_dir", "output_dir", "firmware", "shared_fonts", "repo"] { values[key] = .null }
        values["resume_interrupted"] = .bool(true)
        values["watch_inputs"] = .bool(true)
        values["auto_rebuild"] = .bool(false)
        var game: [String: JSONValue] = [:]
        for name in (settings?.game.keys).map({ Array($0) }) ?? [] { game[name] = .null }
        if !game.isEmpty { values["game"] = .object(game) }
        setSettings(values)
    }

    func exportSettings(to url: URL) {
        guard let settings else { message = "Settings are not loaded yet."; return }
        let payload: [String: JSONValue] = ["version": 1, "settings": .object(settings.settings)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch { report(error) }
    }

    func importSettings(from url: URL) {
        let allowed = ["repo", "work_dir", "output_dir", "keys", "firmware", "shared_fonts", "resume_interrupted",
                       "watch_inputs", "auto_rebuild", "watch_interval_s", "keep_jobs", "game"]
        do {
            let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            guard let values = root["settings"]?.object else { throw AgentError(code: "invalid", message: "No settings object in that file.") }
            var clean: [String: JSONValue] = [:]
            for (key, value) in values where allowed.contains(key) { clean[key] = value }
            guard !clean.isEmpty else { throw AgentError(code: "invalid", message: "That file has no settings this app knows.") }
            setSettings(clean)
        } catch { report(error) }
    }

    func openUpdate() {
        guard let link = update?.url, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    private func runAgent(_ arguments: [String], then completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let repo = repository else {
            message = "Choose your Switchy folder first (Settings → Switchy folder)."
            return
        }
        installing = true
        let python = Self.pythonPath
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = arguments
            process.currentDirectoryURL = repo
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = ""
            var ok = false
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting: a full pipe blocks
                process.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
                ok = process.terminationStatus == 0
            } catch { output = error.localizedDescription }
            let said = output.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.installing = false
                if !ok { self.message = "The agent command failed: \(said)" }
                completion?(ok)
            }
            if ok, arguments.contains("install") { await self.connectOnce() }
        }
    }
}
#endif

// MARK: - Profile

/// What the menu's avatar represents: a local-only identity, never sent anywhere except this Mac's defaults.
struct Profile: Codable, Equatable {
    var name: String = ""
    var handle: String = ""
    var about: String = ""

    var displayName: String { name.isEmpty ? NSFullUserName() : name }

    var initials: String {
        let source = name.isEmpty ? NSFullUserName() : name
        let parts = source.split(separator: " ").prefix(2).compactMap(\.first).map(String.init)
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }

    private static let key = "profile"

    static func load() -> Profile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Profile.self, from: data) else { return Profile() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - Update check

struct UpdateCheck: Equatable {
    var latest: String
    var url: String
    var isNewer: Bool
}

struct DiskInfo: Equatable {
    var freeGB: Double
    var volume: String
}

extension AppModel {
    /// Ask GitHub for the latest release. The app is ad-hoc signed, so it does not install the update itself: it opens
    /// the release page and lets the user drag the new build in.
    func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/coldrazer/Switchy/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 || http.statusCode == 403 {
                updateNote = "Update checks need the public repository; this is a private development build."
                return
            }
            guard http.statusCode == 200 else {
                message = "Could not check for updates (HTTP \(http.statusCode))."
                return
            }
            updateNote = nil
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let html = object["html_url"] as? String else { return }
            update = UpdateCheck(latest: tag, url: html, isNewer: SemanticVersion.isNewer(tag, than: appVersion))
        } catch { report(error) }
    }

    func measureDisk(path: String? = nil) {
        let url = URL(fileURLWithPath: path ?? settings?.settings["work_dir"]?.string ?? NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
        let bytes = Double(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        disk = DiskInfo(freeGB: bytes / 1_000_000_000, volume: values?.volumeName ?? "the work folder's volume")
    }

    /// Before queueing a build: the pipeline wants about 25 GB free next to the work folder.
    func hasRoomForBuild(path: String? = nil) -> Bool {
        measureDisk(path: path)
        return (disk?.freeGB ?? 0) >= 25
    }
}
