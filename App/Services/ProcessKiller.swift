import Foundation
import Darwin

/// Signal helpers: kill a PID or the whole descendant tree (TERM, then KILL after grace).
enum ProcessKiller {
    enum KillError: Error, Equatable {
        case notRunning(pid_t)
        case permissionDenied(pid_t)
        case signalFailed(pid_t, Int32)

        var message: String {
            switch self {
            case .notRunning(let pid):
                return "PID \(pid) is not running (it may have already exited)."
            case .permissionDenied(let pid):
                return "PID \(pid) is owned by another user — Harbor can only kill processes you own."
            case .signalFailed(let pid, let errnoValue):
                return "Could not signal PID \(pid) (errno \(errnoValue))."
            }
        }
    }

    static func send(_ signal: Int32, to pid: pid_t) -> Result<Void, KillError> {
        if kill(pid, signal) == 0 { return .success(()) }
        switch errno {
        case ESRCH: return .failure(.notRunning(pid))
        case EPERM: return .failure(.permissionDenied(pid))
        case let other: return .failure(.signalFailed(pid, other))
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Snapshot of every process as (pid, parent pid).
    static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var count = size / stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        count = size / stride
        return procs.prefix(count).map { (pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid) }
    }

    /// All living descendants of `root` (excluding the root itself), computed from a snapshot.
    static func descendants(of root: pid_t, in table: [(pid: pid_t, ppid: pid_t)]) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for entry in table where entry.ppid != 0 {
            children[entry.ppid, default: []].append(entry.pid)
        }
        var found = Set<pid_t>()
        var stack = [root]
        while let current = stack.popLast() {
            for child in children[current] ?? [] where !found.contains(child) {
                found.insert(child)
                stack.append(child)
            }
        }
        return found
    }

    /// TERM the whole tree, wait up to `grace` seconds, KILL whatever survives.
    /// Fails only if the root process itself could not be signaled (e.g. permission denied).
    static func terminateTree(rootPID: pid_t, grace: TimeInterval = 2.0) async -> Result<Void, KillError> {
        let table = processTable()
        let targets = Array(descendants(of: rootPID, in: table)) + [rootPID]

        var rootError: KillError?
        for pid in targets {
            if case .failure(let error) = send(SIGTERM, to: pid), pid == rootPID {
                rootError = error
            }
        }
        if rootError != nil, targets.count == 1 {
            // Root didn't even take TERM; nothing else to do.
            return .failure(rootError!)
        }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !targets.contains(where: isAlive) { return .success(()) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for pid in targets where isAlive(pid) {
            _ = send(SIGKILL, to: pid)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let rootError { return .failure(rootError) }
        return .success(())
    }

    /// Synchronous stop used at app-quit time (short grace, blocks the caller briefly).
    static func emergencyStop(rootPID: pid_t, grace: TimeInterval = 1.0) {
        let table = processTable()
        let targets = Array(descendants(of: rootPID, in: table)) + [rootPID]
        for pid in targets {
            _ = send(SIGTERM, to: pid)
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !targets.contains(where: isAlive) { return }
            usleep(80_000)
        }
        for pid in targets where isAlive(pid) {
            _ = send(SIGKILL, to: pid)
        }
    }
}
