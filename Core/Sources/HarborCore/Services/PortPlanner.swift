import Foundation
import Darwin

/// Pure port-conflict planning shared by the popover, project views and the
/// ports overview. No UI, no singletons — projects, listeners and the
/// PID→project resolver are all passed in, so the logic is unit-testable.
///
/// Two kinds of problems are detected:
/// - **Runtime conflicts** — a claimed port is being listened on right now by
///   a foreign process, or by another Harbor project's managed process.
///   (Managed-vs-managed collisions were invisible before the planner:
///   `foreignListener` deliberately ignored managed PIDs.)
/// - **Static overlaps** — two or more projects claim the same port even
///   though nothing is running yet. This is the planning-time warning.
public enum PortPlanner {
    /// A Harbor-managed process currently holding a port.
    public struct ManagedHolder: Hashable {
        public let projectID: String
        public let projectName: String
        public let processName: String

        public init(projectID: String, projectName: String, processName: String) {
            self.projectID = projectID
            self.projectName = projectName
            self.processName = processName
        }
    }

    /// One port a project needs, with its config-side source.
    public struct ClaimedPort: Hashable {
        public let port: Int
        /// `[[process]]` name when the port comes from a process entry; nil for a bare claim.
        public let processName: String?
        public let note: String?

        public init(port: Int, processName: String?, note: String?) {
            self.port = port
            self.processName = processName
            self.note = note
        }
    }

    /// A port a project needs while somebody else is listening on it.
    public struct RuntimeConflict: Identifiable, Hashable {
        public let projectID: String
        public let projectName: String
        public let port: Int
        /// Process the port is configured on, if it came from `[[process]].port`.
        public let processName: String?
        public let listener: Listener
        /// nil = holder is a foreign (unmanaged) process.
        public let managedHolder: ManagedHolder?

        public var id: String { "\(projectID)::\(port)::\(listener.pid)" }

        public var holderLabel: String {
            if let managedHolder {
                return "\(managedHolder.projectName) · \(managedHolder.processName)"
            }
            return listener.processName
        }
    }

    /// A port claimed by two or more projects — latent until both run at once.
    public struct StaticOverlap: Identifiable, Hashable {
        public let port: Int
        /// Claiming project names, sorted.
        public let projects: [String]

        public var id: Int { port }

        public init(port: Int, projects: [String]) {
            self.port = port
            self.projects = projects
        }
    }

    // MARK: - Claims

    /// Every port claim across all projects (process ports + `[[port_claim]]`).
    public static func claims(projects: [Project]) -> [(projectName: String, claim: ClaimedPort)] {
        var result: [(projectName: String, claim: ClaimedPort)] = []
        for project in projects {
            for definition in project.processes {
                guard let port = definition.port else { continue }
                result.append((project.name, ClaimedPort(port: port, processName: definition.name, note: nil)))
            }
            for claim in project.portClaims {
                result.append((project.name, ClaimedPort(port: claim.port, processName: claim.processName, note: claim.note)))
            }
        }
        return result
    }

    // MARK: - Runtime conflicts

    /// Conflicts for one project: ports of its `[[process]]` entries currently
    /// held by a foreign listener or by another project's managed process.
    /// Held by the project itself = it is simply running, never a conflict.
    ///
    /// `[[port_claim]]` ports are deliberately excluded: they describe
    /// infrastructure the project *relies on* (a brew-services postgres, a
    /// Docker-published port whose listener is com.docker.backend, …). Those
    /// holders never appear as managed PIDs even when everything is healthy,
    /// so treating them as conflicts would light the menubar warning
    /// permanently. Claims still drive static overlaps and the Port Allocation Convention.
    public static func conflicts(forProject project: Project,
                          listeners: [Listener],
                          managedHolder: (pid_t) -> ManagedHolder?) -> [RuntimeConflict] {
        var byPort: [Int: ClaimedPort] = [:]
        for definition in project.processes {
            guard let port = definition.port else { continue }
            byPort[port] = ClaimedPort(port: port, processName: definition.name, note: nil)
        }

        var conflicts: [RuntimeConflict] = []
        for (port, source) in byPort.sorted(by: { $0.key < $1.key }) {
            guard let listener = listeners.first(where: { $0.port == port }) else { continue }
            let holder = managedHolder(listener.pid)
            if let holder, holder.projectID == project.id { continue }
            conflicts.append(RuntimeConflict(
                projectID: project.id,
                projectName: project.name,
                port: port,
                processName: source.processName,
                listener: listener,
                managedHolder: holder
            ))
        }
        return conflicts
    }

    /// Conflicts across every registered project, sorted by port.
    public static func runtimeConflicts(projects: [Project],
                                 listeners: [Listener],
                                 managedHolder: (pid_t) -> ManagedHolder?) -> [RuntimeConflict] {
        projects
            .flatMap { conflicts(forProject: $0, listeners: listeners, managedHolder: managedHolder) }
            .sorted { $0.port != $1.port ? $0.port < $1.port : $0.projectName < $1.projectName }
    }

    // MARK: - Static overlaps

    /// Ports claimed by two or more projects, sorted by port.
    public static func staticOverlaps(projects: [Project]) -> [StaticOverlap] {
        var namesByPort: [Int: Set<String>] = [:]
        for (projectName, claim) in claims(projects: projects) {
            namesByPort[claim.port, default: []].insert(projectName)
        }
        return namesByPort
            .compactMap { port, names in
                names.count >= 2 ? StaticOverlap(port: port, projects: names.sorted()) : nil
            }
            .sorted { $0.port < $1.port }
    }

    // MARK: - Suggestions

    /// `count` port numbers starting from `base` that nothing claims or listens on.
    public static func suggestFreePorts(count: Int, from base: Int, taken: Set<Int>) -> [Int] {
        var suggestions: [Int] = []
        var candidate = max(base, 1)
        while suggestions.count < count, candidate <= 65535 {
            if !taken.contains(candidate) {
                suggestions.append(candidate)
            }
            candidate += 1
        }
        return suggestions
    }

    // MARK: - Pool suggestions

    /// First port in `pool` not in `taken` and passing `isBindable`.
    /// Used for skill-equivalent suggestions — not start-time assignment.
    public static func allocatePort(taken: Set<Int>,
                                    pool: PortPool = .default,
                                    isBindable: (Int) -> Bool = isBindable) -> Int? {
        for port in pool.ports where !taken.contains(port) && isBindable(port) {
            return port
        }
        return nil
    }

    /// `count` free ports from `pool`, skipping `taken` (no bind probe).
    public static func suggestFreePorts(count: Int, pool: PortPool, taken: Set<Int>) -> [Int] {
        var suggestions: [Int] = []
        for port in pool.ports where !taken.contains(port) {
            suggestions.append(port)
            if suggestions.count == count { break }
        }
        return suggestions
    }

    /// Returns true when `port` can be bound on 0.0.0.0 (catches stale lsof gaps).
    public static func isBindable(_ port: Int) -> Bool {
        guard port >= 1, port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Soft lint: does `command` reference the port env var (e.g. `$PORT`)?
    public static func commandReferencesPortEnv(_ command: String, envName: String) -> Bool {
        command.contains("$" + envName)
            || command.contains("${" + envName + "}")
    }

    /// Soft lint: command mentions `$PORT` / `${PORT}` or the decimal port number.
    public static func commandReferencesDeclaredPort(_ command: String, port: Int, envName: String) -> Bool {
        if commandReferencesPortEnv(command, envName: envName) { return true }
        let digits = String(port)
        var search = command.startIndex
        while let range = command.range(of: digits, range: search..<command.endIndex) {
            let beforeIsDigit: Bool
            if range.lowerBound > command.startIndex {
                beforeIsDigit = command[command.index(before: range.lowerBound)].isNumber
            } else {
                beforeIsDigit = false
            }
            let afterIsDigit = range.upperBound < command.endIndex && command[range.upperBound].isNumber
            if !beforeIsDigit && !afterIsDigit { return true }
            search = range.upperBound
        }
        return false
    }

    /// True when the process listens on ports other than the one Harbor expects.
    public static func portMismatch(expected: Int, observed: Set<Int>) -> Bool {
        !observed.isEmpty && !observed.contains(expected)
    }

    /// Ports an lsof snapshot attributes to `rootPID` or its descendants.
    public static func observedListeningPorts(rootPID: pid_t,
                                       listeners: [Listener],
                                       processTable: [(pid: pid_t, ppid: pid_t)]) -> Set<Int> {
        let tree = Set([rootPID] + Array(ProcessKiller.descendants(of: rootPID, in: processTable)))
        return Set(listeners.filter { tree.contains($0.pid) }.map(\.port))
    }

    /// After `grace`, returns a mismatch when the process tree listens elsewhere.
    public static func portVerification(status: ProcessStatus,
                               definitionPort: Int?,
                               listeners: [Listener],
                               processTable: [(pid: pid_t, ppid: pid_t)],
                               now: Date = Date(),
                               grace: TimeInterval = 5) -> PortVerification? {
        guard status.state == .running else { return nil }
        guard let startedAt = status.startedAt, now.timeIntervalSince(startedAt) > grace else { return nil }
        let expected = definitionPort
        guard let expected, let pid = status.pid else { return nil }
        let observed = observedListeningPorts(rootPID: pid, listeners: listeners, processTable: processTable)
        guard portMismatch(expected: expected, observed: observed) else { return nil }
        return PortVerification(expected: expected, observed: observed)
    }
}
