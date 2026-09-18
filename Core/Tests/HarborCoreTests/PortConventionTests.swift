import XCTest
@testable import HarborCore
import Darwin

final class PortConventionTests: XCTestCase {
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

    func testConventionRowsAreOnlyLeasedPoolPorts() {
        let pool = PortPool.default
        let shop = project("shop",
                           processPorts: ["web": 8100, "vite": 5173],
                           claims: [PortClaim(port: 5432, note: "postgres", processName: nil)])
        let api = project("api", processPorts: ["server": 8101])
        let holders: [pid_t: PortPlanner.ManagedHolder] = [
            11: PortPlanner.ManagedHolder(projectID: "/tmp/shop", projectName: "shop", processName: "web"),
        ]
        let rows = HarborCoordinator.conventionRows(
            pool: pool,
            projects: [shop, api],
            listeners: [listener(8100, 11), listener(5432, 99, name: "postgres")],
            holdersByPID: holders
        )
        XCTAssertEqual(rows.map(\.port), [8100, 8101])
        XCTAssertEqual(rows.map(\.processName), ["web", "server"])
        XCTAssertEqual(rows[0].managedHolder?.processName, "web")
        XCTAssertNil(rows[1].listener)
        XCTAssertFalse(rows.contains { $0.port == 5173 })
        XCTAssertFalse(rows.contains { $0.port == 5432 })
    }

    func testOtherClaimRowsAreNonPoolProcessPortsAndPortClaims() {
        let pool = PortPool.default
        let shop = project("shop",
                           processPorts: ["web": 8100, "vite": 5173],
                           claims: [PortClaim(port: 5432, note: "postgres", processName: nil)])
        let rows = HarborCoordinator.otherClaimRows(
            pool: pool,
            projects: [shop],
            listeners: [listener(5432, 55, name: "postgres")],
            holdersByPID: [:]
        )
        XCTAssertEqual(rows.map(\.port), [5173, 5432])
        XCTAssertEqual(rows.first { $0.port == 5173 }?.claimDetails.first, "shop — process vite")
        XCTAssertEqual(rows.first { $0.port == 5432 }?.claimDetails.first, "shop — postgres")
        XCTAssertFalse(rows.contains { $0.port == 8100 })
    }

    func testConventionDoesNotRenderUnusedPoolPorts() {
        let rows = HarborCoordinator.conventionRows(
            pool: .default,
            projects: [project("only", processPorts: ["api": 8105])],
            listeners: [],
            holdersByPID: [:]
        )
        XCTAssertEqual(rows.map(\.port), [8105])
        XCTAssertEqual(rows.count, 1)
    }

    func testPoolSummaryCountsUniqueLeasedPorts() {
        // Evaluated via the same counting the coordinator uses.
        let projects = [
            project("a", processPorts: ["web": 8100, "api": 8100]),
            project("b", processPorts: ["web": 8101, "vite": 5173]),
        ]
        let allocated = Set(projects.flatMap { project in
            project.processes.compactMap { definition -> Int? in
                guard let port = definition.port, PortPool.default.contains(port) else { return nil }
                return port
            }
        })
        XCTAssertEqual(allocated, [8100, 8101])
        XCTAssertEqual(PortPool.default.capacity, 100)
    }
}
