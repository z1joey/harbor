import Foundation
import HarborCore
import HarborTUIKit

/// Ports panel with two subviews: live listening sockets and the Port
/// Allocation Convention (pool leases + other claims).
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

    private static let conventionColumns = [
        TableColumn(title: "PORT", width: 7, alignment: .right),
        TableColumn(title: "PROJECT", width: 18),
        TableColumn(title: "PROCESS", width: 16),
        TableColumn(title: "STATUS", width: 10),
        TableColumn(title: "HOLDER", width: 28),
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

    /// Flattened convention + other-claims table. Header rows have a nil payload
    /// so the TUI can skip them when killing.
    struct AllocationItem {
        let listener: Listener?
        let isHeader: Bool
    }

    static func conventionTable(conventionRows: [HarborCoordinator.ConventionRow],
                                otherRows: [HarborCoordinator.OverviewRow],
                                overlapPorts: Set<Int>,
                                selected: Int?) -> (table: TableView, items: [AllocationItem]) {
        var tableRows: [TableRow] = []
        var items: [AllocationItem] = []

        func statusCells(listener: Listener?, managed: PortPlanner.ManagedHolder?) -> (status: String, color: Color?, holder: String) {
            let status: String
            let statusColor: Color?
            if managed != nil {
                status = "managed"
                statusColor = .green
            } else if listener != nil {
                status = "external"
                statusColor = .yellow
            } else {
                status = "free"
                statusColor = .brightBlack
            }
            let holderText: String
            if let managed {
                holderText = "\(managed.projectName) · \(managed.processName)"
            } else if let listener {
                holderText = listener.processName
            } else {
                holderText = "—"
            }
            return (status, statusColor, holderText)
        }

        tableRows.append(TableRow(["──", "pool leases", "", "", ""], style: Style(fg: .brightBlack, bold: true)))
        items.append(AllocationItem(listener: nil, isHeader: true))

        if conventionRows.isEmpty {
            tableRows.append(TableRow(["", "none — declare [[process]].port from the pool", "", "", ""],
                                      style: Style(fg: .brightBlack)))
            items.append(AllocationItem(listener: nil, isHeader: true))
        } else {
            for row in conventionRows {
                let cells = statusCells(listener: row.listener, managed: row.managedHolder)
                var style = Style(fg: cells.color)
                if overlapPorts.contains(row.port) {
                    style = style + Style(bold: true)
                }
                let port = overlapPorts.contains(row.port) ? "\(row.port) ⚠" : String(row.port)
                tableRows.append(TableRow([port, row.projectName, row.processName, cells.status, cells.holder], style: style))
                items.append(AllocationItem(listener: row.listener, isHeader: false))
            }
        }

        tableRows.append(TableRow(["──", "other claims", "", "", ""], style: Style(fg: .brightBlack, bold: true)))
        items.append(AllocationItem(listener: nil, isHeader: true))

        if otherRows.isEmpty {
            tableRows.append(TableRow(["", "none", "", "", ""], style: Style(fg: .brightBlack)))
            items.append(AllocationItem(listener: nil, isHeader: true))
        } else {
            for row in otherRows {
                let cells = statusCells(listener: row.listener, managed: row.managedHolder)
                var style = Style(fg: cells.color)
                if overlapPorts.contains(row.port) {
                    style = style + Style(bold: true)
                }
                let port = overlapPorts.contains(row.port) ? "\(row.port) ⚠" : String(row.port)
                let project = row.projectNames.isEmpty ? "—" : row.projectNames.joined(separator: ", ")
                let process = row.claimDetails.first.map { detail in
                    if let dash = detail.range(of: " — ") {
                        return String(detail[dash.upperBound...])
                    }
                    return detail
                } ?? "—"
                tableRows.append(TableRow([port, project, process, cells.status, cells.holder], style: style))
                items.append(AllocationItem(listener: row.listener, isHeader: false))
            }
        }

        var table = TableView(columns: conventionColumns, rows: tableRows)
        table.select(selected)
        return (table, items)
    }
}
