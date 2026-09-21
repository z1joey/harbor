import Foundation
import HarborCore
import HarborTUIKit

/// Projects panel: a flat list of project rows, each followed by its process
/// rows. `targets` maps table row index → what the selection acts on.
struct ProjectsPanel {
    enum Target {
        case project(Project)
        case process(Project, ProcessDefinition, ProcessKey)
    }

    private static let columns = [
        TableColumn(title: "", width: 2),
        TableColumn(title: "NAME", width: 26),
        TableColumn(title: "STATUS", width: 19),
        TableColumn(title: "PORT", width: 12),
        TableColumn(title: "PID", width: 7, alignment: .right),
        TableColumn(title: "INFO", width: 48),
    ]

    /// Builds the table and the parallel target list for selection actions.
    static func build(projects: [Project],
                      statuses: [ProcessKey: ProcessStatus],
                      conflictsByProcess: [String: PortPlanner.RuntimeConflict],
                      verifications: [ProcessKey: PortVerification],
                      selected: Int?,
                      visibleRows: Int) -> (table: TableView, targets: [Target]) {
        var rows: [TableRow] = []
        var targets: [Target] = []

        for project in projects {
            let running = project.processes.filter { statuses[ProcessKey(projectID: project.id, processName: $0.name)]?.state.isRunningLike ?? false }.count
            let header: String
            var headerStyle = Style(bold: true)
            if project.configError != nil {
                header = "\(project.name) — config error"
                headerStyle = Style(fg: .red, bold: true)
            } else {
                header = "\(project.name) — \(running)/\(project.processes.count) running"
            }
            rows.append(TableRow(["▪", header, "", "", "", ""], style: headerStyle))
            targets.append(.project(project))

            for definition in project.processes {
                let key = ProcessKey(projectID: project.id, processName: definition.name)
                let status = statuses[key] ?? ProcessStatus()
                var info = ""
                if let conflict = conflictsByProcess["\(project.id)::\(definition.name)"] {
                    info = "⚠ port held by \(conflict.holderLabel)"
                } else if let verification = verifications[key] {
                    info = "⚠ listening on \(verification.observed.sorted().map(String.init).joined(separator: ", ")), expected \(verification.expected)"
                } else if let port = definition.port,
                          !PortPlanner.commandReferencesDeclaredPort(definition.command, port: port, envName: definition.portEnv) {
                    info = "command does not use $\(definition.portEnv) or \(port)"
                }
                let stateChar = "●"
                let rowStyle = Style(fg: stateColor(status.state))
                rows.append(TableRow([
                    stateChar,
                    "  " + definition.name,
                    Self.statusText(status),
                    Self.portLabel(definition, status),
                    status.pid.map(String.init) ?? "—",
                    info,
                ], style: rowStyle))
                targets.append(.process(project, definition, key))
            }
        }

        var table = TableView(columns: columns, rows: rows)
        table.select(selected)
        table.ensureVisible(visibleRows: max(1, visibleRows))
        return (table, targets)
    }

    static func stateColor(_ state: ProcessState) -> Color? {
        switch state {
        case .running: return .green
        case .starting: return .yellow
        case .stopping: return .yellow
        case .failed: return .red
        case .stopped: return .brightBlack
        }
    }

    static func statusText(_ status: ProcessStatus) -> String {
        switch status.state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .running:
            switch status.ready {
            case .some(true): return "running (ready)"
            case .some(false): return "running (waiting)"
            case .none: return "running"
            }
        case .failed: return "failed (exit \(status.exitCode.map(String.init) ?? "?"))"
        }
    }

    static func portLabel(_ definition: ProcessDefinition, _: ProcessStatus) -> String {
        if let port = definition.port { return ":\(port)" }
        return "—"
    }
}
