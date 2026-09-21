import Foundation
import Darwin
import Combine
import HarborCore
import HarborTUIKit

/// TUI application: owns the core services (same assembly as the GUI's
/// AppState), routes keys between the three panels and the inline
/// confirm/command bars, and repaints on a fixed cadence (the diff encoder
/// makes empty frames nearly free).
@MainActor
final class TuiApp {
    /// Strong reference for the process lifetime — the run loop is callback
    /// driven, so nothing else keeps the app (and its sources) alive.
    private(set) static var current: TuiApp?

    let terminal: TerminalController
    let registry: ProjectRegistry
    let observer: PortObserver
    let supervisor: ProcessSupervisor
    let portPoolStore: PortPoolStore
    let coordinator: HarborCoordinator

    // MARK: - UI state

    enum Panel { case projects, logs, ports }
    private var panel: Panel = .projects

    private var projectsSelected: Int? = 0
    private var projectsTargets: [ProjectsPanel.Target] = []

    private var logs = LogsPanel()

    private var ports = PortsPanel()
    private var listeningRowCount = 0
    private var overviewRowCount = 0

    private var currentConflicts: [PortPlanner.RuntimeConflict] = []
    private var currentHolders: [pid_t: PortPlanner.ManagedHolder] = [:]
    private var conflictsByProcess: [String: PortPlanner.RuntimeConflict] = [:]
    private var currentOverlaps: [PortPlanner.StaticOverlap] = []
    private var verifications: [ProcessKey: PortVerification] = [:]

    /// Set whenever a service publishes a change (listener poll ~2s, process
    /// statuses, registry reloads). The derived model above is rebuilt on
    /// this cadence inside draw(), not on every repaint tick — the sysctl
    /// walks don't need to run 5×/s just because the screen does.
    private var modelDirty = true
    private var cancellables = Set<AnyCancellable>()

    enum Overlay {
        case confirm(Confirmation)
        case command(CommandBar)
        case filter(CommandBar)
    }
    private var overlay: Overlay?

    struct Confirmation {
        enum Action: Equatable {
            case quit
            case killListener(Listener)
            case startProcess(Project, ProcessDefinition, ProcessKey, PortPlanner.RuntimeConflict)
            case startAllConflicts(Project, [PortPlanner.RuntimeConflict])
            /// Held `[[port_claim]]`s bound to the process/project being
            /// started — start-anyway or cancel only (the holder is normally
            /// infrastructure like com.docker.backend; freeing it is unsafe).
            case startProcessClaims(Project, ProcessDefinition, ProcessKey, [PortPlanner.RuntimeConflict])
            case startAllClaims(Project, [PortPlanner.RuntimeConflict])
        }

        let message: String
        let options: [ConfirmBar.Option]
        let action: Action
    }

    private var flash: (text: String, style: Style, until: Date)?

    private var redrawScheduled = false
    private var repaintTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    init() throws {
        HarborStoreLocation.migrateLegacyStoresIfNeeded()
        HarborStoreLocation.migrateLegacyConfigsIfNeeded()
        terminal = try TerminalController()
        registry = ProjectRegistry()
        observer = PortObserver()
        supervisor = ProcessSupervisor()
        portPoolStore = PortPoolStore()
        coordinator = HarborCoordinator(registry: registry, observer: observer,
                                        supervisor: supervisor, portPoolStore: portPoolStore)

        supervisor.onAutoRestartGiveUp = { [weak self] _, message in
            self?.showFlash(message, style: Style(fg: .red))
        }
        registry.objectWillChange.sink { [weak self] _ in self?.modelDirty = true }.store(in: &cancellables)
        observer.objectWillChange.sink { [weak self] _ in self?.modelDirty = true }.store(in: &cancellables)
        supervisor.objectWillChange.sink { [weak self] _ in self?.modelDirty = true }.store(in: &cancellables)
        observer.start(interval: 2.0)
        Task { await observer.refresh() }

        terminal.onKey = { [weak self] key in
            Task { @MainActor [weak self] in self?.handle(key) }
        }
        terminal.onResize = { [weak self] in
            Task { @MainActor [weak self] in self?.draw() }
        }
        terminal.onTerminate = { [weak self] in
            Task { @MainActor [weak self] in self?.quitNow() }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.draw() }
        }
        timer.resume()
        repaintTimer = timer
        Self.current = self // all stored properties set; keep alive for process lifetime
    }

    // MARK: - Key routing

    private func handle(_ key: Key) {
        switch overlay {
        case .confirm(let confirmation):
            handleConfirm(key, confirmation)
        case .command(var bar):
            let editing = handleInput(key, bar: &bar, live: nil, onEnter: { [weak self] input in
                self?.executeCommand(input)
            }, onCancel: { [weak self] in
                self?.overlay = nil
                self?.draw()
            })
            if editing {
                overlay = .command(bar) // write back edits before repainting
                draw()
            }
        case .filter(var bar):
            let editing = handleInput(key, bar: &bar, live: { [weak self] text in
                self?.ports.filter = text
            }, onEnter: { [weak self] _ in
                self?.overlay = nil
                self?.draw()
            }, onCancel: { [weak self] in
                self?.ports.filter = ""
                self?.overlay = nil
                self?.draw()
            })
            if editing {
                overlay = .filter(bar) // write back edits before repainting
                draw()
            }
        case .none:
            handleNormal(key)
        }
    }

    private func handleConfirm(_ key: Key, _ confirmation: Confirmation) {
        let choice: Character?
        switch key {
        case .char(let ch): choice = ch
        case .escape, .ctrl("c"): choice = nil
        default: return // ignore navigation keys while confirming
        }
        // Only keys the prompt offers may act; anything else is ignored so a
        // stray keypress can never confirm a destructive action.
        if let choice, !confirmation.options.contains(where: { $0.key == choice }) {
            return
        }
        if choice == nil || choice == "c" || choice == "n" {
            // Esc / Ctrl+C cancel any prompt — except the quit prompt, where
            // they re-confirm the quit that was explicitly requested.
            if confirmation.action == .quit, choice == nil {
                overlay = nil
                quitNow()
            } else {
                overlay = nil
                draw()
            }
            return
        }
        overlay = nil
        switch confirmation.action {
        case .quit:
            if choice == "q" { quitNow() } else { draw() }
        case .killListener(let listener):
            // The options guard above leaves only "y" — kill is never implied.
            killForeign(listener)
        case .startProcess(let project, let definition, let key, let conflict):
            switch choice {
            case "f":
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.freeConflict(conflict)
                    let claimBlockers = self.claimBlockers(project: project, startingProcesses: [definition.name])
                    if !claimBlockers.isEmpty {
                        self.promptClaimConflicts(project: project, definition: definition, key: key, blockers: claimBlockers)
                    } else {
                        self.startManaged(key, definition, project, successFlash: "starting \(definition.name)")
                    }
                    self.draw()
                }
            case "s":
                let claimBlockers = self.claimBlockers(project: project, startingProcesses: [definition.name])
                if !claimBlockers.isEmpty {
                    self.promptClaimConflicts(project: project, definition: definition, key: key, blockers: claimBlockers)
                } else {
                    self.startManaged(key, definition, project,
                                      successFlash: "started \(definition.name) despite conflict",
                                      successStyle: Style(fg: .yellow))
                }
            default: break
            }
        case .startAllConflicts(let project, let conflicts):
            switch choice {
            case "f":
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for conflict in conflicts {
                        await self.freeConflict(conflict)
                    }
                    let pendingNames = self.notRunningProcessNames(project: project)
                    let claimBlockers = self.claimBlockers(project: project, startingProcesses: pendingNames)
                    if !claimBlockers.isEmpty {
                        self.promptProjectClaimConflicts(project: project, blockers: claimBlockers)
                    } else {
                        self.startAll(project, force: true)
                    }
                    self.draw()
                }
            case "a":
                let pendingNames = notRunningProcessNames(project: project)
                let claimBlockers = claimBlockers(project: project, startingProcesses: pendingNames)
                if !claimBlockers.isEmpty {
                    promptProjectClaimConflicts(project: project, blockers: claimBlockers)
                } else {
                    startAll(project, force: true)
                }
            default: break
            }
        case .startProcessClaims(let project, let definition, let key, _):
            if choice == "s" {
                startManaged(key, definition, project,
                             successFlash: "started \(definition.name) despite conflict",
                             successStyle: Style(fg: .yellow))
            }
        case .startAllClaims(let project, _):
            if choice == "a" {
                startAll(project, force: true)
                showFlash("starting \(project.name) despite conflicts", style: Style(fg: .yellow))
            }
        }
        draw()
    }

    /// Shared input handling for command and filter bars. Returns true while
    /// still editing (the bar was mutated — the caller writes it back into
    /// the overlay and repaints); false when the prompt finished or the key
    /// was inert, with the callbacks having handled their own repaint.
    @discardableResult
    private func handleInput(_ key: Key, bar: inout CommandBar, live: ((String) -> Void)?,
                             onEnter: @escaping (String) -> Void, onCancel: @escaping () -> Void) -> Bool {
        switch key {
        case .char(let ch):
            bar.insert(ch)
        case .backspace:
            bar.backspace()
        case .left:
            bar.moveLeft()
            return true
        case .right:
            bar.moveRight()
            return true
        case .enter:
            onEnter(bar.input)
            return false
        case .escape, .ctrl("c"):
            onCancel()
            return false
        default:
            return false
        }
        live?(bar.input)
        return true
    }

    private func handleNormal(_ key: Key) {
        switch key {
        case .char("1"): panel = .projects
        case .char("2"): panel = .logs
        case .char("3"): panel = .ports
        case .tab:
            panel = panel == .projects ? .logs : (panel == .logs ? .ports : .projects)
        case .up, .char("k"): move(-1)
        case .down, .char("j"): move(1)
        case .pageUp: movePage(-1)
        case .pageDown: movePage(1)
        case .home: jump(to: 0)
        case .end: jump(to: Int.max)
        case .enter, .char("l"): focusLogs()
        case .char("s"): startSelection()
        case .char("S"): startAllSelection()
        case .char("x"): stopSelection()
        case .char("X"): stopAllSelection()
        case .char("r"): restartSelection()
        case .char("f"):
            if panel == .logs {
                if logs.view.follow {
                    // A page, not zero lines — the first press must visibly scroll.
                    logs.view.scrollUp(max(1, terminal.screen.height - 4))
                } else {
                    logs.view.toBottom()
                }
            }
        case .char("c"):
            if panel == .logs, let key = logs.focused {
                supervisor.logBuffer(for: key).clear()
            }
        case .char("m"):
            if panel == .ports {
                ports.mineOnly.toggle()
            }
        case .char("v"):
            if panel == .ports {
                ports.subview = ports.subview == .listening ? .overview : .listening
            }
        case .char("/"):
            if panel == .ports {
                var bar = CommandBar(prompt: "/")
                bar.input = ports.filter
                bar.cursorIndex = bar.input.count
                overlay = .filter(bar)
            }
        case .escape:
            if panel == .ports, !ports.filter.isEmpty {
                ports.filter = ""
            }
        case .char(":"):
            overlay = .command(CommandBar())
        case .char("q"), .ctrl("c"):
            requestQuit()
        default:
            return
        }
        draw()
    }

    // MARK: - Selection movement

    private var selectedRowCount: Int {
        switch panel {
        case .projects: return projectsTargets.count
        case .logs: return 0
        case .ports: return ports.subview == .listening ? listeningRowCount : overviewRowCount
        }
    }

    private func move(_ delta: Int) {
        let count = selectedRowCount
        guard count > 0 else { return }
        switch panel {
        case .projects:
            let current = projectsSelected ?? 0
            projectsSelected = min(max(0, current + delta), count - 1)
        case .logs:
            if delta < 0 { logs.view.scrollUp(-delta) } else { logs.view.scrollDown(delta) }
        case .ports:
            if ports.subview == .listening {
                let current = ports.listeningSelection ?? 0
                ports.listeningSelection = min(max(0, current + delta), count - 1)
            } else {
                let current = ports.overviewSelection ?? 0
                ports.overviewSelection = min(max(0, current + delta), count - 1)
            }
        }
    }

    private func movePage(_ direction: Int) {
        let pageSize = max(1, (terminal.screen.height - 4))
        move(direction * pageSize)
    }

    private func jump(to index: Int) {
        guard selectedRowCount > 0 else { return }
        switch panel {
        case .projects: projectsSelected = min(index, projectsTargets.count - 1)
        case .logs: break
        case .ports:
            if ports.subview == .listening {
                ports.listeningSelection = min(index, listeningRowCount - 1)
            } else {
                ports.overviewSelection = min(index, overviewRowCount - 1)
            }
        }
    }

    // MARK: - Process actions

    private var selectedProject: Project? {
        guard panel == .projects else { return nil }
        switch projectsTargets[safe: projectsSelected ?? -1] {
        case .project(let project): return project
        case .process(let project, _, _): return project
        case .none: return nil
        }
    }

    private func focusLogs() {
        guard panel == .projects,
              case .process(_, _, let key) = projectsTargets[safe: projectsSelected ?? -1] else { return }
        logs.focused = key
        logs.view.toBottom()
        panel = .logs
    }

    private func startSelection() {
        guard panel == .projects else { return }
        switch projectsTargets[safe: projectsSelected ?? -1] {
        case .project(let project):
            startProjectFlow(project)
        case .process(let project, let definition, let key):
            startProcessFlow(project, definition, key)
        case .none:
            return
        }
    }

    private func startProcessFlow(_ project: Project, _ definition: ProcessDefinition, _ key: ProcessKey) {
        let status = supervisor.status(for: key)
        if status.state.isRunningLike {
            showFlash("\(definition.name) is already running", style: Style(fg: .yellow))
            return
        }
        if let conflict = currentConflicts.first(where: { $0.projectID == project.id && $0.processName == definition.name }) {
            overlay = .confirm(Confirmation(
                message: ":\(conflict.port) held by \(conflict.holderLabel) — start \(definition.name)?",
                options: [
                    ConfirmBar.Option(key: "f", label: "free port & start"),
                    ConfirmBar.Option(key: "s", label: "start anyway"),
                    ConfirmBar.Option(key: "c", label: "cancel"),
                ],
                action: .startProcess(project, definition, key, conflict)))
            return
        }
        let claimBlockers = claimBlockers(project: project, startingProcesses: [definition.name])
        if !claimBlockers.isEmpty {
            promptClaimConflicts(project: project, definition: definition, key: key, blockers: claimBlockers)
            return
        }
        startManaged(key, definition, project, successFlash: "starting \(definition.name)")
    }

    private func startAllSelection() {
        guard let project = selectedProject else { return }
        startProjectFlow(project)
    }

    private func startProjectFlow(_ project: Project) {
        let pending = project.processes.filter { definition in
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            return !(supervisor.status(for: key).state.isRunningLike)
        }
        guard !pending.isEmpty else {
            showFlash("all processes already running", style: Style(fg: .yellow))
            return
        }
        let pendingNames = Set(pending.map(\.name))
        let blocked = currentConflicts.filter { $0.projectID == project.id && pendingNames.contains($0.processName ?? "") }
        if blocked.isEmpty {
            let claimBlockers = claimBlockers(project: project, startingProcesses: pendingNames)
            if !claimBlockers.isEmpty {
                promptProjectClaimConflicts(project: project, blockers: claimBlockers)
                return
            }
            startAll(project, force: false)
        } else {
            let heldPorts = blocked.map { ":\($0.port)" }.joined(separator: ", ")
            overlay = .confirm(Confirmation(
                message: "\(heldPorts) held — start all for \(project.name)?",
                options: [
                    ConfirmBar.Option(key: "f", label: "free ports & start all"),
                    ConfirmBar.Option(key: "a", label: "start all anyway"),
                    ConfirmBar.Option(key: "c", label: "cancel"),
                ],
                action: .startAllConflicts(project, blocked)))
        }
    }

    /// Held `[[port_claim]]`s bound to `startingProcesses`, freshly resolved.
    private func claimBlockers(project: Project, startingProcesses: Set<String>) -> [PortPlanner.RuntimeConflict] {
        PortPlanner.claimConflicts(forProject: project,
                                   startingProcesses: startingProcesses,
                                   listeners: observer.listeners,
                                   managedHolder: { coordinator.managedHolder(forPID: $0) })
    }

    private func notRunningProcessNames(project: Project) -> Set<String> {
        Set(project.processes.compactMap { definition -> String? in
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            let state = supervisor.status(for: key).state
            return (!state.isRunningLike && state != .stopping) ? definition.name : nil
        })
    }

    /// Starts a managed process and surfaces the Result — start failures (bad
    /// cwd, spawn error) used to vanish into the log buffer behind a green
    /// "starting …" flash. Returns whether the start was accepted.
    @discardableResult
    private func startManaged(_ key: ProcessKey, _ definition: ProcessDefinition, _ project: Project,
                              successFlash: String, successStyle: Style = Style(fg: .green)) -> Bool {
        switch supervisor.start(key: key, definition: definition, projectRoot: project.root) {
        case .success:
            showFlash(successFlash, style: successStyle)
            return true
        case .failure(let error):
            showFlash("start failed: \(error.message)", style: Style(fg: .red))
            return false
        }
    }

    private func promptClaimConflicts(project: Project, definition: ProcessDefinition, key: ProcessKey,
                                      blockers: [PortPlanner.RuntimeConflict]) {
        let held = blockers.map { ":\($0.port) held by \($0.holderLabel)" }.joined(separator: ", ")
        overlay = .confirm(Confirmation(
            message: "\(held) — start \(definition.name)?",
            options: [
                ConfirmBar.Option(key: "s", label: "start anyway"),
                ConfirmBar.Option(key: "c", label: "cancel"),
            ],
            action: .startProcessClaims(project, definition, key, blockers)))
    }

    private func promptProjectClaimConflicts(project: Project, blockers: [PortPlanner.RuntimeConflict]) {
        let held = blockers.map { ":\($0.port) held by \($0.holderLabel)" }.joined(separator: ", ")
        overlay = .confirm(Confirmation(
            message: "\(held) — start all for \(project.name)?",
            options: [
                ConfirmBar.Option(key: "a", label: "start all anyway"),
                ConfirmBar.Option(key: "c", label: "cancel"),
            ],
            action: .startAllClaims(project, blockers)))
    }

    /// Starts every not-running process of `project`. Without `force`, blocked
    /// processes are skipped with a log line (same as the GUI).
    private func startAll(_ project: Project, force: Bool) {
        for definition in project.processes {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            guard !supervisor.status(for: key).state.isRunningLike else { continue }
            if !force, let conflict = currentConflicts.first(where: { $0.projectID == project.id && $0.processName == definition.name }) {
                supervisor.logBuffer(for: key).appendLine(
                    "— Harbor: skipped — port \(conflict.port) is held by \(conflict.holderLabel) —")
                continue
            }
            startManaged(key, definition, project, successFlash: "starting \(definition.name)")
        }
    }

    private func stopSelection() {
        switch panel {
        case .projects:
            switch projectsTargets[safe: projectsSelected ?? -1] {
            case .project(let project):
                stopProject(project)
            case .process(_, _, let key):
                Task { @MainActor [weak self] in await self?.supervisor.stop(key: key) }
            case .none:
                return
            }
        case .ports:
            killSelection()
        case .logs:
            break
        }
    }

    private func stopAllSelection() {
        guard let project = selectedProject else { return }
        stopProject(project)
    }

    private func stopProject(_ project: Project) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for definition in project.processes {
                let key = ProcessKey(projectID: project.id, processName: definition.name)
                if self.supervisor.status(for: key).state.isRunningLike {
                    await self.supervisor.stop(key: key)
                }
            }
        }
    }

    private func restartSelection() {
        guard panel == .projects,
              case .process(let project, let definition, let key) = projectsTargets[safe: projectsSelected ?? -1] else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.supervisor.stop(key: key)
            // Refresh the snapshot and the cached gates, so restart goes
            // through the same conflict prompts as a fresh start instead of
            // silently bypassing them (or tripping on the dead process's
            // stale listener).
            await self.observer.refresh()
            self.draw()
            self.startProcessFlow(project, definition, key)
            self.draw()
        }
    }

    private func freeConflict(_ conflict: PortPlanner.RuntimeConflict) async {
        if let holder = conflict.managedHolder {
            await supervisor.stop(key: ProcessKey(projectID: holder.projectID, processName: holder.processName))
            showFlash("stopped \(holder.projectName)/\(holder.processName) to free :\(conflict.port)", style: Style(fg: .yellow))
        } else {
            let result = await ProcessKiller.terminateTree(rootPID: conflict.listener.pid, grace: 2.0)
            switch result {
            case .success:
                showFlash("freed :\(conflict.port) (killed PID \(conflict.listener.pid))", style: Style(fg: .green))
            case .failure(let error):
                showFlash(error.message, style: Style(fg: .red))
            }
        }
        // Give the port a beat to actually be released.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Ports / killing

    private func killSelection() {
        let listener: Listener?
        if ports.subview == .listening {
            listener = visibleListeners[safe: ports.listeningSelection ?? -1]
        } else {
            listener = allocationItems[safe: ports.overviewSelection ?? -1]?.listener
        }
        guard let listener else { return }
        if let holder = currentHolders[listener.pid] {
            showFlash("stopping managed \(holder.projectName)/\(holder.processName)…", style: Style(fg: .yellow))
            Task { @MainActor [weak self] in
                await self?.supervisor.stop(key: ProcessKey(projectID: holder.projectID, processName: holder.processName))
            }
            return
        }
        overlay = .confirm(Confirmation(
            message: "kill PID \(listener.pid) (\(listener.processName))? SIGTERM → ~2s → SIGKILL",
            options: [
                ConfirmBar.Option(key: "y", label: "kill"),
                ConfirmBar.Option(key: "n", label: "cancel"),
            ],
            action: .killListener(listener)))
    }

    private func killForeign(_ listener: Listener) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ProcessKiller.terminateTree(rootPID: listener.pid, grace: 2.0)
            switch result {
            case .success:
                self.showFlash("killed PID \(listener.pid)", style: Style(fg: .green))
            case .failure(let error):
                self.showFlash(error.message, style: Style(fg: .red))
            }
            self.draw()
        }
    }

    // MARK: - Registry commands

    private func executeCommand(_ input: String) {
        overlay = nil
        let parts = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { draw(); return }
        switch parts[0].lowercased() {
        case "refresh":
            registry.reloadAll()
            Task { await observer.refresh() }
            showFlash("refreshed", style: Style(fg: .green))
        case "q", "quit":
            requestQuit()
        default:
            showFlash("unknown command: \(parts[0]) (try refresh/q; registration lives in ~/.harbor via the harbor-pilot skill)",
                      style: Style(fg: .yellow))
        }
        draw()
    }

    // MARK: - Quit

    private func requestQuit() {
        if supervisor.runningCount() > 0 {
            overlay = .confirm(Confirmation(
                message: "stop all managed processes and quit?",
                options: [ConfirmBar.Option(key: "q", label: "stop all & quit"), ConfirmBar.Option(key: "n", label: "stay")],
                action: .quit))
            draw()
        } else {
            quitNow()
        }
    }

    private func quitNow() {
        terminal.shutdown()
        supervisor.emergencyStopAll()
        exit(0)
    }

    // MARK: - Flash messages

    private func showFlash(_ text: String, style: Style) {
        flash = (text, style, Date().addingTimeInterval(4))
    }

    // MARK: - Drawing

    private var visibleListeners: [Listener] = []
    private var allocationItems: [PortsPanel.AllocationItem] = []

    /// Recomputes everything derived from the services (one process-table
    /// walk). Runs when a service publishes a change — not on every repaint
    /// tick, whose output the diff encoder makes cheap but whose inputs are
    /// not.
    private func rebuildModel() {
        let parents = coordinator.processTableParents()
        let listeners = observer.listeners
        currentHolders = [:]
        for listener in listeners {
            if let holder = coordinator.managedHolder(forPID: listener.pid, parents: parents) {
                currentHolders[listener.pid] = holder
            }
        }
        currentConflicts = PortPlanner.runtimeConflicts(projects: registry.projects,
                                                        listeners: listeners,
                                                        managedHolder: { currentHolders[$0] })
        // Keyed by project too — two projects can both have a process named "web".
        conflictsByProcess = [:]
        for conflict in currentConflicts {
            if let name = conflict.processName { conflictsByProcess["\(conflict.projectID)::\(name)"] = conflict }
        }
        currentOverlaps = PortPlanner.staticOverlaps(projects: registry.projects)
        let processTable = parents.map { (pid: $0.key, ppid: $0.value) }
        verifications = [:]
        for project in registry.projects {
            for definition in project.processes {
                let key = ProcessKey(projectID: project.id, processName: definition.name)
                if let verification = PortPlanner.portVerification(status: supervisor.status(for: key),
                                                                   definitionPort: definition.port,
                                                                   listeners: listeners,
                                                                   processTable: processTable) {
                    verifications[key] = verification
                }
            }
        }
    }

    private func draw() {
        if let flash, Date() > flash.until { self.flash = nil }

        var screen = terminal.screen
        screen.clear()
        let width = screen.width
        let height = screen.height
        guard width >= 24, height >= 6 else {
            screen.drawString("terminal too small (need ≥ 24×6)", x: 0, y: 0, style: Style(fg: .red))
            terminal.screen = screen
            terminal.present()
            return
        }

        if modelDirty {
            rebuildModel()
            modelDirty = false
        }

        // Top bar.
        let running = supervisor.runningCount()
        var top = "harbor — \(registry.projects.count) projects · \(running) running"
        if !currentConflicts.isEmpty { top += " · \(currentConflicts.count) port conflicts" }
        if !currentOverlaps.isEmpty { top += " · \(currentOverlaps.count) static overlaps" }
        screen.fillRow(0, style: Style(reverse: true), text: truncatedToWidth(top, width))

        // Panel area.
        let area = Rect(x: 0, y: 1, width: width, height: height - 3)
        switch panel {
        case .projects:
            let (table, targets) = ProjectsPanel.build(projects: registry.projects,
                                                       statuses: supervisor.statuses,
                                                       conflictsByProcess: conflictsByProcess,
                                                       verifications: verifications,
                                                       selected: projectsSelected,
                                                       visibleRows: area.height - 1)
            projectsTargets = targets
            projectsSelected = table.selectedRow
            table.render(into: &screen, rect: area)
        case .logs:
            let lines = logs.focused.map { supervisor.logBuffer(for: $0).snapshot() } ?? []
            logs.refresh(lines: lines)
            logs.render(into: &screen, rect: area, label: logsLabel())
        case .ports:
            drawPorts(into: &screen, area: area, listeners: observer.listeners, holders: currentHolders, overlaps: currentOverlaps)
        }

        // Bottom bars.
        let barY = height - 2
        screen.fillRow(barY, style: .plain)
        switch overlay {
        case .confirm(let confirmation):
            ConfirmBar(message: confirmation.message, options: confirmation.options).render(into: &screen, y: barY)
        case .command(let bar):
            bar.render(into: &screen, y: barY)
        case .filter(let bar):
            bar.render(into: &screen, y: barY)
        case .none:
            if let flash {
                screen.drawString(truncatedToWidth(flash.text, width), x: 0, y: barY, style: flash.style)
            } else {
                screen.drawString(truncatedToWidth(hintText(), width), x: 0, y: barY, style: Style(fg: .brightBlack))
            }
        }
        StatusBar(left: panelName(), right: "harbor-tui \(harborVersion)  [1/2/3] panels  [q] quit").render(into: &screen, y: height - 1)

        terminal.screen = screen
        terminal.present()
    }

    private func drawPorts(into screen: inout Screen, area: Rect, listeners: [Listener],
                           holders: [pid_t: PortPlanner.ManagedHolder],
                           overlaps: [PortPlanner.StaticOverlap]) {
        guard area.height >= 2 else { return }
        let headerRect = Rect(x: area.x, y: area.y, width: area.width, height: 1)
        let tableRect = Rect(x: area.x, y: area.y + 1, width: area.width, height: area.height - 1)
        if ports.subview == .listening {
            visibleListeners = listeners.filter { PortsPanel.matches($0, filter: ports.filter, mineOnly: ports.mineOnly) }
            listeningRowCount = visibleListeners.count
            let header = "listening ports — [v] convention  [m] mine-only: \(ports.mineOnly ? "on" : "off")  [/] filter: \(ports.filter.isEmpty ? "-" : ports.filter)"
            screen.drawString(truncatedToWidth(header, headerRect.width), x: headerRect.x, y: headerRect.y, style: Style(fg: .brightBlack))
            var table = PortsPanel.listeningTable(listeners: listeners,
                                                  holdersByPID: holders,
                                                  filter: ports.filter,
                                                  mineOnly: ports.mineOnly,
                                                  selected: ports.listeningSelection)
            table.ensureVisible(visibleRows: max(1, tableRect.height))
            ports.listeningSelection = table.selectedRow
            table.render(into: &screen, rect: tableRect)
        } else {
            let convention = HarborCoordinator.conventionRows(
                pool: portPoolStore.pool,
                projects: registry.projects,
                listeners: listeners,
                holdersByPID: holders
            )
            let other = HarborCoordinator.otherClaimRows(
                pool: portPoolStore.pool,
                projects: registry.projects,
                listeners: listeners,
                holdersByPID: holders
            )
            let overlapPorts = Set(overlaps.map(\.port))
            let summary = coordinator.poolSummary()
            let next = coordinator.nextFreePoolPort().map { "next free \($0)" } ?? "pool exhausted"
            let header = "port convention — \(summary.label) · \(summary.allocated)/\(summary.capacity) allocated · \(next)  [v] listening · ⚠ = overlap"
            screen.drawString(truncatedToWidth(header, headerRect.width), x: headerRect.x, y: headerRect.y, style: Style(fg: .brightBlack))
            let built = PortsPanel.conventionTable(conventionRows: convention,
                                                   otherRows: other,
                                                   overlapPorts: overlapPorts,
                                                   selected: ports.overviewSelection)
            var table = built.table
            allocationItems = built.items
            overviewRowCount = allocationItems.count
            table.ensureVisible(visibleRows: max(1, tableRect.height))
            ports.overviewSelection = table.selectedRow
            table.render(into: &screen, rect: tableRect)
        }
    }

    private func logsLabel() -> String {
        guard let key = logs.focused else { return "no process selected — press Enter on a process in Projects" }
        let projectName = registry.projects.first { $0.id == key.projectID }?.name ?? key.projectID
        return "\(projectName) / \(key.processName)"
    }

    private func panelName() -> String {
        switch panel {
        case .projects: return "projects"
        case .logs: return "logs"
        case .ports: return ports.subview == .listening ? "ports — listening" : "ports — convention"
        }
    }

    private func hintText() -> String {
        switch panel {
        case .projects:
            return "⏎ logs · s start · S start all · x stop · X stop all · r restart · : refresh"
        case .logs:
            return "f follow · c clear · j/k scroll · PgUp/PgDn page"
        case .ports:
            return ports.subview == .listening
                ? "v convention · m mine-only · / filter · x kill"
                : "v listening · x kill holder"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
