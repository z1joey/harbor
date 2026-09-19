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
        return Project(configURL: URL(fileURLWithPath: "/tmp/harbor-test/\(name).toml"),
                       root: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       processes: processes, portClaims: claims,
                       openProcessName: nil, openURL: nil,
                       configError: nil)
    }

    /// Maps a PID to a managed project with the given name.
    private func resolver(_ holders: [pid_t: String]) -> (pid_t) -> PortPlanner.ManagedHolder? {
        return { pid in
            guard let name = holders[pid] else { return nil }
            return PortPlanner.ManagedHolder(projectID: "/tmp/harbor-test/\(name).toml", projectName: name,
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

    // MARK: - Claim gates (start time)

    func testBoundClaimHeldByForeignListenerGatesStart() {
        // The dictionary-app regression: a stale container squats on the port
        // the process is about to publish; `start` must surface it instead of
        // sailing through.
        let alpha = project("alpha",
                            claims: [PortClaim(port: 8080, note: "frontend", processName: "app")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app"],
                                                   listeners: [listener(8080, 4242, name: "com.docker.backend")],
                                                   managedHolder: resolver([:]))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].port, 8080)
        XCTAssertEqual(conflicts[0].processName, "app")
        XCTAssertEqual(conflicts[0].listener.pid, 4242)
        XCTAssertNil(conflicts[0].managedHolder)
        XCTAssertEqual(conflicts[0].holderLabel, "com.docker.backend")
    }

    func testFreePortDoesNotGateClaimStart() {
        let alpha = project("alpha", claims: [PortClaim(port: 8080, note: nil, processName: "app")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app"],
                                                   listeners: [listener(9999, 1)],
                                                   managedHolder: resolver([:]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testUnboundClaimNeverGatesStart() {
        // Unbound claims are dependency declarations (a brew postgres): being
        // held is their healthy state, never a start blocker.
        let alpha = project("alpha", claims: [PortClaim(port: 5432, note: "postgres", processName: nil)])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app"],
                                                   listeners: [listener(5432, 55)],
                                                   managedHolder: resolver([:]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testClaimBoundToOtherProcessDoesNotGate() {
        let alpha = project("alpha", claims: [PortClaim(port: 8001, note: "api", processName: "backend")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["web"],
                                                   listeners: [listener(8001, 55)],
                                                   managedHolder: resolver([:]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testSameProjectHolderDoesNotGateClaimStart() {
        let alpha = project("alpha", claims: [PortClaim(port: 8080, note: nil, processName: "app")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app"],
                                                   listeners: [listener(8080, 7)],
                                                   managedHolder: resolver([7: "alpha"]))
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testOtherProjectManagedHolderGatesClaimStart() {
        let alpha = project("alpha", claims: [PortClaim(port: 8080, note: nil, processName: "app")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app"],
                                                   listeners: [listener(8080, 99)],
                                                   managedHolder: resolver([99: "beta"]))
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].managedHolder?.projectName, "beta")
    }

    func testStartAllGatesEveryBoundClaimSortedByPort() {
        let alpha = project("alpha", claims: [PortClaim(port: 8080, note: "frontend", processName: "app"),
                                              PortClaim(port: 8001, note: "api", processName: "app")])
        let conflicts = PortPlanner.claimConflicts(forProject: alpha,
                                                   startingProcesses: ["app", "worker"],
                                                   listeners: [listener(8080, 1), listener(8001, 2)],
                                                   managedHolder: resolver([:]))
        XCTAssertEqual(conflicts.map(\.port), [8001, 8080])
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

    // MARK: - Pool port suggestions

    func testAllocatePortSkipsTakenPorts() {
        let port = PortPlanner.allocatePort(taken: [8100, 8101, 8102], isBindable: { _ in true })
        XCTAssertEqual(port, 8103)
    }

    func testAllocatePortUsesConfiguredPoolNotLegacyAutoBand() {
        let pool = PortPool(ranges: [PortRange(from: 9000, to: 9002)])
        XCTAssertEqual(PortPlanner.allocatePort(taken: [], pool: pool, isBindable: { _ in true }), 9000)
        XCTAssertEqual(PortPlanner.allocatePort(taken: [9000], pool: pool, isBindable: { _ in true }), 9001)
        XCTAssertNil(PortPlanner.allocatePort(taken: [9000, 9001, 9002], pool: pool, isBindable: { _ in true }))
        // 8100 is free but outside this pool — must not be suggested.
        XCTAssertNotEqual(PortPlanner.allocatePort(taken: [9000, 9001, 9002], pool: pool, isBindable: { _ in true }), 8100)
    }

    func testAllocatePortRespectsDefaultPoolCeiling() {
        var taken = Set(8100...8199)
        taken.remove(8199)
        let port = PortPlanner.allocatePort(taken: taken, isBindable: { _ in true })
        XCTAssertEqual(port, 8199)
        XCTAssertNil(PortPlanner.allocatePort(taken: Set(8100...8199), isBindable: { _ in true }))
    }

    func testAllocatePortDoesNotScanLegacy9999Band() {
        // The old auto range was 8100–9999. With the default pool, 8200+ is out.
        var taken = Set(8100...8199)
        XCTAssertNil(PortPlanner.allocatePort(taken: taken, isBindable: { _ in true }))
        taken.remove(8200)
        XCTAssertNil(PortPlanner.allocatePort(taken: taken, isBindable: { _ in true }),
                     "8200 is outside the default 8100–8199 pool")
    }

    func testIsBindableRejectsOccupiedPort() throws {
        let server = try startListeningServer(on: 0)
        defer { server.close() }
        let boundPort = try XCTUnwrap(server.boundPort)
        XCTAssertFalse(PortPlanner.isBindable(boundPort))
        XCTAssertTrue(PortPlanner.isBindable(boundPort + 1))
    }

    func testCommandReferencesDeclaredPort() {
        XCTAssertTrue(PortPlanner.commandReferencesDeclaredPort("python3 -m http.server $PORT", port: 8100, envName: "PORT"))
        XCTAssertTrue(PortPlanner.commandReferencesDeclaredPort("python3 -m http.server 8100", port: 8100, envName: "PORT"))
        XCTAssertFalse(PortPlanner.commandReferencesDeclaredPort("python3 -m http.server 81000", port: 8100, envName: "PORT"))
        XCTAssertFalse(PortPlanner.commandReferencesDeclaredPort("npm run dev", port: 8100, envName: "PORT"))
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
        let status = ProcessStatus(state: .running, pid: 10,
                                   startedAt: now.addingTimeInterval(-3))
        XCTAssertNil(PortPlanner.portVerification(
            status: status,
            definitionPort: 8100,
            listeners: [listener(5173, 10)],
            processTable: [(10, 1)],
            now: now
        ))
    }

    func testPortVerificationDetectsMismatchAfterGrace() {
        let now = Date()
        let status = ProcessStatus(state: .running, pid: 10,
                                   startedAt: now.addingTimeInterval(-6))
        let verification = PortPlanner.portVerification(
            status: status,
            definitionPort: 8100,
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
