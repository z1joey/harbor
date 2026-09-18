import Foundation
import Darwin

/// Orchestration logic shared by the GUI and the TUI: PID→managed-holder
/// resolution (ancestor walk), pool-port suggestions and the Port Allocation
/// Convention row model. Holds references to the core services; the frontends
/// own their construction and wiring.
@MainActor
public final class HarborCoordinator {
    public let registry: ProjectRegistry
    public let observer: PortObserver
    public let supervisor: ProcessSupervisor
    public let portPoolStore: PortPoolStore

    public init(registry: ProjectRegistry,
                observer: PortObserver,
                supervisor: ProcessSupervisor,
                portPoolStore: PortPoolStore) {
        self.registry = registry
        self.observer = observer
        self.supervisor = supervisor
        self.portPoolStore = portPoolStore
    }

    // MARK: - PID → managed holder

    /// Snapshot of every process as (pid → parent pid), one sysctl walk.
    public func processTableParents() -> [pid_t: pid_t] {
        Dictionary(ProcessKiller.processTable().map { ($0.pid, $0.ppid) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Which managed project/process a PID belongs to, if any. Listeners are
    /// usually grandchildren of the tracked PID (`zsh -lc` → `uv run` →
    /// `python` …), so this also walks the ancestor chain — otherwise Harbor
    /// would flag its own running processes as foreign port conflicts.
    public func managedHolder(forPID pid: pid_t) -> PortPlanner.ManagedHolder? {
        managedHolder(forPID: pid, parents: processTableParents())
    }

    public func managedHolder(forPID pid: pid_t, parents: [pid_t: pid_t]) -> PortPlanner.ManagedHolder? {
        var key = supervisor.key(forPID: pid)
        if key == nil {
            var ancestor = parents[pid]
            var steps = 0
            while let current = ancestor, current > 1, steps < 64 {
                if let found = supervisor.key(forPID: current) {
                    key = found
                    break
                }
                ancestor = parents[current]
                steps += 1
            }
        }
        guard let key else { return nil }
        let projectName = registry.projects.first(where: { $0.id == key.projectID })?.name ?? key.projectID
        return PortPlanner.ManagedHolder(projectID: key.projectID, projectName: projectName,
                                         processName: key.processName)
    }

    /// Batch-resolve managed holders for a listener list (one process-table walk).
    public func managedHolders(for listeners: [Listener]) -> [pid_t: PortPlanner.ManagedHolder] {
        let parents = processTableParents()
        var result: [pid_t: PortPlanner.ManagedHolder] = [:]
        for listener in listeners {
            if let holder = managedHolder(forPID: listener.pid, parents: parents) {
                result[listener.pid] = holder
            }
        }
        return result
    }

    /// True for PIDs Harbor manages directly or through a descendant process.
    public func isManagedOrDescendant(_ pid: pid_t) -> Bool {
        managedHolder(forPID: pid) != nil
    }

    // MARK: - Ports

    /// Ports unavailable for pool suggestions: listeners ∪ static claims.
    public func takenPorts() -> Set<Int> {
        var taken = Set(observer.listeners.map(\.port))
        for project in registry.projects {
            taken.formUnion(project.claimedPorts)
        }
        return taken
    }

    /// First free port in the configured pool (bind-probed). Suggestions only.
    public func nextFreePoolPort() -> Int? {
        PortPlanner.allocatePort(taken: takenPorts(), pool: portPoolStore.pool, isBindable: PortPlanner.isBindable)
    }

    /// Port numbers free in the configured pool (no bind probe).
    public func suggestedFreePorts(count: Int = 5) -> [Int] {
        PortPlanner.suggestFreePorts(count: count, pool: portPoolStore.pool, taken: takenPorts())
    }

    public var pool: PortPool { portPoolStore.pool }

    public func poolSummary(projects: [Project]? = nil) -> (label: String, allocated: Int, capacity: Int) {
        let pool = portPoolStore.pool
        let projects = projects ?? registry.projects
        let allocated = Set(projects.flatMap { project in
            project.processes.compactMap { definition -> Int? in
                guard let port = definition.port, pool.contains(port) else { return nil }
                return port
            }
        }).count
        return (pool.summary, allocated, pool.capacity)
    }

    // MARK: - Convention / overview rows

    /// A pool port leased by a registered `[[process]].port`.
    public struct ConventionRow: Identifiable, Equatable {
        public let port: Int
        public let projectName: String
        public let processName: String
        public let listener: Listener?
        public let managedHolder: PortPlanner.ManagedHolder?

        public var id: String { "\(port)::\(projectName)::\(processName)" }
    }

    /// One overview row: a port, who claims it in config, and who (if anyone)
    /// is listening on it right now.
    public struct OverviewRow: Identifiable, Equatable {
        public let port: Int
        public let projectNames: [String]
        public let claimDetails: [String]
        public let listener: Listener?
        public let managedHolder: PortPlanner.ManagedHolder?

        public var id: Int { port }
    }

    /// Only process ports that fall inside `pool`. One row per lease so an
    /// overlap still shows both projects. Unused pool ports are omitted.
    nonisolated public static func conventionRows(pool: PortPool,
                                      projects: [Project],
                                      listeners: [Listener],
                                      holdersByPID: [pid_t: PortPlanner.ManagedHolder]) -> [ConventionRow] {
        var listenerByPort: [Int: Listener] = [:]
        for listener in listeners where listenerByPort[listener.port] == nil {
            listenerByPort[listener.port] = listener
        }
        var rows: [ConventionRow] = []
        for project in projects {
            for definition in project.processes {
                guard let port = definition.port, pool.contains(port) else { continue }
                let listener = listenerByPort[port]
                rows.append(ConventionRow(
                    port: port,
                    projectName: project.name,
                    processName: definition.name,
                    listener: listener,
                    managedHolder: listener.flatMap { holdersByPID[$0.pid] }
                ))
            }
        }
        return rows.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.projectName != $1.projectName { return $0.projectName < $1.projectName }
            return $0.processName < $1.processName
        }
    }

    /// Claims that are not Harbor-convention leases: `[[port_claim]]`s and
    /// process ports outside the pool (framework defaults, hardcoded 5173, …).
    nonisolated public static func otherClaimRows(pool: PortPool,
                                      projects: [Project],
                                      listeners: [Listener],
                                      holdersByPID: [pid_t: PortPlanner.ManagedHolder]) -> [OverviewRow] {
        var namesByPort: [Int: Set<String>] = [:]
        var detailsByPort: [Int: [String]] = [:]
        func register(port: Int, projectName: String, detail: String) {
            namesByPort[port, default: []].insert(projectName)
            detailsByPort[port, default: []].append("\(projectName) — \(detail)")
        }
        for project in projects {
            for definition in project.processes {
                guard let port = definition.port, !pool.contains(port) else { continue }
                register(port: port, projectName: project.name, detail: "process \(definition.name)")
            }
            for claim in project.portClaims {
                let note = claim.note ?? "claim"
                register(port: claim.port, projectName: project.name, detail: note)
            }
        }
        var listenerByPort: [Int: Listener] = [:]
        for listener in listeners where listenerByPort[listener.port] == nil {
            listenerByPort[listener.port] = listener
        }
        return namesByPort.keys.sorted().map { port in
            let listener = listenerByPort[port]
            return OverviewRow(port: port,
                               projectNames: (namesByPort[port] ?? []).sorted(),
                               claimDetails: detailsByPort[port] ?? [],
                               listener: listener,
                               managedHolder: listener.flatMap { holdersByPID[$0.pid] })
        }
    }

    /// Union of claimed and currently-listening ports (Listening Ports already
    /// covers unclaimed listeners; kept for overlap planning helpers).
    nonisolated public static func overviewRows(projects: [Project],
                                    listeners: [Listener],
                                    holdersByPID: [pid_t: PortPlanner.ManagedHolder]) -> [OverviewRow] {
        var namesByPort: [Int: Set<String>] = [:]
        var detailsByPort: [Int: [String]] = [:]
        func register(port: Int, projectName: String, detail: String) {
            namesByPort[port, default: []].insert(projectName)
            detailsByPort[port, default: []].append("\(projectName) — \(detail)")
        }
        for project in projects {
            for definition in project.processes {
                if let port = definition.port {
                    register(port: port, projectName: project.name, detail: "process \(definition.name)")
                }
            }
            for claim in project.portClaims {
                let note = claim.note ?? "claim"
                register(port: claim.port, projectName: project.name, detail: note)
            }
        }
        var listenerByPort: [Int: Listener] = [:]
        for listener in listeners where listenerByPort[listener.port] == nil {
            listenerByPort[listener.port] = listener
        }
        let ports = Set(namesByPort.keys).union(listenerByPort.keys).sorted()
        return ports.map { port in
            let listener = listenerByPort[port]
            return OverviewRow(port: port,
                               projectNames: (namesByPort[port] ?? []).sorted(),
                               claimDetails: detailsByPort[port] ?? [],
                               listener: listener,
                               managedHolder: listener.flatMap { holdersByPID[$0.pid] })
        }
    }
}
