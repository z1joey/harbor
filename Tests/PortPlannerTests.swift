import XCTest
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
                                  port: port, readyURL: nil, autoRestart: false, env: [:])
            }
            .sorted { $0.name < $1.name }
        return Project(root: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       processes: processes, portClaims: claims,
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
}
