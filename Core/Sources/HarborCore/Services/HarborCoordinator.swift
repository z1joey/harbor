import Foundation
import Darwin

/// Orchestration logic shared by the GUI and the TUI: PID→managed-holder
/// resolution (ancestor walk), auto-port planning, free-port suggestions and
/// the Ports Overview row model. Holds references to the three core services;
/// the frontends own their construction and wiring.
@MainActor
public final class HarborCoordinator {
    public let registry: ProjectRegistry
    public let observer: PortObserver
    public let supervisor: ProcessSupervisor

    public init(registry: ProjectRegistry, observer: PortObserver, supervisor: ProcessSupervisor) {
        self.registry = registry
        self.observer = observer
        self.supervisor = supervisor
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

    /// Ports unavailable for auto assignment: listeners, static claims, in-flight assignments.
    public func autoPortTakenSet() -> Set<Int> {
        var taken = Set(observer.listeners.map(\.port))
        for project in registry.projects {
            taken.formUnion(project.claimedPorts)
        }
        taken.formUnion(supervisor.assignedPorts())
        return taken
    }

    public func allocateAutoPort() -> Int? {
        PortPlanner.allocatePort(taken: autoPortTakenSet(), isBindable: PortPlanner.isBindable)
    }

    /// Port numbers free across every registered project and current listener.
    public func suggestedFreePorts(count: Int = 5, from base: Int = 8000) -> [Int] {
        PortPlanner.suggestFreePorts(count: count, from: base, taken: autoPortTakenSet())
    }

    /// Assigned auto ports per process key (for the overview's `:NNNN auto` rows).
    public func assignedPortsByKey() -> [ProcessKey: Int] {
        var result: [ProcessKey: Int] = [:]
        for (key, status) in supervisor.statuses {
            if let port = status.assignedPort {
                result[key] = port
            }
        }
        return result
    }

    // MARK: - Ports Overview rows

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

    /// Pure row model for the Ports Overview (both frontends render it their
    /// own way). Rows cover the union of claimed and currently-listening ports.
    public static func overviewRows(projects: [Project],
                                    listeners: [Listener],
                                    holdersByPID: [pid_t: PortPlanner.ManagedHolder],
                                    assignedPorts: [ProcessKey: Int]) -> [OverviewRow] {
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
                } else if definition.autoPort {
                    let key = ProcessKey(projectID: project.id, processName: definition.name)
                    if let assigned = assignedPorts[key] {
                        register(port: assigned, projectName: project.name,
                                 detail: "process \(definition.name) (auto)")
                    }
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
