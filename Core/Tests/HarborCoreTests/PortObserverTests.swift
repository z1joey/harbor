import XCTest
@testable import HarborCore

final class PortObserverTests: XCTestCase {
    /// A realistic lsof row set: header, IPv4+IPv6 duplicates for one pid,
    /// trailing (LISTEN) state column, and a full command name with spaces.
    private let fixtureOutput = """
    COMMAND               PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    ControlCenter         634   joey   11u  IPv4  0x18cc3237425b8c71      0t0 TCP *:7000 (LISTEN)
    ControlCenter         634   joey   12u  IPv6 0x55efce7acb85c1c1      0t0 TCP *:7000 (LISTEN)
    Google Chrome        1234   joey   31u  IPv4  0x9aab3237425b8c71      0t0 TCP 127.0.0.1:9222 (LISTEN)
    Python               5678   joey    4u  IPv6 0x55efce7acb85c1c1      0t0 TCP *:8765 (LISTEN)
    """

    func testParsesRowsAndDeduplicatesByPortAndPID() {
        let listeners = PortObserver.parseLsofOutput(fixtureOutput)
        // (7000, 634) appears twice (IPv4+IPv6) — must dedupe to one row.
        XCTAssertEqual(listeners.count, 3)
        XCTAssertTrue(listeners.contains { $0.port == 7000 && $0.pid == 634 && $0.proto == "TCP" })
        XCTAssertTrue(listeners.contains { $0.port == 9222 && $0.pid == 1234 && $0.processName == "Google Chrome" })
        XCTAssertTrue(listeners.contains { $0.port == 8765 && $0.pid == 5678 })
    }

    func testIgnoresNonTCPAndMalformedRows() {
        let noisy = """
        COMMAND  PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        somed    99  joey 5u unix 0xabc 0t0 ->0xdef
        weird line with too few fields
        Python   100 joey 4u IPv6 0x0 0t0 TCP *:70000 (LISTEN)
        Python   101 joey 4u IPv6 0x0 0t0 TCP *:notaport (LISTEN)
        """
        XCTAssertTrue(PortObserver.parseLsofOutput(noisy).isEmpty)
    }

    func testEmptyOutputParsesToEmptyList() {
        XCTAssertTrue(PortObserver.parseLsofOutput("").isEmpty)
    }

    func testCollectListenersSucceedsAgainstLiveLsof() {
        if case .failure(let message) = PortObserver.collectListeners() {
            XCTFail("live lsof collection failed: \(message)")
        }
    }

    func testForeignListenerExcludesManagedPIDs() {
        let listeners = PortObserver.parseLsofOutput(fixtureOutput)
        // Port 8765 is held by PID 5678: with it managed, no foreign listener remains.
        XCTAssertNil(PortObserver.foreignListener(in: listeners, on: 8765, managedPIDs: [5678]))
        // Without it managed, the listener is found.
        XCTAssertEqual(PortObserver.foreignListener(in: listeners, on: 8765, managedPIDs: [])?.pid, 5678)
        // Ports nobody holds yield nil / no pids.
        XCTAssertNil(PortObserver.foreignListener(in: listeners, on: 1, managedPIDs: []))
        XCTAssertTrue(PortObserver.pidsListening(in: listeners, on: 8765) == [5678])
    }

    func testListenerCommandDisplayFallsBackToProcessName() {
        var listener = PortObserver.parseLsofOutput(fixtureOutput)[0]
        XCTAssertFalse(listener.commandDisplay.isEmpty)
        listener.command = "python3 -m http.server"
        XCTAssertEqual(listener.commandDisplay, "python3 -m http.server")
    }
}
