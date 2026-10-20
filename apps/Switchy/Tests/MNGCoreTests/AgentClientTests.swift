import Foundation
import XCTest
@testable import MNGCore

/// MNGCore against the real Python agent (mng_agent) with the harmless test pipeline: the same socket protocol the
/// app speaks. Needs python3 and the repository; skipped when either is missing.
final class AgentClientTests: XCTestCase {
    var root: URL!
    var agent: Process?
    var socketPath: String { root.appendingPathComponent("s.sock").path }
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        guard FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent("mng_agent/server.py").path) else {
            throw XCTSkip("the repository is not next to this package")
        }
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mngt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("g"), withIntermediateDirectories: true)
        var xci = Data(count: 0x100)
        xci.append(contentsOf: Array("HEAD".utf8))
        xci.append(Data(count: 512))
        try xci.write(to: root.appendingPathComponent("g/totk.xci"))
        try "header_key = 00\nkey_area_key_application_00 = 11\ntitlekek_00 = 22\n"
            .write(to: root.appendingPathComponent("g/prod.keys"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-m", "mng_agent", "serve"]
        p.currentDirectoryURL = Self.repo
        var env = ProcessInfo.processInfo.environment
        env["MNG_AGENT_HOME"] = root.appendingPathComponent("home").path
        env["MNG_AGENT_SOCKET"] = socketPath
        env["MNG_GAME_DATA"] = root.appendingPathComponent("data").path
        env["MNG_AGENT_PIPELINE"] = "agent_fake_pipeline:BUILD"
        env["PYTHONPATH"] = Self.repo.appendingPathComponent("tests").path + ":" + Self.repo.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        agent = p
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketPath) { usleep(50_000) }
        guard FileManager.default.fileExists(atPath: socketPath) else { throw XCTSkip("the agent did not start") }
    }

    override func tearDown() {
        agent?.terminate()
        agent?.waitUntilExit()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func connected() throws -> AgentClient {
        let client = AgentClient(path: socketPath)
        try client.connect()
        return client
    }

    func testHelloStatusAndErrors() async throws {
        let client = try connected()
        defer { client.close() }
        let hello = try await client.hello()
        XCTAssertEqual(hello.agent, "com.macnativegames.agent")
        XCTAssertEqual(hello.protocol, 1)
        let status = try await client.status()
        XCTAssertEqual(status.library, 0)
        do {
            _ = try await client.callRaw("no.such.method")
            XCTFail("expected an error")
        } catch let error as AgentError {
            XCTAssertEqual(error.code, "unknown_method")
        }
        do {
            _ = try await client.submitBuild(game: "/nowhere.xci", update: nil, keys: nil)
            XCTFail("expected an error")
        } catch let error as AgentError {
            XCTAssertEqual(error.code, "invalid_params")
        }
    }

    func testBuildEventsLibraryDetailsAndSettings() async throws {
        let client = try connected()
        defer { client.close() }
        let events = EventLog()
        client.onEvent = { events.append($0) }
        try await client.subscribe()
        let detection = try await client.detect([root.appendingPathComponent("g/totk.xci").path,
                                                 root.appendingPathComponent("g/prod.keys").path])
        XCTAssertEqual(detection.files.first?.kind, "xci")
        XCTAssertNotNil(detection.base)
        XCTAssertNotNil(detection.keys)
        let job = try await client.submitBuild(game: detection.base!, update: nil, keys: detection.keys)
        XCTAssertEqual(job.status, "queued")
        var finished: Job?
        for _ in 0..<200 {
            if let j = events.jobs.last(where: { $0.id == job.id && !$0.isActive }) { finished = j; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(finished?.status, "succeeded")
        XCTAssertEqual(finished?.progress, 1)
        XCTAssertTrue(events.logs.contains("fake step package"))
        XCTAssertTrue(events.sawLibrary)
        let library = try await client.library()
        XCTAssertEqual(library.count, 1)
        XCTAssertEqual(library.first?.displayVersion, "1.0.0")
        XCTAssertEqual(library.first?.name, "Tears of the Kingdom")
        let details = try await client.details(app: library[0].path)
        XCTAssertEqual(details.saveFiles, 0)
        XCTAssertEqual(details.modsState, "none")
        XCTAssertNil(details.icon)
        let lines = try await client.log(job: job.id)
        XCTAssertTrue(lines.contains("fake step data"))
        let settings = try await client.setSettings(["game": ["operation_mode": "handheld"]])
        XCTAssertEqual(settings["game"]?["operation_mode"]?.string, "handheld")
        let reply = try await client.settings()
        XCTAssertEqual(reply.game["operation_mode"]?.env, "TOTK_OPERATION_MODE")
        let mods = try await client.mods()
        XCTAssertEqual(mods.folders["v143"]?.state, "none")
    }

    func testUnavailableAgent() async throws {
        let client = AgentClient(path: root.appendingPathComponent("missing.sock").path)
        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertTrue((error as? AgentError)?.isUnavailable ?? false)
        }
        do {
            _ = try await client.hello()
            XCTFail("expected an error")
        } catch let error as AgentError {
            XCTAssertTrue(error.isUnavailable)
        }
    }

    func testConnectionCloseFailsPendingCalls() async throws {
        let client = try connected()
        let closed = expectation(description: "closed")
        client.onClose = { closed.fulfill() }
        agent?.terminate()
        await fulfillment(of: [closed], timeout: 10)
        do {
            _ = try await client.hello()
            XCTFail("expected an error")
        } catch let error as AgentError {
            XCTAssertTrue(error.isUnavailable)
        }
    }
}

final class ModelTests: XCTestCase {
    func testJobProgressAndDecoding() throws {
        let json = """
        {"id":"a1","kind":"build","status":"running","created":1.5,"started":2,"finished":null,"attempt":1,
         "current_step":"data","error":null,"result":null,"params":{"out":"/x/T.app","no_shader_reminder":true},
         "steps":[{"name":"code","title":"Rewriting","status":"done","started":1,"finished":2},
                  {"name":"identify_update","title":"Identify","status":"skipped","started":null,"finished":null},
                  {"name":"data","title":"Extracting","status":"running","started":3,"finished":null},
                  {"name":"binary","title":"Binary","status":"pending","started":null,"finished":null}]}
        """
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let job = try d.decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(job.progress!, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(job.currentTitle, "Extracting")
        XCTAssertEqual(job.output, "/x/T.app")
        XCTAssertTrue(job.isActive)
    }

    func testJSONValueRoundTripsIntegersAsIntegers() throws {
        let value: JSONValue = ["n": 3, "f": .number(1.5), "s": "x", "b": true, "z": nil, "a": [1, "2"]]
        let text = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"n\":3"))
        XCTAssertFalse(text.contains("3.0"))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value)
    }

    func testStatusMissingTools() throws {
        let status = AgentStatus(active: [], library: 0, toolchain: ["ready": false, "git": "/usr/bin/git",
                                                                      "xcrun": nil, "homebrew_opus": false,
                                                                      "platform": "Linux x86_64"], install: [:])
        XCTAssertEqual(status.missingTools, ["homebrew_opus", "xcrun"])
        XCTAssertFalse(status.toolchainReady)
    }

    func testDefaultSocketPath() {
        XCTAssertEqual(Format.defaultSocketPath(home: "/Users/a", environment: [:]),
                       "/Users/a/Library/Application Support/MacNativeGames/agent/agent.sock")
        XCTAssertEqual(Format.defaultSocketPath(home: "/Users/a", environment: ["MNG_AGENT_HOME": "/h"]), "/h/agent.sock")
        XCTAssertEqual(Format.defaultSocketPath(home: "/Users/a", environment: ["MNG_AGENT_SOCKET": "/s"]), "/s")
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    func append(_ e: AgentEvent) { lock.lock(); events.append(e); lock.unlock() }
    private var snapshot: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var jobs: [Job] { snapshot.compactMap { if case .job(let j) = $0 { return j }; return nil } }
    var logs: [String] { snapshot.compactMap { if case .log(_, let m) = $0 { return m }; return nil } }
    var sawLibrary: Bool { snapshot.contains(.library) }
}
