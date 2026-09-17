import Foundation
import Darwin

/// Starts/stops managed process groups via `/bin/zsh -lc`, captures stdout/stderr
/// into per-process ring buffers, tracks state, and optionally auto-restarts.
///
/// Ownership: Harbor only considers a process "managed" if it spawned it here.
/// Stop = SIGTERM the whole descendant tree, wait ~2s, SIGKILL survivors.
@MainActor
public final class ProcessSupervisor: ObservableObject {
    /// Callback for "auto-restart gave up" — AppState wires it to user notifications.
    public var onAutoRestartGiveUp: ((ProcessKey, String) -> Void)?
    /// Picks a free port for `port = "auto"` processes. AppState wires this to PortPlanner.
    public var portAllocator: ((ProcessKey, ProcessDefinition) -> Int?)?

    private(set) var logBuffers: [ProcessKey: LogBuffer] = [:]
    private var processes: [ProcessKey: ManagedProcess] = [:]

    @Published public private(set) var statuses: [ProcessKey: ProcessStatus] = [:]

    public init() {}

    private let autoRestartBackoff: [TimeInterval] = [1, 2, 5]
    private let maxAutoRestartAttempts = 3
    /// A process that ran at least this long before exiting is considered "stable":
    /// its crash-restart counter resets.
    private let stabilityInterval: TimeInterval = 30

    // MARK: - Queries

    public func logBuffer(for key: ProcessKey) -> LogBuffer {
        if let existing = logBuffers[key] { return existing }
        let buffer = LogBuffer()
        logBuffers[key] = buffer
        return buffer
    }

    public func status(for key: ProcessKey) -> ProcessStatus {
        statuses[key] ?? ProcessStatus()
    }

    public func managedPIDs() -> Set<pid_t> {
        Set(processes.values.compactMap(\.pid))
    }

    public func managedRunningPIDs() -> [pid_t] {
        processes.values.filter { $0.state.isRunningLike }.compactMap(\.pid)
    }

    public func runningCount() -> Int {
        processes.values.filter { $0.state.isRunningLike }.count
    }

    /// Ports currently assigned to running-like auto-port processes.
    public func assignedPorts() -> Set<Int> {
        Set(processes.values.compactMap { managed in
            guard managed.state.isRunningLike, let port = managed.assignedPort else { return nil }
            return port
        })
    }

    public func key(forPID pid: pid_t) -> ProcessKey? {
        processes.first(where: { $0.value.pid == pid })?.key
    }

    // MARK: - Start

    @discardableResult
    public func start(key: ProcessKey, definition: ProcessDefinition, projectRoot: URL, userInitiated: Bool = true) -> Result<Void, HarborError> {
        let managed = existingOrNewProcess(key: key, definition: definition, projectRoot: projectRoot)
        managed.definition = definition
        managed.projectRoot = projectRoot
        guard !managed.state.isRunningLike, managed.state != .stopping else { return .success(()) }
        if userInitiated {
            managed.restartAttempts = 0
        }

        var workDirectory = projectRoot
        if let cwd = definition.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            workDirectory = projectRoot.appendingPathComponent(cwd)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fail(managed, message: "Working directory does not exist: \(workDirectory.path)")
        }

        if definition.autoPort {
            guard let allocator = portAllocator else {
                return fail(managed, message: "Auto port allocation is not configured.")
            }
            guard let allocated = allocator(key, definition) else {
                return fail(managed, message: "No free port in \(PortPlanner.autoPortRange.lowerBound)–\(PortPlanner.autoPortRange.upperBound).")
            }
            managed.assignedPort = allocated
            managed.logBuffer.appendLine("— Harbor: assigned port \(allocated) (\(definition.portEnv)) —")
        } else {
            managed.assignedPort = nil
        }

        let resolvedPort = managed.assignedPort ?? definition.port
        let resolvedReadyURL = definition.readyURL(port: resolvedPort)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so the user's PATH (homebrew, uv, nvm, …) is available.
        process.arguments = ["-l", "-c", definition.command]
        process.currentDirectoryURL = workDirectory
        var mergedEnv = ProcessInfo.processInfo.environment.merging(definition.env) { _, override in override }
        if let allocated = managed.assignedPort {
            mergedEnv[definition.portEnv] = String(allocated)
        }
        process.environment = mergedEnv
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = managed.logBuffer
        let outForker = LineForker { [weak buffer] line in buffer?.appendLine(line) }
        let errForker = LineForker { [weak buffer] line in buffer?.appendLine(line) }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outForker.feed(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errForker.feed(data)
        }
        managed.outPipe = outPipe
        managed.errPipe = errPipe
        managed.outForker = outForker
        managed.errForker = errForker

        managed.state = .starting
        managed.exitCode = nil
        managed.ready = resolvedReadyURL != nil ? false : nil
        managed.userInitiatedStop = false
        managed.startedAt = Date()
        managed.process = process
        managed.pid = nil
        publish(managed)

        let capturedKey = key
        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(key: capturedKey, exitCode: code)
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            managed.process = nil
            return fail(managed, message: "Failed to start: \(error.localizedDescription)")
        }

        // Best effort: make the child a process-group leader so group kills are possible.
        // The sysctl-based tree kill in ProcessKiller covers the case where this loses the race.
        _ = setpgid(process.processIdentifier, process.processIdentifier)

        managed.pid = process.processIdentifier
        managed.state = .running
        buffer.appendLine("— Harbor: started \"\(definition.name)\" (PID \(managed.pid ?? 0)) in \(workDirectory.path) —")
        publish(managed)

        if let readyURL = resolvedReadyURL {
            managed.healthTask = Task { [weak self] in
                let ready = await HealthProbe.waitUntilReady(url: readyURL)
                guard !Task.isCancelled else { return }
                await self?.markReady(key: capturedKey, ready: ready, url: readyURL)
            }
        }
        return .success(())
    }

    // MARK: - Stop / Restart

    public func stop(key: ProcessKey) async {
        guard let managed = processes[key] else { return }
        guard let pid = managed.pid, managed.process != nil else {
            managed.state = .stopped
            managed.userInitiatedStop = false
            publish(managed)
            return
        }
        managed.state = .stopping
        managed.userInitiatedStop = true
        cancelHelperTasks(managed)
        publish(managed)

        let result = await Task.detached(priority: .userInitiated) {
            await ProcessKiller.terminateTree(rootPID: pid, grace: 2.0)
        }.value

        if case .failure(let error) = result {
            managed.logBuffer.appendLine("— Harbor: stop had a problem: \(error.message) —")
        }
        // handleTermination usually lands first; this is a safety net if the
        // process was already reaped before the handler was observed.
        if managed.state == .stopping {
            finishStop(managed, exitCode: managed.exitCode)
        }
    }

    public func restart(key: ProcessKey, projectRoot: URL) async {
        guard let managed = processes[key] else { return }
        let definition = managed.definition
        await stop(key: key)
        // Give the port a moment to be released.
        try? await Task.sleep(nanoseconds: 300_000_000)
        start(key: key, definition: definition, projectRoot: projectRoot, userInitiated: true)
    }

    public func stopAllRunning() async {
        let runningKeys = processes.values
            .filter { $0.state.isRunningLike }
            .map(\.key)
        for key in runningKeys {
            await stop(key: key)
        }
    }

    /// Synchronous emergency stop used at application quit (~1s grace).
    public func emergencyStopAll() {
        for pid in managedRunningPIDs() {
            ProcessKiller.emergencyStop(rootPID: pid, grace: 1.0)
        }
    }

    // MARK: - Internals

    private func existingOrNewProcess(key: ProcessKey, definition: ProcessDefinition, projectRoot: URL) -> ManagedProcess {
        if let existing = processes[key] { return existing }
        let managed = ManagedProcess(key: key, definition: definition, projectRoot: projectRoot, logBuffer: logBuffer(for: key))
        processes[key] = managed
        return managed
    }

    private func handleTermination(key: ProcessKey, exitCode: Int32) {
        guard let managed = processes[key] else { return }
        guard managed.process !== nil else { return }
        drainPipes(managed)

        managed.exitCode = exitCode
        managed.process = nil
        managed.pid = nil
        managed.assignedPort = nil
        managed.ready = nil
        managed.healthTask?.cancel()
        managed.healthTask = nil
        cancelHelperTasks(managed)

        if let startedAt = managed.startedAt, Date().timeIntervalSince(startedAt) > stabilityInterval {
            managed.restartAttempts = 0
        }

        if managed.userInitiatedStop || managed.state == .stopping {
            finishStop(managed, exitCode: exitCode)
            return
        }

        managed.state = .failed
        let ranStable = managed.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        managed.logBuffer.appendLine("— Harbor: \"\(managed.definition.name)\" exited unexpectedly (exit code \(exitCode)) after \(Int(ranStable))s —")

        if managed.definition.autoRestart {
            if managed.restartAttempts < maxAutoRestartAttempts {
                let delay = autoRestartBackoff[min(managed.restartAttempts, autoRestartBackoff.count - 1)]
                managed.restartAttempts += 1
                managed.logBuffer.appendLine("— Harbor: auto-restarting in \(Int(delay))s (attempt \(managed.restartAttempts)/\(maxAutoRestartAttempts)) —")
                publish(managed)
                let capturedKey = key
                managed.restartTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.performAutoRestart(key: capturedKey)
                }
                publish(managed)
                return
            }
            managed.logBuffer.appendLine("— Harbor: giving up after \(maxAutoRestartAttempts) consecutive auto-restarts —")
            onAutoRestartGiveUp?(key, "\"\(managed.definition.name)\" in \(managed.projectRoot.lastPathComponent) kept crashing; auto-restart gave up.")
        }
        publish(managed)
    }

    private func performAutoRestart(key: ProcessKey) {
        guard let managed = processes[key] else { return }
        guard managed.state == .failed, !managed.userInitiatedStop else { return }
        managed.restartTask = nil
        start(key: key, definition: managed.definition, projectRoot: managed.projectRoot, userInitiated: false)
    }

    private func finishStop(_ managed: ManagedProcess, exitCode: Int32?) {
        managed.state = .stopped
        managed.userInitiatedStop = false
        managed.restartAttempts = 0
        managed.logBuffer.appendLine("— Harbor: \"\(managed.definition.name)\" stopped (exit code \(exitCode.map(String.init) ?? "?")) —")
        publish(managed)
    }

    private func markReady(key: ProcessKey, ready: Bool, url: URL) {
        guard let managed = processes[key], managed.state.isRunningLike else { return }
        managed.ready = ready
        managed.logBuffer.appendLine(ready
            ? "— Harbor: health check OK (\(url.absoluteString)) —"
            : "— Harbor: health check timed out (\(url.absoluteString)) —")
        publish(managed)
    }

    private func cancelHelperTasks(_ managed: ManagedProcess) {
        managed.healthTask?.cancel()
        managed.healthTask = nil
        managed.restartTask?.cancel()
        managed.restartTask = nil
    }

    private func drainPipes(_ managed: ManagedProcess) {
        for (pipe, forker) in [(managed.outPipe, managed.outForker), (managed.errPipe, managed.errForker)] {
            guard let pipe, let forker else { continue }
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = nil
            DispatchQueue.global(qos: .utility).async {
                if let rest = try? handle.readToEnd() {
                    forker.feed(rest)
                }
                forker.flush()
            }
        }
    }

    private func fail(_ managed: ManagedProcess, message: String) -> Result<Void, HarborError> {
        managed.state = .failed
        managed.process = nil
        managed.pid = nil
        managed.assignedPort = nil
        managed.logBuffer.appendLine("— Harbor error: \(message) —")
        publish(managed)
        return .failure(HarborError(message))
    }

    private func publish(_ managed: ManagedProcess) {
        statuses[managed.key] = ProcessStatus(
            state: managed.state,
            pid: managed.pid,
            ready: managed.ready,
            exitCode: managed.exitCode,
            restartAttempt: managed.restartAttempts,
            assignedPort: managed.assignedPort,
            startedAt: managed.startedAt
        )
    }
}

/// Private per-process runtime record.
private final class ManagedProcess {
    let key: ProcessKey
    var definition: ProcessDefinition
    var projectRoot: URL
    let logBuffer: LogBuffer

    var process: Process?
    var outPipe: Pipe?
    var errPipe: Pipe?
    var outForker: LineForker?
    var errForker: LineForker?

    var state: ProcessState = .stopped
    var pid: pid_t?
    var ready: Bool?
    var exitCode: Int32?
    var restartAttempts = 0
    var startedAt: Date?
    var userInitiatedStop = false
    var healthTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?
    var assignedPort: Int?

    init(key: ProcessKey, definition: ProcessDefinition, projectRoot: URL, logBuffer: LogBuffer) {
        self.key = key
        self.definition = definition
        self.projectRoot = projectRoot
        self.logBuffer = logBuffer
    }
}

/// Splits a byte stream into lines from arbitrary chunks (pipe reader callback).
final class LineForker {
    private var pending = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            onLine(Self.decode(lineData))
        }
        if pending.count > 65_536 {
            onLine(Self.decode(pending))
            pending.removeAll()
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let rest = pending
        pending.removeAll()
        onLine(Self.decode(rest))
    }

    private static func decode(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.hasSuffix("\r") ? String(text.dropLast()) : text
    }
}
