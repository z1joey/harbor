import Foundation

/// One TCP listener (deduplicated by port + PID) as reported by `lsof`.
public struct Listener: Identifiable, Hashable {
    public let port: Int
    public let pid: pid_t
    public let processName: String
    public let user: String
    public let proto: String
    public var command: String?

    public var id: String { "\(port)-\(pid)" }

    public var isMine: Bool { user == NSUserName() }

    public var commandDisplay: String {
        if let command, !command.isEmpty { return command }
        return processName
    }

    public init(port: Int, pid: pid_t, processName: String, user: String, proto: String, command: String?) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.user = user
        self.proto = proto
        self.command = command
    }
}
