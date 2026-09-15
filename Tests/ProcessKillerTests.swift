import XCTest
import Darwin

final class ProcessKillerTests: XCTestCase {
    func testIsAliveForOwnProcess() {
        XCTAssertTrue(ProcessKiller.isAlive(getpid()))
    }

    func testIsAliveFalseForLikelyUnusedPID() {
        // PID 2^22-ish is out of range on macOS (pid_max ~99998); ESRCH expected.
        XCTAssertFalse(ProcessKiller.isAlive(999_999))
    }

    func testSendZeroSignalSucceedsForSelf() {
        if case .failure(let error) = ProcessKiller.send(0, to: getpid()) {
            XCTFail("signal 0 to own pid should succeed, got: \(error.message)")
        }
    }

    func testSendToRootIsPermissionDenied() {
        // Killing launchd (PID 1) as non-root must fail with a readable reason.
        guard case .failure(let error) = ProcessKiller.send(SIGTERM, to: 1) else {
            // Running as root in some CI images would succeed; skip in that case.
            return
        }
        XCTAssertTrue(error.message.contains("owned by another user"),
                      "unexpected message: \(error.message)")
    }

    func testDescendantsWalksPIDHierarchy() {
        let table: [(pid: pid_t, ppid: pid_t)] = [
            (1, 0), (10, 1), (11, 1), (100, 10), (101, 10), (200, 11), (300, 999),
        ]
        let descendants = ProcessKiller.descendants(of: 10, in: table)
        XCTAssertEqual(descendants, [100, 101])
        XCTAssertTrue(ProcessKiller.descendants(of: 300, in: table).isEmpty)
    }

    func testTerminateTreeKillsShellAndChildren() async throws {
        let tree = Process()
        tree.executableURL = URL(fileURLWithPath: "/bin/zsh")
        tree.arguments = ["-c", "sleep 301 & sleep 302 & wait"]
        try tree.run()
        let rootPID = tree.processIdentifier

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(ProcessKiller.descendants(of: rootPID, in: ProcessKiller.processTable()).isEmpty,
                       "expected child sleeps before kill")

        let result = await ProcessKiller.terminateTree(rootPID: rootPID, grace: 2.0)
        if case .failure(let error) = result {
            XCTFail("terminateTree failed: \(error.message)")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(ProcessKiller.isAlive(rootPID))
        XCTAssertTrue(ProcessKiller.descendants(of: rootPID, in: ProcessKiller.processTable()).isEmpty,
                      "children must not survive the tree kill")
    }
}
