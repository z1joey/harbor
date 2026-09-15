import Foundation

/// One TCP listener (deduplicated by port + PID) as reported by `lsof`.
struct Listener: Identifiable, Hashable {
    let port: Int
    let pid: pid_t
    let processName: String
    let user: String
    let proto: String
    var command: String?

    var id: String { "\(port)-\(pid)" }

    var isMine: Bool { user == NSUserName() }

    var commandDisplay: String {
        if let command, !command.isEmpty { return command }
        return processName
    }
}
