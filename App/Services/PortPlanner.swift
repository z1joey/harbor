import Foundation

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
enum PortPlanner {
    /// A Harbor-managed process currently holding a port.
    struct ManagedHolder: Hashable {
        let projectID: String
        let projectName: String
        let processName: String
    }

    /// One port a project needs, with its config-side source.
    struct ClaimedPort: Hashable {
        let port: Int
        /// `[[process]]` name when the port comes from a process entry; nil for a bare claim.
        let processName: String?
        let note: String?
    }

    /// A port a project needs while somebody else is listening on it.
    struct RuntimeConflict: Identifiable, Hashable {
        let projectID: String
        let projectName: String
        let port: Int
        /// Process the port is configured on, if it came from `[[process]].port`.
        let processName: String?
        let listener: Listener
        /// nil = holder is a foreign (unmanaged) process.
        let managedHolder: ManagedHolder?

        var id: String { "\(projectID)::\(port)::\(listener.pid)" }

        var holderLabel: String {
            if let managedHolder {
                return "\(managedHolder.projectName) · \(managedHolder.processName)"
            }
            return listener.processName
        }
    }

    /// A port claimed by two or more projects — latent until both run at once.
    struct StaticOverlap: Identifiable, Hashable {
        let port: Int
        /// Claiming project names, sorted.
        let projects: [String]

        var id: Int { port }
    }

    // MARK: - Claims

    /// Every port claim across all projects (process ports + `[[port_claim]]`).
    static func claims(projects: [Project]) -> [(projectName: String, claim: ClaimedPort)] {
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
    /// permanently. Claims still drive static overlaps and the Ports Overview.
    static func conflicts(forProject project: Project,
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
    static func runtimeConflicts(projects: [Project],
                                 listeners: [Listener],
                                 managedHolder: (pid_t) -> ManagedHolder?) -> [RuntimeConflict] {
        projects
            .flatMap { conflicts(forProject: $0, listeners: listeners, managedHolder: managedHolder) }
            .sorted { $0.port != $1.port ? $0.port < $1.port : $0.projectName < $1.projectName }
    }

    // MARK: - Static overlaps

    /// Ports claimed by two or more projects, sorted by port.
    static func staticOverlaps(projects: [Project]) -> [StaticOverlap] {
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
    static func suggestFreePorts(count: Int, from base: Int, taken: Set<Int>) -> [Int] {
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
}
