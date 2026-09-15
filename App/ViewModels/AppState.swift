import Foundation
import Combine

/// Root application state: wires the port observer, project registry and
/// process supervisor together and exposes everything the UI needs.
@MainActor
final class AppState: ObservableObject {
    let portObserver: PortObserver
    let registry: ProjectRegistry
    let supervisor: ProcessSupervisor

    /// A single process the user asked to start while its port is held by a foreign PID.
    @Published var pendingConflict: PendingConflict?
    /// "Start all" for a project where at least one declared port is held by a foreign PID.
    @Published var pendingStartAllConflicts: PendingStartAllConflicts?
    /// A kill-by-port the user still has to confirm (PID not managed by Harbor).
    @Published var pendingKill: PendingKill?
    @Published var lastKillError: String?
    @Published var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled
    @Published var launchAtLoginError: String?

    struct PendingConflict: Identifiable {
        let key: ProcessKey
        let processName: String
        let port: Int
        let pid: pid_t
        let owner: String
        var id: String { "\(key.projectID)::\(key.processName)::\(port)" }
    }

    struct PendingStartAllConflicts: Identifiable {
        let projectID: String
        let projectName: String
        let items: [Conflict]
        var id: String { projectID }
    }

    struct PendingKill: Identifiable {
        let listener: Listener
        var id: String { listener.id }
    }

    struct Conflict: Identifiable {
        let projectName: String
        let processName: String
        let port: Int
        let pid: pid_t
        let owner: String
        var id: String { "\(projectName)/\(processName)/\(port)" }
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        portObserver = PortObserver()
        registry = ProjectRegistry()
        supervisor = ProcessSupervisor()
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
    }

    // MARK: - Derived state

    var managedRunningCount: Int { supervisor.runningCount() }
    var managedPIDs: Set<pid_t> { supervisor.managedPIDs() }

    var conflicts: [Conflict] {
        let managed = supervisor.managedPIDs()
        var result: [Conflict] = []
        for project in registry.projects {
            for definition in project.processes {
                guard let port = definition.port else { continue }
                if let listener = portObserver.foreignListener(on: port, managedPIDs: managed) {
                    result.append(Conflict(projectName: project.name, processName: definition.name,
                                           port: port, pid: listener.pid, owner: listener.processName))
                }
            }
        }
        return result
    }

    var hasVisibleConflict: Bool { !conflicts.isEmpty }

    // MARK: - Process actions

    func start(project: Project, definition: ProcessDefinition, force: Bool = false) {
        let key = ProcessKey(projectID: project.id, processName: definition.name)
        if !force, let port = definition.port,
           let foreign = portObserver.foreignListener(on: port, managedPIDs: supervisor.managedPIDs()) {
            pendingConflict = PendingConflict(key: key, processName: definition.name,
                                              port: port, pid: foreign.pid, owner: foreign.processName)
            return
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

    /// "Start all" — first checks every process; if any declared port is held by a
    /// foreign PID, nothing starts until the user confirms.
    func startProjectWithConfirmation(_ project: Project) {
        let managed = supervisor.managedPIDs()
        var found: [Conflict] = []
        for definition in project.processes {
            guard let port = definition.port else { continue }
            let state = supervisor.status(for: ProcessKey(projectID: project.id, processName: definition.name)).state
            guard !state.isRunningLike, state != .stopping else { continue }
            if let foreign = portObserver.foreignListener(on: port, managedPIDs: managed) {
                found.append(Conflict(projectName: project.name, processName: definition.name,
                                      port: port, pid: foreign.pid, owner: foreign.processName))
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

    /// Starts every stopped/failed process in the project (sequential is fine).
    func startProject(_ project: Project) {
        NotificationService.requestAuthorizationIfNeeded()
        let managed = supervisor.managedPIDs()
        for definition in project.processes {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            let state = supervisor.status(for: key).state
            guard !state.isRunningLike, state != .stopping else { continue }
            if let port = definition.port, let foreign = portObserver.foreignListener(on: port, managedPIDs: managed) {
                supervisor.logBuffer(for: key).appendLine("— Harbor: not starting, port \(port) is in use by \(foreign.processName) (PID \(foreign.pid)) —")
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

    // MARK: - Kill by port

    func requestKill(listener: Listener) {
        if supervisor.managedPIDs().contains(listener.pid) {
            // Our own process — route through the supervisor so state stays in sync.
            kill(listener: listener)
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

    enum AddOutcome {
        case added(Project)
        case missingConfig
    }

    func addProject(root: URL, createTemplateIfMissing: Bool) -> Result<AddOutcome, HarborError> {
        switch registry.add(root: root, createTemplateIfMissing: createTemplateIfMissing) {
        case .success(let project):
            return .success(.added(project))
        case .failure(let error as ProjectRegistry.AddError) where error == .missingConfig:
            return .success(.missingConfig)
        case .failure(let error):
            return .failure(HarborError(error.localizedDescription))
        }
    }

    func configExists(at root: URL) -> Bool {
        HarborConfigParser.locateConfig(in: root) != nil
    }

    func createTemplateConfig(at root: URL) -> Result<URL, HarborError> {
        switch registry.createTemplate(root: root) {
        case .success(let url): return .success(url)
        case .failure(let error): return .failure(HarborError(error.localizedDescription))
        }
    }

    func removeProject(_ project: Project) {
        registry.remove(projectID: project.id)
    }

    func writeConfig(text: String, at root: URL) -> Result<URL, HarborError> {
        let url = root.appendingPathComponent("harbor.toml")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            registry.reload(projectID: root.path)
            return .success(url)
        } catch {
            return .failure(HarborError("Could not write harbor.toml: \(error.localizedDescription)"))
        }
    }

    func importDrafts(at root: URL) -> [ConfigImporter.Draft] {
        ConfigImporter.drafts(in: root)
    }

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
