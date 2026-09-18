import Foundation
import Combine
import AppKit
import HarborCore

/// Root application state: wires the port observer, project registry and
/// process supervisor together and exposes everything the UI needs.
@MainActor
final class AppState: ObservableObject {
    let portObserver: PortObserver
    let registry: ProjectRegistry
    let supervisor: ProcessSupervisor
    let portPoolStore: PortPoolStore
    /// Shared orchestration (PID resolution, port planning) — same logic the TUI uses.
    let coordinator: HarborCoordinator

    /// A single process the user asked to start while its port is held by a
    /// foreign process or another project's managed process.
    @Published var pendingConflict: PendingConflict?
    /// "Start all" for a project where at least one needed port is already held.
    @Published var pendingStartAllConflicts: PendingStartAllConflicts?
    /// A kill-by-port the user still has to confirm (PID not managed by Harbor).
    @Published var pendingKill: PendingKill?
    @Published var lastKillError: String?
    @Published var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    @Published var launchAtLoginError: String?
    /// Whether the main window is open. The menubar popover only offers its
    /// port filter while the full window (with the ports table) is available.
    @Published var isMainWindowOpen = false

    struct PendingConflict: Identifiable {
        let key: ProcessKey
        let processName: String
        let port: Int
        let pid: pid_t
        /// Human-readable label of whoever holds the port right now.
        let owner: String
        /// nil = foreign (unmanaged) holder; otherwise the Harbor project and
        /// process currently holding the port.
        let holder: PortPlanner.ManagedHolder?
        var id: String { "\(key.projectID)::\(key.processName)::\(port)" }

        init(key: ProcessKey, from conflict: PortPlanner.RuntimeConflict) {
            self.key = key
            self.processName = key.processName
            self.port = conflict.port
            self.pid = conflict.listener.pid
            self.owner = conflict.holderLabel
            self.holder = conflict.managedHolder
        }
    }

    struct PendingStartAllConflicts: Identifiable {
        let projectID: String
        let projectName: String
        let items: [PortPlanner.RuntimeConflict]
        var id: String { projectID }
    }

    struct PendingKill: Identifiable {
        let listener: Listener
        var id: String { listener.id }
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        HarborStoreLocation.migrateLegacyStoresIfNeeded()
        portObserver = PortObserver()
        registry = ProjectRegistry()
        supervisor = ProcessSupervisor()
        portPoolStore = PortPoolStore()
        coordinator = HarborCoordinator(registry: registry, observer: portObserver,
                                        supervisor: supervisor, portPoolStore: portPoolStore)
        supervisor.onAutoRestartGiveUp = { [weak self] key, message in
            NotificationService.notify(title: "Harbor: process keeps crashing", body: message)
            _ = key
        }
        portObserver.start()
        Task { await portObserver.refresh() }

        // Forward child object changes so every @EnvironmentObject consumer updates.
        portObserver.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        registry.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        supervisor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        portPoolStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Derived state

    var managedRunningCount: Int { supervisor.runningCount() }
    var managedPIDs: Set<pid_t> { supervisor.managedPIDs() }

    /// Every project's claimed port currently held by a foreign process or by
    /// another project's managed process.
    var conflicts: [PortPlanner.RuntimeConflict] {
        PortPlanner.runtimeConflicts(projects: registry.projects,
                                     listeners: portObserver.listeners,
                                     managedHolder: { pid in self.managedHolder(forPID: pid) })
    }

    /// Ports claimed by two or more projects — a conflict waiting to happen
    /// the first time both run at the same time.
    var staticOverlaps: [PortPlanner.StaticOverlap] {
        PortPlanner.staticOverlaps(projects: registry.projects)
    }

    var hasVisibleConflict: Bool { !conflicts.isEmpty }

    /// Which managed project/process a PID belongs to, if any (ancestor walk
    /// lives in HarborCoordinator, shared with the TUI).
    func managedHolder(forPID pid: pid_t) -> PortPlanner.ManagedHolder? {
        coordinator.managedHolder(forPID: pid)
    }

    /// True for PIDs Harbor manages directly or through a descendant process.
    func isManagedOrDescendant(_ pid: pid_t) -> Bool {
        coordinator.isManagedOrDescendant(pid)
    }

    /// Batch-resolve managed holders for a listener list (one process-table walk).
    func managedHolders(for listeners: [Listener]) -> [pid_t: PortPlanner.ManagedHolder] {
        coordinator.managedHolders(for: listeners)
    }

    /// Port verifications for every process in a project (one process-table walk).
    func portVerifications(for project: Project) -> [String: PortVerification] {
        let processTable = ProcessKiller.processTable()
        let listeners = portObserver.listeners
        var result: [String: PortVerification] = [:]
        for definition in project.processes {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            let status = supervisor.status(for: key)
            if let verification = PortPlanner.portVerification(
                status: status,
                definitionPort: definition.port,
                listeners: listeners,
                processTable: processTable
            ) {
                result[definition.name] = verification
            }
        }
        return result
    }

    // MARK: - Process actions

    func start(project: Project, definition: ProcessDefinition, force: Bool = false) {
        let key = ProcessKey(projectID: project.id, processName: definition.name)
        if !force, let port = definition.port {
            let blockers = PortPlanner.conflicts(forProject: project, listeners: portObserver.listeners,
                                                 managedHolder: { pid in self.managedHolder(forPID: pid) })
            if let conflict = blockers.first(where: { $0.port == port }) {
                pendingConflict = PendingConflict(key: key, from: conflict)
                return
            }
        }
        NotificationService.requestAuthorizationIfNeeded()
        supervisor.start(key: key, definition: definition, projectRoot: project.root, userInitiated: true)
    }

    func confirmPendingConflict() {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        guard let project = registry.projects.first(where: { $0.id == conflict.key.projectID }),
              let definition = project.processes.first(where: { $0.name == conflict.key.processName }) else { return }
        NotificationService.notify(title: "Harbor: started despite port conflict",
                                   body: "\"\(definition.name)\" started even though port \(conflict.port) is in use by \(conflict.owner) (PID \(conflict.pid)).")
        start(project: project, definition: definition, force: true)
    }

    func cancelPendingConflict() {
        pendingConflict = nil
    }

    /// "Free the port, then start": stop the managed holder or kill the
    /// foreign process tree, then start the requested process.
    func confirmPendingConflictFreeingPort() {
        guard let pending = pendingConflict else { return }
        pendingConflict = nil
        guard let project = registry.projects.first(where: { $0.id == pending.key.projectID }),
              let definition = project.processes.first(where: { $0.name == pending.key.processName }) else { return }
        NotificationService.requestAuthorizationIfNeeded()
        Task {
            guard await freePortHolder(managedHolder: pending.holder, pid: pending.pid) else { return }
            await portObserver.refresh()
            start(project: project, definition: definition, force: true)
            NotificationService.notify(title: "Harbor: port \(pending.port) freed",
                                       body: "Port \(pending.port) was freed and \"\(definition.name)\" started.")
        }
    }

    /// Stops a managed holder, or kills a foreign process tree. Returns false
    /// when a foreign holder could not be terminated.
    private func freePortHolder(managedHolder holder: PortPlanner.ManagedHolder?, pid: pid_t) async -> Bool {
        if let holder {
            await supervisor.stop(key: ProcessKey(projectID: holder.projectID, processName: holder.processName))
        } else {
            let result = await ProcessKiller.terminateTree(rootPID: pid, grace: 2.0)
            if case .failure(let error) = result {
                lastKillError = error.message
                return false
            }
        }
        return true
    }

    /// "Start all" — first checks every process; if any declared port is held by a
    /// foreign PID, nothing starts until the user confirms.
    func startProjectWithConfirmation(_ project: Project) {
        let blockers = PortPlanner.conflicts(forProject: project, listeners: portObserver.listeners,
                                             managedHolder: { pid in self.managedHolder(forPID: pid) })
        var found: [PortPlanner.RuntimeConflict] = []
        for definition in project.processes {
            guard let port = definition.port else { continue }
            let state = supervisor.status(for: ProcessKey(projectID: project.id, processName: definition.name)).state
            guard !state.isRunningLike, state != .stopping else { continue }
            if let conflict = blockers.first(where: { $0.port == port }) {
                found.append(conflict)
            }
        }
        if found.isEmpty {
            startProject(project)
        } else {
            pendingStartAllConflicts = PendingStartAllConflicts(projectID: project.id, projectName: project.name, items: found)
        }
    }

    func confirmPendingStartAllConflicts() {
        guard let pending = pendingStartAllConflicts else { return }
        pendingStartAllConflicts = nil
        guard let project = registry.projects.first(where: { $0.id == pending.projectID }) else { return }
        startProject(project)
    }

    func cancelPendingStartAllConflicts() {
        pendingStartAllConflicts = nil
    }

    /// "Free the ports, then start all": stop/kill every holder, refresh the
    /// port snapshot, then start the whole project.
    func confirmPendingStartAllConflictsFreeingPorts() {
        guard let pending = pendingStartAllConflicts else { return }
        pendingStartAllConflicts = nil
        guard let project = registry.projects.first(where: { $0.id == pending.projectID }) else { return }
        NotificationService.requestAuthorizationIfNeeded()
        Task {
            for conflict in pending.items {
                _ = await freePortHolder(managedHolder: conflict.managedHolder,
                                         pid: conflict.listener.pid)
            }
            await portObserver.refresh()
            startProject(project, force: true)
        }
    }

    /// Starts every stopped/failed process in the project (sequential is fine).
    /// With `force`, blocked processes start anyway instead of being skipped.
    func startProject(_ project: Project, force: Bool = false) {
        NotificationService.requestAuthorizationIfNeeded()
        let blockers = PortPlanner.conflicts(forProject: project, listeners: portObserver.listeners,
                                             managedHolder: { pid in self.managedHolder(forPID: pid) })
        for definition in project.processes {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            let state = supervisor.status(for: key).state
            guard !state.isRunningLike, state != .stopping else { continue }
            if let port = definition.port, !force,
               let conflict = blockers.first(where: { $0.port == port }) {
                supervisor.logBuffer(for: key).appendLine(
                    "— Harbor: not starting, port \(port) is held by \(conflict.holderLabel) (PID \(conflict.listener.pid)) —")
                continue
            }
            supervisor.start(key: key, definition: definition, projectRoot: project.root, userInitiated: true)
        }
    }

    func stop(project: Project, definition: ProcessDefinition) {
        Task { await supervisor.stop(key: ProcessKey(projectID: project.id, processName: definition.name)) }
    }

    func restart(project: Project, definition: ProcessDefinition) {
        Task {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            await supervisor.stop(key: key)
            if let fresh = registry.projects.first(where: { $0.id == project.id }) {
                start(project: fresh, definition: definition)
            }
        }
    }

    func stopProject(_ project: Project) {
        for definition in project.processes {
            stop(project: project, definition: definition)
        }
    }

    func openProjectInBrowser(_ project: Project) {
        guard let url = browserURL(for: project, status: { supervisor.status(for: $0) }) else { return }
        NSWorkspace.shared.open(url)
    }

    func projectBrowserURL(_ project: Project) -> URL? {
        browserURL(for: project, status: { supervisor.status(for: $0) })
    }

    // MARK: - Kill by port

    func requestKill(listener: Listener) {
        if let holder = managedHolder(forPID: listener.pid) {
            // Ours — possibly a descendant of the tracked PID (e.g. the
            // python under `zsh -lc …`). Route through the supervisor so
            // state stays in sync and the whole tree stops cleanly.
            Task {
                await supervisor.stop(key: ProcessKey(projectID: holder.projectID,
                                                      processName: holder.processName))
            }
        } else {
            pendingKill = PendingKill(listener: listener)
        }
    }

    func confirmPendingKill() {
        guard let pending = pendingKill else { return }
        pendingKill = nil
        kill(listener: pending.listener)
    }

    func cancelPendingKill() {
        pendingKill = nil
    }

    private func kill(listener: Listener) {
        Task {
            if let key = supervisor.key(forPID: listener.pid) {
                await supervisor.stop(key: key)
            } else {
                let pids = portObserver.pidsListening(on: listener.port)
                for pid in pids {
                    let result = await ProcessKiller.terminateTree(rootPID: pid, grace: 2.0)
                    if case .failure(let error) = result {
                        lastKillError = error.message
                    }
                }
            }
            await portObserver.refresh()
        }
    }

    func refreshPortsNow() {
        Task { await portObserver.refresh() }
    }

    // MARK: - Projects

    func reloadConfigsIfStale() {
        registry.reloadAll()
    }

    // MARK: - Settings

    func toggleLaunchAtLogin(_ enabled: Bool) {
        switch LaunchAtLogin.setEnabled(enabled) {
        case .success:
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = nil
        case .failure(let error):
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = error.message
        }
    }

    // MARK: - Quit

    /// Kill every managed tree synchronously; called from applicationWillTerminate.
    func stopEverythingForQuit() {
        supervisor.emergencyStopAll()
    }
}
