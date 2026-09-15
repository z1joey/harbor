import Foundation

/// Lifecycle of a managed process.
enum ProcessState: String {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var isRunningLike: Bool { self == .running || self == .starting }
}

/// Identifies a managed process: (project root path, process name from config).
struct ProcessKey: Hashable {
    let projectID: String
    let processName: String
}

/// UI-facing snapshot of a managed process at a point in time.
struct ProcessStatus {
    var state: ProcessState = .stopped
    var pid: pid_t?
    /// nil = no `ready_url` configured; true/false = health probe result.
    var ready: Bool?
    var exitCode: Int32?
    var restartAttempt: Int = 0

    var isRunningLike: Bool { state == .running || state == .starting }
}
