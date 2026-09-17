import Foundation

/// Polls the system for listening TCP ports via `lsof` on a background queue
/// (~every 2 seconds) and publishes a deduplicated snapshot on the main actor.
@MainActor
public final class PortObserver: ObservableObject {
    @Published public private(set) var listeners: [Listener] = []
    @Published public private(set) var lastError: String?

    private let queue = DispatchQueue(label: "app.harbor.Harbor.port-observer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pollGeneration = 0

    public init() {}

    public func start(interval: TimeInterval = 2.0) {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        source.resume()
        timer = source
    }

    public func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    /// Runs one lsof pass immediately (off the main thread) and publishes the result.
    public func refresh() async {
        pollGeneration += 1
        let generation = pollGeneration
        let snapshot: Result<[Listener], HarborError> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.collectListeners())
            }
        }
        guard generation == pollGeneration else { return }
        switch snapshot {
        case .success(let fresh):
            listeners = fresh
            lastError = nil
        case .failure(let error):
            // Keep the last known snapshot visible; surface the problem.
            lastError = error.message
        }
    }

    public func pidsListening(on port: Int) -> [pid_t] {
        Self.pidsListening(in: listeners, on: port)
    }

    /// The listener on `port` that is not one of Harbor's managed PIDs, if any.
    public func foreignListener(on port: Int, managedPIDs: Set<pid_t>) -> Listener? {
        Self.foreignListener(in: listeners, on: port, managedPIDs: managedPIDs)
    }

    // MARK: - Pure helpers (unit-testable)

    nonisolated static func pidsListening(in listeners: [Listener], on port: Int) -> [pid_t] {
        listeners.filter { $0.port == port }.map(\.pid)
    }

    nonisolated static func foreignListener(in listeners: [Listener], on port: Int, managedPIDs: Set<pid_t>) -> Listener? {
        listeners.first { $0.port == port && !managedPIDs.contains($0.pid) }
    }

    // MARK: - lsof

    /// macOS ships lsof in /usr/sbin (older/toolchain layouts may differ) — resolve once.
    private nonisolated static let lsofPath: String? = {
        for candidate in ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof", "/usr/local/bin/lsof", "/opt/homebrew/bin/lsof"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    nonisolated static func collectListeners() -> Result<[Listener], HarborError> {
        guard let lsofPath else {
            return .failure(HarborError("lsof was not found on this system."))
        }
        // +c0 prints the full command name (can contain spaces) — parse columns right-to-left.
        let run = runProcess(executable: lsofPath, arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "+c0"])
        switch run {
        case .failure(let message):
            return .failure(HarborError("lsof failed: \(message)"))
        case .success(let output):
            let parsed = parseLsofOutput(output)
            guard !parsed.isEmpty else { return .success([]) }
            let commands = commandLines(for: Set(parsed.map(\.pid)))
            var result: [Listener] = parsed
            for index in result.indices {
                result[index].command = commands[result[index].pid]
            }
            result.sort { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
            return .success(result)
        }
    }

    /// Parses raw `lsof` output into listeners deduplicated by (port, pid) and
    /// sorted by port. Internal (not private) so unit tests can feed fixture text.
    nonisolated static func parseLsofOutput(_ text: String) -> [Listener] {
        var seen = Set<String>()
        var listeners: [Listener] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("COMMAND") { continue }
            // lsof -i appends the socket state in parentheses: "… TCP *:8000 (LISTEN)"
            if line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
                line = line[..<open].trimmingCharacters(in: .whitespaces)
            }
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9 else { continue }
            // Right-to-left: NAME NODE SIZE/OFF DEVICE TYPE FD USER PID COMMAND...
            let name = fields.removeLast()
            let node = fields.removeLast()
            _ = fields.removeLast() // size/off
            _ = fields.removeLast() // device
            let type = fields.removeLast()
            _ = fields.removeLast() // fd
            let user = fields.removeLast()
            let pidString = fields.removeLast()
            let command = fields.joined(separator: " ")
            guard node == "TCP" || node == "TCP6" || node == "tcp" || node == "tcp6" else { continue }
            guard let pid = pid_t(pidString), pid > 0 else { continue }
            guard let colon = name.lastIndex(of: ":") else { continue }
            guard let port = Int(name[name.index(after: colon)...]), port > 0, port <= 65535 else { continue }
            let proto = type.uppercased().contains("6") ? "TCP6" : "TCP"
            let listener = Listener(port: port, pid: pid, processName: command, user: user, proto: proto, command: nil)
            // One pid can listen on both IPv4 and IPv6 — keep one row per (port, pid).
            guard seen.insert(listener.id).inserted else { continue }
            listeners.append(listener)
        }
        listeners.sort { $0.port != $1.port ? $0.port < $1.port : $0.pid < $1.pid }
        return listeners
    }

    /// One `ps` pass for full command lines of the given PIDs.
    private nonisolated static func commandLines(for pids: Set<pid_t>) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        guard case .success(let output) = runProcess(executable: "/bin/ps", arguments: ["-axo", "pid=,command="]) else {
            return [:]
        }
        var wanted = pids
        var map: [pid_t: String] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(line[..<space]) else { continue }
            guard wanted.contains(pid) else { continue }
            let command = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            if !command.isEmpty {
                map[pid] = command
                wanted.remove(pid)
            }
            if wanted.isEmpty { break }
        }
        return map
    }

    private nonisolated static func runProcess(executable: String, arguments: [String]) -> Result<String, HarborError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(HarborError(error.localizedDescription))
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outData, as: UTF8.self)
        let exitCode = process.terminationStatus
        // lsof exits 1 when nothing matched — that's an empty snapshot, not a failure.
        if exitCode == 0 || (exitCode == 1 && output.isEmpty) {
            return .success(output)
        }
        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(HarborError(errText.isEmpty ? "exit status \(exitCode)" : errText))
    }
}
