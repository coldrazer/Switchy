import Foundation

// The agent's objects (mng_agent/store.py, jobs.py, server.py). Keys arrive in snake_case.

public struct Hello: Codable, Equatable, Sendable {
    public var agent: String
    public var version: String
    public var `protocol`: Int
    public var pid: Int
    public var home: String
    public var repo: String
    public var platform: String
}

public struct JobStep: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var title: String
    public var status: String          // pending running done resumed skipped failed interrupted
    public var started: Double?
    public var finished: Double?
    public var error: String?
    public var id: String { name }
}

public struct JobResult: Codable, Equatable, Sendable {
    public var app: String?
    public var version: String?
    public var displayVersion: String?
    public var platform: String?
}

public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var status: String          // queued running succeeded failed cancelled
    public var created: Double
    public var started: Double?
    public var finished: Double?
    public var attempt: Int?
    public var currentStep: String?
    public var error: String?
    public var result: JobResult?
    public var steps: [JobStep]
    public var params: [String: JSONValue]

    public var isActive: Bool { status == "queued" || status == "running" }
    public var output: String? { params["out"]?.string }

    /// Steps that count towards progress (the ones that apply to this build).
    public var applicableSteps: [JobStep] { steps.filter { $0.status != "skipped" } }

    /// 0...1: finished steps over applicable steps; nil before the runner has sent its plan.
    public var progress: Double? {
        let applicable = applicableSteps
        guard !applicable.isEmpty else { return nil }
        if status == "succeeded" { return 1 }
        let finished = applicable.filter { $0.status == "done" || $0.status == "resumed" }.count
        return Double(finished) / Double(applicable.count)
    }

    public var currentTitle: String? {
        guard let name = currentStep else { return nil }
        return steps.first { $0.name == name }?.title ?? name
    }
}

public struct LibraryApp: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var version: String
    public var displayVersion: String
    public var platform: String
    public var built: Double
    public var job: String?
    public var params: [String: JSONValue]?
    public var stale: Bool?
    public var missing: Bool?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }

    public init(path: String, version: String, displayVersion: String, platform: String, built: Double,
                job: String? = nil, params: [String: JSONValue]? = nil, stale: Bool? = nil, missing: Bool? = nil) {
        self.path = path
        self.version = version
        self.displayVersion = displayVersion
        self.platform = platform
        self.built = built
        self.job = job
        self.params = params
        self.stale = stale
        self.missing = missing
    }
}

public struct AppDetails: Codable, Equatable, Sendable {
    public var path: String
    public var version: String
    public var displayVersion: String
    public var platform: String
    public var built: Double
    public var stale: Bool
    public var missing: Bool
    public var icon: String?
    public var shadersSeeded: Int?
    public var shaderCacheFiles: Int
    public var saveFiles: Int
    public var modsEnabled: Int
    public var modsState: String
}

public struct Mod: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public var added: Double
    public var source: String?
    public var present: Bool?
    public var files: Int?
}

public struct ModFolder: Codable, Equatable, Sendable {
    public var path: String
    public var state: String           // none composed manual
}

public struct ModsList: Codable, Equatable, Sendable {
    public var mods: [Mod]
    public var folders: [String: ModFolder]
}

public struct GameFile: Codable, Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var size: Int?
    public var kind: String?
    public var role: String
    public var title: String?
    public var note: String?
    public var titleId: String?
    public var game: String?
    public var supported: Bool?
    public var reason: String?
}

public struct Detection: Codable, Equatable, Sendable {
    public var files: [GameFile]
    public var base: String?
    public var update: String?
    public var keys: String?
    public var supported: Bool?
    public var reason: String?
}

public struct GameSettingInfo: Codable, Equatable, Sendable {
    public var env: String
    public var description: String
    public var values: [String]?
}

public struct SettingsReply: Codable, Equatable, Sendable {
    public var settings: [String: JSONValue]
    public var game: [String: GameSettingInfo]
}

public struct AgentStatus: Codable, Equatable, Sendable {
    public var active: [Job]
    public var library: Int
    public var toolchain: [String: JSONValue]
    public var install: [String: JSONValue]
    public var toolchainReady: Bool { toolchain["ready"]?.bool ?? false }
    /// The prerequisites build_app.py would stop on.
    public var missingTools: [String] {
        toolchain.compactMap { key, value in
            guard key != "ready", key != "platform" else { return nil }
            switch value { case .null, .bool(false): return key; default: return nil }
        }.sorted()
    }
}

public struct LogLines: Codable, Equatable, Sendable { public var lines: [String] }
public struct ExportReply: Codable, Equatable, Sendable { public var path: String }

/// What the agent pushes to subscribers.
public enum AgentEvent: Equatable, Sendable {
    case job(Job)
    case log(job: String, message: String)
    case library
    case mods
    case settings
    case other(String)

    static func parse(_ value: JSONValue, decoder: JSONDecoder) -> AgentEvent? {
        guard let name = value["event"]?.string else { return nil }
        switch name {
        case "job":
            guard let raw = value["job"], let data = try? JSONEncoder().encode(raw),
                  let job = try? decoder.decode(Job.self, from: data) else { return .other(name) }
            return .job(job)
        case "job.log":
            return .log(job: value["job"]?.string ?? "", message: value["message"]?.string ?? "")
        case "library": return .library
        case "mods": return .mods
        case "settings": return .settings
        default: return .other(name)
        }
    }
}

public enum Format {
    /// "1.4.3" style label for a library app or a build in progress.
    public static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// The default socket path, as mng_agent/server.py socket_path() names it.
    public static func defaultSocketPath(home: String = NSHomeDirectory(),
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["MNG_AGENT_SOCKET"], !path.isEmpty { return path }
        if let agentHome = environment["MNG_AGENT_HOME"], !agentHome.isEmpty {
            return (agentHome as NSString).appendingPathComponent("agent.sock")
        }
        return (home as NSString).appendingPathComponent("Library/Application Support/MacNativeGames/agent/agent.sock")
    }
}
