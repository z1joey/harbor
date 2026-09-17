import Foundation
import HarborCore
import HarborTUIKit

/// Ports panel with two subviews: live listening sockets and the planning
/// overview (claimed vs. listening, static overlaps).
struct PortsPanel {
    enum Subview {
        case listening
        case overview
    }

    var subview: Subview = .listening
    var mineOnly = false
    var filter = ""
    var listeningSelection: Int?
    var overviewSelection: Int?

    private static let listeningColumns = [
        TableColumn(title: "PORT", width: 7, alignment: .right),
        TableColumn(title: "PID", width: 8, alignment: .right),
        TableColumn(title: "PROCESS", width: 22),
        TableColumn(title: "USER", width: 11),
        TableColumn(title: "MANAGED", width: 9),
        TableColumn(title: "COMMAND", width: 40),
    ]

    private static let overviewColumns = [
        TableColumn(title: "PORT", width: 7, alignment: .right),
        TableColumn(title: "CLAIMED BY", width: 36),
        TableColumn(title: "STATUS", width: 10),
        TableColumn(title: "HOLDER", width: 36),
    ]

    static func matches(_ listener: Listener, filter: String, mineOnly: Bool) -> Bool {
        if mineOnly, !listener.isMine { return false }
        guard !filter.isEmpty else { return true }
        let needle = filter.lowercased()
        return listener.processName.lowercased().contains(needle)
            || listener.commandDisplay.lowercased().contains(needle)
            || String(listener.port).contains(needle)
            || String(listener.pid).contains(needle)
            || listener.user.lowercased().contains(needle)
    }

    static func listeningTable(listeners: [Listener],
                               holdersByPID: [pid_t: PortPlanner.ManagedHolder],
                               filter: String,
                               mineOnly: Bool,
                               selected: Int?) -> TableView {
        let visible = listeners.filter { matches($0, filter: filter, mineOnly: mineOnly) }
        let rows = visible.map { listener -> TableRow in
            let managed: String
            var style = Style()
            if holdersByPID[listener.pid] != nil {
                managed = "● harbor"
                style = Style(fg: .green)
            } else if listener.isMine {
                managed = "—"
            } else {
                managed = "—"
                style = Style(fg: .brightBlack)
            }
            return TableRow([
                String(listener.port),
                String(listener.pid),
                listener.processName,
                listener.user,
                managed,
                listener.commandDisplay,
            ], style: style)
        }
        var table = TableView(columns: listeningColumns, rows: rows)
        table.select(selected)
        return table
    }

    static func overviewTable(rows: [HarborCoordinator.OverviewRow],
                              overlapPorts: Set<Int>,
                              selected: Int?) -> TableView {
        let tableRows = rows.map { row -> TableRow in
            let status: String
            let statusColor: Color?
            if let holder = row.managedHolder {
                status = "managed"
                statusColor = .green
            } else if row.listener != nil {
                status = "external"
                statusColor = .yellow
            } else {
                status = "free"
                statusColor = .brightBlack
            }
            var style = Style(fg: statusColor)
            if overlapPorts.contains(row.port) {
                style = style + Style(bold: true)
            }
            let claims = row.claimDetails.isEmpty ? "—" : row.claimDetails.joined(separator: "; ")
            let holderText: String
            if let managed = row.managedHolder {
                holderText = "\(managed.projectName) · \(managed.processName)"
            } else if let listener = row.listener {
                holderText = listener.processName
            } else {
                holderText = "—"
            }
            let port = overlapPorts.contains(row.port) ? "\(row.port) ⚠" : String(row.port)
            return TableRow([port, claims, status, holderText], style: style)
        }
        var table = TableView(columns: overviewColumns, rows: tableRows)
        table.select(selected)
        return table
    }
}
