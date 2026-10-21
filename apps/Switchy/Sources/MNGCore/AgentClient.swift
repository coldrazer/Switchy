import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AgentError: Error, Equatable, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }

    public static func unavailable(_ why: String) -> AgentError { AgentError(code: "unavailable", message: why) }
    public var isUnavailable: Bool { code == "unavailable" }
}

/// One connection to the agent socket (mng_agent/protocol.py): newline-delimited JSON requests, responses and events.
/// A background thread reads the socket; `call` suspends until its response arrives; events go to `onEvent`.
public final class AgentClient: @unchecked Sendable {
    public let path: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    /// Called on the reader thread for every pushed event.
    public var onEvent: (@Sendable (AgentEvent) -> Void)?
    /// Called once when the connection ends (agent stopped, socket closed).
    public var onClose: (@Sendable () -> Void)?

    public init(path: String = Format.defaultSocketPath()) {
        self.path = path
    }

    deinit { close() }

    public func connect() throws {
        let s = socket(AF_UNIX, streamSocketType, 0)
        guard s >= 0 else { throw AgentError.unavailable("socket(): \(String(cString: strerror(errno)))") }
        #if canImport(Darwin)
        var on: Int32 = 1   // a write to a closed agent returns EPIPE instead of killing the app
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin_or_Glibc_close(s)
            throw AgentError.unavailable("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(s, $0, size) }
        }
        guard result == 0 else {
            let why = String(cString: strerror(errno))
            Darwin_or_Glibc_close(s)
            throw AgentError.unavailable("the agent is not running (\(why))")
        }
        lock.lock(); fd = s; closed = false; lock.unlock()
        let thread = Thread { [weak self] in self?.readLoop(s) }
        thread.name = "agent-socket"
        thread.start()
    }

    public func close() {
        lock.lock()
        let s = fd
        let wasClosed = closed
        closed = true
        fd = -1
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        if s >= 0 { _ = shutdown(s, shutdownBoth); Darwin_or_Glibc_close(s) }
        for (_, continuation) in waiting { continuation.resume(throwing: AgentError.unavailable("connection closed")) }
        if !wasClosed { onClose?() }
    }

    /// Send a request and wait for its result, decoded as T.
    public func call<T: Decodable>(_ method: String, _ params: [String: JSONValue] = [:], as type: T.Type = T.self) async throws -> T {
        let raw = try await callRaw(method, params)
        let data = try JSONEncoder().encode(raw)
        return try decoder.decode(T.self, from: data)
    }

    public func callRaw(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            lock.lock()
            guard !closed, fd >= 0 else {
                lock.unlock()
                continuation.resume(throwing: AgentError.unavailable("not connected"))
                return
            }
            let id = nextId
            nextId += 1
            pending[id] = continuation
            let s = fd
            lock.unlock()
            let request: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": .object(params)]
            guard var data = try? JSONEncoder().encode(request) else {
                fail(id, AgentError(code: "bad_request", message: "cannot encode the request"))
                return
            }
            data.append(0x0A)
            if !writeAll(s, data) { fail(id, AgentError.unavailable("write failed")) }
        }
    }

    // MARK: - internals

    private func fail(_ id: Int, _ error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func writeAll(_ s: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = send(s, raw.baseAddress! + offset, raw.count - offset, sendFlags)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    private func readLoop(_ s: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(s, &chunk, chunk.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { dispatch(Data(line)) }
            }
            if buffer.count > 2 << 20 { break }   // an agent line is at most 1 MiB
        }
        close()
    }

    private func dispatch(_ line: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        if message["event"] != nil {
            if let event = AgentEvent.parse(message, decoder: decoder) { onEvent?(event) }
            return
        }
        guard let idNumber = message["id"]?.number else { return }
        let id = Int(idNumber)
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if let error = message["error"] {
            continuation.resume(throwing: AgentError(code: error["code"]?.string ?? "error",
                                                     message: error["message"]?.string ?? "unknown error"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }
}

// MARK: - typed calls

public extension AgentClient {
    func hello() async throws -> Hello { try await call("hello") }
    func status() async throws -> AgentStatus { try await call("status") }
    func subscribe() async throws { _ = try await callRaw("subscribe") }
    func detect(_ paths: [String]) async throws -> Detection {
        try await call("detect", ["paths": .array(paths.map { .string($0) })])
    }
    func submitBuild(game: String, update: String?, keys: String?, platform: String = "macos") async throws -> Job {
        var params: [String: JSONValue] = ["game": .string(game), "platform": .string(platform)]
        if let update { params["update"] = .string(update) }
        if let keys { params["keys"] = .string(keys) }
        return try await call("build.submit", params)
    }
    func jobs(limit: Int = 50) async throws -> [Job] { try await call("jobs.list", ["limit": .number(Double(limit))]) }
    func cancel(job: String) async throws -> Job { try await call("jobs.cancel", ["id": .string(job)]) }
    func log(job: String, tail: Int = 200) async throws -> [String] {
        (try await call("jobs.log", ["id": .string(job), "tail": .number(Double(tail))], as: LogLines.self)).lines
    }
    func library() async throws -> [LibraryApp] { try await call("library.list") }
    func details(app: String) async throws -> AppDetails { try await call("library.details", ["path": .string(app)]) }
    func rebuild(app: String) async throws -> Job { try await call("library.rebuild", ["path": .string(app)]) }
    func forget(app: String) async throws { _ = try await callRaw("library.remove", ["path": .string(app)]) }
    func launch(app: String?) async throws {
        _ = try await callRaw("launch", app.map { ["path": .string($0)] } ?? [:])
    }
    func settings() async throws -> SettingsReply { try await call("settings.get") }
    func setSettings(_ values: [String: JSONValue]) async throws -> [String: JSONValue] {
        try await call("settings.set", ["values": .object(values)])
    }
    func mods(version: String? = nil) async throws -> ModsList {
        try await call("mods.list", version.map { ["version": .string($0)] } ?? [:])
    }
    func addMod(source: String, version: String, name: String?) async throws -> JSONValue {
        var params: [String: JSONValue] = ["source": .string(source), "version": .string(version)]
        if let name { params["name"] = .string(name) }
        return try await callRaw("mods.add", params)
    }
    func enableMod(_ id: String, _ enabled: Bool) async throws -> JSONValue {
        try await callRaw("mods.enable", ["id": .string(id), "enabled": .bool(enabled)])
    }
    func removeMod(_ id: String) async throws -> JSONValue { try await callRaw("mods.remove", ["id": .string(id)]) }
    func importMods(version: String) async throws -> JSONValue {
        try await callRaw("mods.import", ["version": .string(version)])
    }
    func diagnostics() async throws -> JSONValue { try await callRaw("diagnostics.report") }
    func exportDiagnostics(to destination: String) async throws -> String {
        (try await call("diagnostics.export", ["destination": .string(destination)], as: ExportReply.self)).path
    }
}

// MARK: - platform shims

@inline(__always) func Darwin_or_Glibc_close(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}

@inline(__always) func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ size: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, size)
    #else
    return Glibc.connect(fd, address, size)
    #endif
}

#if canImport(Darwin)
let streamSocketType: Int32 = SOCK_STREAM
let shutdownBoth: Int32 = SHUT_RDWR
let sendFlags: Int32 = 0                      // SIGPIPE is off per socket (SO_NOSIGPIPE)
#else
let streamSocketType: Int32 = Int32(SOCK_STREAM.rawValue)
let shutdownBoth: Int32 = Int32(SHUT_RDWR)
let sendFlags: Int32 = Int32(MSG_NOSIGNAL)
#endif
