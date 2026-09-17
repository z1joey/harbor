import Foundation

/// Lifecycle of a managed process.
public enum ProcessState: String {
    case stopped
    case starting
    case running
    case stopping
    case failed

    public var isRunningLike: Bool { self == .running || self == .starting }
}

/// Identifies a managed process: (project root path, process name from config).
public struct ProcessKey: Hashable {
    public let projectID: String
    public let processName: String

    public init(projectID: String, processName: String) {
        self.projectID = projectID
        self.processName = processName
    }
}

/// UI-facing snapshot of a managed process at a point in time.
public struct ProcessStatus {
    public var state: ProcessState = .stopped
    public var pid: pid_t?
    /// nil = no `ready_url` configured; true/false = health probe result.
    public var ready: Bool?
    public var exitCode: Int32?
    public var restartAttempt: Int = 0
    /// Port Harbor assigned for `port = "auto"`; cleared on stop.
    public var assignedPort: Int?
    /// When the current run started; used for port-verification grace period.
    public var startedAt: Date?

    public var isRunningLike: Bool { state == .running || state == .starting }

    public init(state: ProcessState = .stopped,
                pid: pid_t? = nil,
                ready: Bool? = nil,
                exitCode: Int32? = nil,
                restartAttempt: Int = 0,
                assignedPort: Int? = nil,
                startedAt: Date? = nil) {
        self.state = state
        self.pid = pid
        self.ready = ready
        self.exitCode = exitCode
        self.restartAttempt = restartAttempt
        self.assignedPort = assignedPort
        self.startedAt = startedAt
    }
}

/// Runtime check: managed process listens on a port other than Harbor expects.
public struct PortVerification: Hashable {
    public let expected: Int
    public let observed: Set<Int>

    public init(expected: Int, observed: Set<Int>) {
        self.expected = expected
        self.observed = observed
    }
}
