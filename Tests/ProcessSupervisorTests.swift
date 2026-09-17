import XCTest
import Darwin

@MainActor
final class ProcessSupervisorTests: XCTestCase {
    private var projectRoot: URL!
    private var supervisor: ProcessSupervisor!

    override func setUp() async throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        supervisor = ProcessSupervisor()
    }

    override func tearDown() async throws {
        // Make sure nothing leaks between tests even on failure paths.
        await supervisor.stopAllRunning()
        supervisor.emergencyStopAll()
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private func start(_ name: String, command: String, cwd: String? = nil,
                       port: Int? = nil, readyURL: URL? = nil,
                       autoRestart: Bool = false, env: [String: String] = [:]) -> ProcessKey {
        let key = ProcessKey(projectID: projectRoot.path, processName: name)
        let definition = ProcessDefinition(name: name, command: command, cwd: cwd,
                                           port: port, readyURL: readyURL,
                                           autoRestart: autoRestart, env: env)
        let result = supervisor.start(key: key, definition: definition, projectRoot: projectRoot)
        guard case .success = result else {
            XCTFail("start(\(name)) failed: \(result)")
            return key
        }
        return key
    }

    func testKeyForPIDResolvesManagedProcessOnlyWhileRunning() async throws {
        let key = start("tracked", command: "sleep 30")
        try await Task.sleep(nanoseconds: 800_000_000)
        let pid = try XCTUnwrap(supervisor.status(for: key).pid)
        XCTAssertEqual(supervisor.key(forPID: pid), key)

        await supervisor.stop(key: key)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(supervisor.key(forPID: pid), "PID mapping must clear after stop")
    }

    func testRunsWithConfiguredWorkingDirectoryAndEnv() async throws {
        let key = start("cwdcheck", command: "pwd > out.txt; echo $HARBOR_TEST_VAR >> out.txt; sleep 30",
                        cwd: "sub", env: ["HARBOR_TEST_VAR": "hello42"])
        defer { Task { await supervisor.stop(key: key) } }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(supervisor.status(for: key).state, .running)
        XCTAssertNotNil(supervisor.status(for: key).pid)

        let output = try String(contentsOf: projectRoot.appendingPathComponent("sub/out.txt"), encoding: .utf8)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        XCTAssertEqual(lines.first?.hasSuffix("/sub"), true, "pwd should be the configured cwd, got \(lines.first ?? "nil")")
        XCTAssertTrue(output.contains("hello42"))
    }

    func testStopKillsTreeAndClearsRunningState() async throws {
        let key = start("tree", command: "sleep 301 & sleep 302 & wait")
        try await Task.sleep(nanoseconds: 800_000_000)
        let pid = try XCTUnwrap(supervisor.status(for: key).pid)

        await supervisor.stop(key: key)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(supervisor.status(for: key).state, .stopped)
        XCTAssertFalse(ProcessKiller.isAlive(pid), "root must be dead after Stop")
        XCTAssertTrue(ProcessKiller.descendants(of: pid, in: ProcessKiller.processTable()).isEmpty,
                      "children must be dead after Stop")
    }

    func testLogsStreamIntoBuffer() async throws {
        let key = start("logger", command: "for i in 1 2 3; do echo \"tick $i\"; sleep 0.3; done; sleep 30")
        defer { Task { await supervisor.stop(key: key) } }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !supervisor.logBuffer(for: key).snapshot().contains("tick 3") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(supervisor.logBuffer(for: key).snapshot().contains { $0.contains("tick 3") },
                      "logs should stream within ~1s of being written")
    }

    func testUnexpectedExitMarksFailedAndKeepsLogs() async throws {
        let key = start("crasher", command: "echo about-to-crash; exit 3")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(supervisor.status(for: key).state, .failed)
        XCTAssertEqual(supervisor.status(for: key).exitCode, 3)
        XCTAssertTrue(supervisor.logBuffer(for: key).snapshot().contains { $0.contains("about-to-crash") },
                      "last logs must remain readable after failure")
    }

    func testAutoRestartRecoversFromExternalKillAndUserStopDoesNotRestart() async throws {
        let key = start("auto", command: "sleep 300", autoRestart: true)
        try await Task.sleep(nanoseconds: 800_000_000)
        let firstPID = try XCTUnwrap(supervisor.status(for: key).pid)
        kill(firstPID, SIGKILL)

        // Backoff (1s) + respawn.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, supervisor.status(for: key).pid == nil
           || supervisor.status(for: key).pid == firstPID {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let secondPID = try XCTUnwrap(supervisor.status(for: key).pid)
        XCTAssertNotEqual(firstPID, secondPID, "auto-restart must spawn a new process")
        XCTAssertEqual(supervisor.status(for: key).state, .running)

        await supervisor.stop(key: key)
        try await Task.sleep(nanoseconds: 2_500_000_000) // longer than the first backoff
        XCTAssertEqual(supervisor.status(for: key).state, .stopped)
        XCTAssertFalse(ProcessKiller.isAlive(secondPID), "user stop must not leave the process running")
        XCTAssertEqual(supervisor.status(for: key).pid, nil)
    }

    func testRunningCountTracksConcurrentProcesses() async throws {
        let a = start("a", command: "sleep 60")
        let b = start("b", command: "sleep 60")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(supervisor.runningCount(), 2)

        await supervisor.stop(key: a)
        await supervisor.stop(key: b)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(supervisor.runningCount(), 0)
    }

    func testMissingWorkingDirectoryFailsStart() {
        let key = ProcessKey(projectID: projectRoot.path, processName: "badcwd")
        let definition = ProcessDefinition(name: "badcwd", command: "echo hi", cwd: "does-not-exist",
                                           port: nil, readyURL: nil, autoRestart: false, env: [:])
        let result = supervisor.start(key: key, definition: definition, projectRoot: projectRoot)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for missing cwd")
        }
        XCTAssertTrue(error.message.contains("does-not-exist"))
        XCTAssertEqual(supervisor.status(for: key).state, .failed)
    }
}
