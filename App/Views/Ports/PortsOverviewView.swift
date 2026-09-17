import SwiftUI
import HarborCore

/// Planning view: every port any project claims, next to whoever is
/// listening on it right now. Static overlaps (two projects claiming one
/// port) surface at the top and on the port rows — this is where
/// cross-project port planning happens before anything is started.
struct PortsOverviewView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selection = Set<HarborCoordinator.OverviewRow.ID>()
    @State private var copyFeedback: String?

    /// Row model built by HarborCoordinator, shared with the TUI.
    private var rows: [HarborCoordinator.OverviewRow] {
        let listeners = appState.portObserver.listeners
        return HarborCoordinator.overviewRows(
            projects: appState.registry.projects,
            listeners: listeners,
            holdersByPID: appState.managedHolders(for: listeners),
            assignedPorts: appState.coordinator.assignedPortsByKey()
        )
    }

    private var overlapsByPort: [Int: PortPlanner.StaticOverlap] {
        Dictionary(appState.staticOverlaps.map { ($0.port, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private var selectedRow: HarborCoordinator.OverviewRow? {
        guard let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.staticOverlaps.isEmpty {
                overlapSummary
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .confirmationDialog(
            "Kill process",
            isPresented: Binding(
                get: { appState.pendingKill != nil },
                set: { if !$0 { appState.cancelPendingKill() } }
            ),
            presenting: appState.pendingKill
        ) { pending in
            Button("Kill PID \(pending.listener.pid) (port \(pending.listener.port))", role: .destructive) {
                appState.confirmPendingKill()
            }
            Button("Cancel", role: .cancel) { appState.cancelPendingKill() }
        } message: { pending in
            Text("Send SIGTERM to PID \(pending.listener.pid) — \(pending.listener.processName). If it ignores SIGTERM, Harbor sends SIGKILL after ~2 seconds.")
        }
        .alert(
            "Could not kill process",
            isPresented: Binding(
                get: { appState.lastKillError != nil },
                set: { if !$0 { appState.lastKillError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.lastKillError ?? "")
        }
    }

    private var overlapSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(appState.staticOverlaps) { overlap in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Port \(overlap.port) is claimed by \(overlap.projects.joined(separator: ", ")) — only one can bind it at a time.")
                        .font(.callout)
                    Spacer()
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let feedback = copyFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Copy port") {
                if let row = selectedRow {
                    Pasteboard.copy(String(row.port))
                    flash("Copied port \(row.port)")
                }
            }
            .disabled(selectedRow == nil)
            Button("Kill holder", role: .destructive) {
                if let listener = selectedRow?.listener {
                    appState.requestKill(listener: listener)
                }
            }
            .disabled(selectedRow?.listener == nil)
            Spacer()
            Button {
                appState.refreshPortsNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Port") { row in
                HStack(spacing: 4) {
                    if let overlap = overlapsByPort[row.port] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Claimed by multiple projects: \(overlap.projects.joined(separator: ", "))")
                    }
                    Text(String(row.port))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
            }
            .width(min: 50, ideal: 70)

            TableColumn("Claimed by") { row in
                Text(row.projectNames.isEmpty ? "—" : row.projectNames.joined(separator: ", "))
                    .foregroundStyle(row.projectNames.isEmpty ? Color.secondary : Color.primary)
                    .help(row.claimDetails.joined(separator: "\n"))
            }

            TableColumn("Status") { row in
                Text(statusText(for: row))
                    .foregroundStyle(row.listener == nil ? Color.secondary : Color.primary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Holder") { row in
                HStack(spacing: 4) {
                    if row.managedHolder != nil {
                        Image(systemName: "sailboat.fill")
                            .foregroundStyle(.green)
                            .help("Managed by Harbor")
                    }
                    Text(holderText(for: row))
                        .lineLimit(1)
                }
            }
        }
        .contextMenu(forSelectionType: HarborCoordinator.OverviewRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                if let listener = row.listener {
                    Button("Kill (port \(row.port), PID \(listener.pid))") {
                        appState.requestKill(listener: listener)
                    }
                }
                if !row.projectNames.isEmpty {
                    Button("Copy claimed by") {
                        Pasteboard.copy(row.projectNames.joined(separator: ", "))
                        flash("Copied projects")
                    }
                }
                Button("Copy port") {
                    Pasteboard.copy(String(row.port))
                    flash("Copied port \(row.port)")
                }
            }
        } primaryAction: { ids in
            selection = ids
        }
    }

    private func statusText(for row: HarborCoordinator.OverviewRow) -> String {
        guard row.listener != nil else { return "Free" }
        return row.managedHolder == nil ? "Listening (external)" : "Listening (managed)"
    }

    private func holderText(for row: HarborCoordinator.OverviewRow) -> String {
        guard let listener = row.listener else { return "—" }
        if let holder = row.managedHolder {
            return "\(holder.projectName) · \(holder.processName) (PID \(listener.pid))"
        }
        return "\(listener.processName) (PID \(listener.pid))"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No claimed or listening ports yet.")
                .foregroundStyle(.secondary)
            Text("Declare ports in harbor.toml ([[process]].port or [[port_claim]]) to plan them across projects.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func flash(_ text: String) {
        copyFeedback = text
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = nil
        }
    }
}
