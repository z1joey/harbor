import XCTest
@testable import HarborCore
import Darwin

final class PortPlannerTests: XCTestCase {
    // MARK: - Fixtures

    private func listener(_ port: Int, _ pid: pid_t, name: String = "node") -> Listener {
        Listener(port: port, pid: pid, processName: name, user: "me", proto: "TCP", command: nil)
    }

    private func project(_ name: String,
                         processPorts: [String: Int] = [:],
                         claims: [PortClaim] = []) -> Project {
        let processes = processPorts
            .map { processName, port in
                ProcessDefinition(name: processName, command: "run \(processName)", cwd: nil,
                                  port: port, autoRestart: false, env: [:])
            }
            .sorted { $0.name < $1.name }
        return Project(root: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       processes: processes, portClaims: claims,
                       openProcessName: nil, openURL: nil,
                       configFileName: "harbor.toml", configError: nil)
    }

    /// Maps a PID to a managed project with the given name.
    private func resolver(_ holders: [pid_t: String]) -> (pid_t) -> PortPlanner.ManagedHolder? {
        return { pid in
            guard let name = holders[pid] else { return nil }
            return PortPlanner.ManagedHolder(projectID: "/tmp/\(name)", projectName: name,
                                             processName: "proc")
        }
    }

    // MARK: - Claims

    func testClaimsUnionProcessPortsAndPortClaims() {
        let alpha = project("alpha",
                            processPorts: ["web": 5173],
                            claims: [PortClaim(port: 5432, note: "postgres", processName: nil)])
        let claims = PortPlanner.claims(projects: [alpha])
        XCTAssertEqual(Set(claims.map { $0.claim.port }), [5173, 5432])
        XCTAssertEqual(Set(claims.map { $0.projectName }), ["alpha"])
        let webClaim = claims.first { $0.claim.port == 5173 }?.claim
        XCTAssertEqual(webClaim?.processName, "web")
    }

    func testProjectClaimedPortsUnion() {
        let alpha = project("alpha", processPorts: ["api": 8001],
                            claims: [PortClaim(port: 6379, note: nil, processName: "api")])
        XCTAssertEqual(alpha.claimedPorts, [8001, 6379])
    }

    // MARK: - Runtime conflicts

    func testForeignHolderConflicts() {
        let alpha = project("alpha", processPorts: ["api": 8001])
        let conflicts = PortPlanner.conflicts(forProject: alpha,
                                              listeners: [listener(8001, 4242, name: "stray-server")],
                                              managedHolder: resolver([:]))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].port, 8001)
        XCTAssertEqual(conflicts[0].listener.pid, 4242)
        XCTAssertNil(conflicts[0].managedHolder)
        XCTAssertEqual(conflicts[0].holderLabel, "stray-server")
    }

    func testManagedHolderFromOtherProjectConflicts() {
        // This is the case the old foreign-listener check silently ignored:
        // project beta (managed by Harbor) holds alpha's port.
        let alpha = project("alpha", processPorts: ["api": 8001])
        let conflicts = PortPlanner.conflicts(forProject: alpha,
                                              listeners: [listener(8001, 99)],
                                              managedHolder: resolver([99: "beta"]))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].managedHolder?.projectName, "beta")
        XCTAssertEqual(conflicts[0].holderLabel, "beta · proc")
    }

    func testSameProjectHolderIsNotAConflict() {
        let alpha = project("alpha", processPorts: ["api": 8001])
        let conflicts = PortPlanner.conflicts(forProject: alpha,
                                              listeners: [listener(8001, 7)],
                                              managedHolder: resolver([7: "alpha"]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testFreePortIsNotAConflict() {
        let alpha = project("alpha", processPorts: ["api": 8001],
                            claims: [PortClaim(port: 5432, note: nil, processName: nil)])
        let conflicts = PortPlanner.conflicts(forProject: alpha,
                                              listeners: [listener(9999, 1)],
                                              managedHolder: resolver([:]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testPortClaimHeldByForeignPIDIsNotARuntimeConflict() {
        // Claims describe infrastructure the project relies on (postgres via
        // brew services, Docker-published ports). Their holders are never
        // managed PIDs, so they must not light the conflict warning —
        // claims only feed static overlaps and the ports overview.
        let alpha = project("alpha",
                            claims: [PortClaim(port: 5432, note: "postgres", processName: "deps")])
        let conflicts = PortPlanner.conflicts(forProject: alpha,
                                              listeners: [listener(5432, 55)],
                                              managedHolder: resolver([:]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testRuntimeConflictsSortsByPortAcrossProjects() {
        let alpha = project("alpha", processPorts: ["api": 9000])
        let beta = project("beta", processPorts: ["web": 5173])
        let conflicts = PortPlanner.runtimeConflicts(
            projects: [alpha, beta],
            listeners: [listener(9000, 1), listener(5173, 2)],
            managedHolder: resolver([:]))
        XCTAssertEqual(conflicts.map(\.port), [5173, 9000])
    }

    // MARK: - Static overlaps

    func testStaticOverlapDetectsPortsClaimedByTwoProjects() {
        let alpha = project("alpha", processPorts: ["web": 5173])
        let beta = project("beta", claims: [PortClaim(port: 5173, note: "vite", processName: nil)])
        let gamma = project("gamma", processPorts: ["api": 8001])
        let overlaps = PortPlanner.staticOverlaps(projects: [alpha, beta, gamma])
        XCTAssertEqual(overlaps.count, 1)
        XCTAssertEqual(overlaps[0].port, 5173)
        XCTAssertEqual(overlaps[0].projects, ["alpha", "beta"])
    }

    func testOverlapsRequireTwoDistinctProjects() {
        // One project claiming a port twice (process + claim would be rejected
        // by the parser, but two claims on one port must not overlap itself).
        let alpha = project("alpha", claims: [PortClaim(port: 5432, note: "a", processName: nil),
                                              PortClaim(port: 5432, note: "b", processName: nil)])
        XCTAssertTrue(PortPlanner.staticOverlaps(projects: [alpha]).isEmpty)
    }

    // MARK: - Suggestions

    func testSuggestFreePortsSkipsTakenPorts() {
        let suggestions = PortPlanner.suggestFreePorts(count: 3, from: 8000,
                                                       taken: [8000, 8001, 5432])
        XCTAssertEqual(suggestions, [8002, 8003, 8004])
    }

    func testSuggestFreePortsStartsAtBaseEvenIfFree() {
        let suggestions = PortPlanner.suggestFreePorts(count: 2, from: 9000, taken: [])
        XCTAssertEqual(suggestions, [9000, 9001])
    }

    func testSuggestFreePortsStopsAtPortCeiling() {
        let suggestions = PortPlanner.suggestFreePorts(count: 3, from: 65534, taken: [])
        XCTAssertEqual(suggestions, [65534, 65535])
    }

    // MARK: - Auto port allocation

    func testAllocatePortSkipsTakenPorts() {
        let port = PortPlanner.allocatePort(taken: [8100, 8101, 8102], isBindable: { _ in true })
        XCTAssertEqual(port, 8103)
    }

    func testAllocatePortRespectsRange() {
        var taken = Set(PortPlanner.autoPortRange)
        taken.remove(9999)
        let port = PortPlanner.allocatePort(taken: taken, isBindable: { _ in true })
        XCTAssertEqual(port, 9999)
    }

    func testAllocatePortReturnsNilWhenRangeExhausted() {
        let port = PortPlanner.allocatePort(taken: Set(PortPlanner.autoPortRange), isBindable: { _ in true })
        XCTAssertNil(port)
    }

    func testIsBindableRejectsOccupiedPort() throws {
        let server = try startListeningServer(on: 0)
        defer { server.close() }
        let boundPort = try XCTUnwrap(server.boundPort)
        XCTAssertFalse(PortPlanner.isBindable(boundPort))
        XCTAssertTrue(PortPlanner.isBindable(boundPort + 1))
    }

    func testCommandReferencesPortEnv() {
        XCTAssertTrue(PortPlanner.commandReferencesPortEnv("npm run dev -- --port $PORT", envName: "PORT"))
        XCTAssertTrue(PortPlanner.commandReferencesPortEnv("uvicorn --port ${PORT}", envName: "PORT"))
        XCTAssertFalse(PortPlanner.commandReferencesPortEnv("python3 -m http.server 8123", envName: "PORT"))
    }

    func testPortMismatch() {
        XCTAssertTrue(PortPlanner.portMismatch(expected: 8100, observed: [5173]))
        XCTAssertFalse(PortPlanner.portMismatch(expected: 8100, observed: [8100]))
        XCTAssertFalse(PortPlanner.portMismatch(expected: 8100, observed: []))
    }

    func testObservedListeningPortsWalksDescendantTree() {
        let table: [(pid: pid_t, ppid: pid_t)] = [(1, 0), (10, 1), (11, 10)]
        let listeners = [
            listener(8100, 11),
            listener(5173, 99),
        ]
        XCTAssertEqual(PortPlanner.observedListeningPorts(rootPID: 1, listeners: listeners, processTable: table),
                       [8100])
    }

    func testPortVerificationRespectsGracePeriod() {
        let now = Date()
        let status = ProcessStatus(state: .running, pid: 10, assignedPort: 8100,
                                   startedAt: now.addingTimeInterval(-3))
        XCTAssertNil(PortPlanner.portVerification(
            status: status,
            definitionPort: nil,
            listeners: [listener(5173, 10)],
            processTable: [(10, 1)],
            now: now
        ))
    }

    func testPortVerificationDetectsMismatchAfterGrace() {
        let now = Date()
        let status = ProcessStatus(state: .running, pid: 10, assignedPort: 8100,
                                   startedAt: now.addingTimeInterval(-6))
        let verification = PortPlanner.portVerification(
            status: status,
            definitionPort: nil,
            listeners: [listener(5173, 10)],
            processTable: [(10, 1)],
            now: now
        )
        XCTAssertEqual(verification?.expected, 8100)
        XCTAssertEqual(verification?.observed, [5173])
    }

    func testPortVerificationUsesDefinitionPortWhenNotAutoAssigned() {
        let now = Date()
        let status = ProcessStatus(state: .running, pid: 10, startedAt: now.addingTimeInterval(-6))
        XCTAssertNil(PortPlanner.portVerification(
            status: status,
            definitionPort: 8000,
            listeners: [listener(8000, 10)],
            processTable: [(10, 1)],
            now: now
        ))
        let verification = PortPlanner.portVerification(
            status: status,
            definitionPort: 8000,
            listeners: [listener(8001, 10)],
            processTable: [(10, 1)],
            now: now
        )
        XCTAssertEqual(verification?.expected, 8000)
        XCTAssertEqual(verification?.observed, [8001])
    }

    private func startListeningServer(on port: Int) throws -> (close: () -> Void, boundPort: Int?) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "test", code: 1) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "test", code: 2)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "test", code: 3)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsock = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let boundPort = getsock == 0 ? Int(UInt16(bigEndian: bound.sin_port)) : nil
        return (close: { close(fd) }, boundPort: boundPort)
    }
}
