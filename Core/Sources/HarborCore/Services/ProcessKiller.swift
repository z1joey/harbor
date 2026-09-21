import Foundation
import Darwin

/// Signal helpers: kill a PID or the whole descendant tree (TERM, then KILL after grace).
public enum ProcessKiller {
    public enum KillError: Error, Equatable {
        case notRunning(pid_t)
        case permissionDenied(pid_t)
        case signalFailed(pid_t, Int32)

        public var message: String {
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

    public static func send(_ signal: Int32, to pid: pid_t) -> Result<Void, KillError> {
        if kill(pid, signal) == 0 { return .success(()) }
        switch errno {
        case ESRCH: return .failure(.notRunning(pid))
        case EPERM: return .failure(.permissionDenied(pid))
        case let other: return .failure(.signalFailed(pid, other))
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Kernel start time of `pid` (seconds since epoch), used to detect PID
    /// reuse between a snapshot and a later signal. Nil when it cannot be
    /// determined (process gone, or sysctl failed) — callers then keep the
    /// old behavior instead of skipping the kill.
    static func startTime(of pid: pid_t) -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let tv = proc.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    /// Start times for a set of target PIDs, taken as one snapshot.
    private static func startTimes(of pids: [pid_t]) -> [pid_t: TimeInterval] {
        var result: [pid_t: TimeInterval] = [:]
        for pid in pids {
            if let start = startTime(of: pid) {
                result[pid] = start
            }
        }
        return result
    }

    /// True when `pid` is still the same process the snapshot saw (or the
    /// snapshot has no record and we can't tell).
    private static func isSameProcess(_ pid: pid_t, snapshot: [pid_t: TimeInterval]) -> Bool {
        guard let snapped = snapshot[pid] else { return true }
        return startTime(of: pid) == snapped
    }

    /// Snapshot of every process as (pid, parent pid).
    public static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
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
    public static func descendants(of root: pid_t, in table: [(pid: pid_t, ppid: pid_t)]) -> Set<pid_t> {
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
    /// Fails only if the root process itself could not be signaled (e.g.
    /// permission denied); a root that is already gone counts as success.
    /// KILL is withheld from a PID whose kernel start time no longer matches
    /// the snapshot — the original target exited and the PID was reused.
    public static func terminateTree(rootPID: pid_t, grace: TimeInterval = 2.0) async -> Result<Void, KillError> {
        let table = processTable()
        let targets = Array(descendants(of: rootPID, in: table)) + [rootPID]
        let snapshot = startTimes(of: targets)

        var rootError: KillError?
        for pid in targets {
            if case .failure(let error) = send(SIGTERM, to: pid), pid == rootPID {
                rootError = error
            }
        }
        if rootError != nil, targets.count == 1 {
            // Root didn't even take TERM; nothing else to do.
            if case .notRunning = rootError! { return .success(()) }
            return .failure(rootError!)
        }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !targets.contains(where: isAlive) { return .success(()) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for pid in targets where isAlive(pid) {
            if isSameProcess(pid, snapshot: snapshot) {
                _ = send(SIGKILL, to: pid)
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let rootError {
            if case .notRunning = rootError { return .success(()) }
            return .failure(rootError)
        }
        return .success(())
    }

    /// Synchronous stop used at app-quit time (short grace, blocks the caller briefly).
    public static func emergencyStop(rootPID: pid_t, grace: TimeInterval = 1.0) {
        let table = processTable()
        let targets = Array(descendants(of: rootPID, in: table)) + [rootPID]
        let snapshot = startTimes(of: targets)
        for pid in targets {
            _ = send(SIGTERM, to: pid)
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !targets.contains(where: isAlive) { return }
            usleep(80_000)
        }
        for pid in targets where isAlive(pid) {
            if isSameProcess(pid, snapshot: snapshot) {
                _ = send(SIGKILL, to: pid)
            }
        }
    }
}
