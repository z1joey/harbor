import SwiftUI
import HarborCore

/// Port Allocation Convention: pool leases (process ports inside the Harbor
/// pool) plus a second section for non-pool claims (`[[port_claim]]`,
/// hardcoded framework ports, …).
struct PortsOverviewView: View {
    @EnvironmentObject private var appState: AppState

    private enum Selection: Hashable {
        case convention(String)
        case other(Int)
    }

    @State private var selection: Selection?
    @State private var copyFeedback: String?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var showPoolEditor = false

    private var pool: PortPool { appState.portPoolStore.pool }

    private var holdersByPID: [pid_t: PortPlanner.ManagedHolder] {
        appState.managedHolders(for: appState.portObserver.listeners)
    }

    private var conventionRows: [HarborCoordinator.ConventionRow] {
        HarborCoordinator.conventionRows(
            pool: pool,
            projects: appState.registry.projects,
            listeners: appState.portObserver.listeners,
            holdersByPID: holdersByPID
        )
    }

    private var otherRows: [HarborCoordinator.OverviewRow] {
        HarborCoordinator.otherClaimRows(
            pool: pool,
            projects: appState.registry.projects,
            listeners: appState.portObserver.listeners,
            holdersByPID: holdersByPID
        )
    }

    private var overlapsByPort: [Int: PortPlanner.StaticOverlap] {
        Dictionary(appState.staticOverlaps.map { ($0.port, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private var selectedPort: Int? {
        switch selection {
        case .convention(let id):
            return conventionRows.first { $0.id == id }?.port
        case .other(let port):
            return port
        case nil:
            return nil
        }
    }

    private var selectedListener: Listener? {
        switch selection {
        case .convention(let id):
            return conventionRows.first { $0.id == id }?.listener
        case .other(let port):
            return otherRows.first { $0.port == port }?.listener
        case nil:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.staticOverlaps.isEmpty {
                overlapSummary
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if conventionRows.isEmpty && otherRows.isEmpty {
                emptyState
            } else {
                tables
            }
        }
        .navigationTitle("Port Allocation Convention")
        .sheet(isPresented: $showPoolEditor) {
            PortPoolEditorSheet(pool: pool)
                .environmentObject(appState)
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
    }

    private var poolSummaryText: String {
        let summary = appState.coordinator.poolSummary()
        return "\(summary.label) · \(summary.allocated) / \(summary.capacity) allocated"
    }

    private var nextFreeText: String {
        if let port = appState.coordinator.nextFreePoolPort() {
            return "next free \(port)"
        }
        return "pool exhausted"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Port Allocation Convention")
                    .font(.headline)
                Text("\(poolSummaryText) · \(nextFreeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Edit pool…") {
                showPoolEditor = true
            }
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
                if let port = selectedPort {
                    Pasteboard.copy(String(port))
                    flash("Copied port \(port)")
                }
            }
            .disabled(selectedPort == nil)
            Button("Kill holder", role: .destructive) {
                if let listener = selectedListener {
                    appState.requestKill(listener: listener)
                }
            }
            .disabled(selectedListener == nil)
            Spacer()
            Button {
                appState.refreshPortsNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
    }

    private var tables: some View {
        VStack(alignment: .leading, spacing: 0) {
            conventionSection
                .frame(maxHeight: .infinity)
            if !otherRows.isEmpty {
                Divider()
                otherSection
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var conventionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pool leases")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            if conventionRows.isEmpty {
                Text("No process has a port in the Harbor pool yet. Declare [[process]].port from the pool (the harbor-pilot skill does this when you register a project).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                Table(conventionRows, selection: conventionSelection) {
                    TableColumn("Port") { row in
                        portCell(port: row.port)
                    }
                    .width(min: 50, ideal: 70)

                    TableColumn("Project") { row in
                        Text(row.projectName)
                    }

                    TableColumn("Process") { row in
                        Text(row.processName)
                    }

                    TableColumn("Status") { row in
                        Text(statusText(listener: row.listener, managed: row.managedHolder != nil))
                            .foregroundStyle(row.listener == nil ? Color.secondary : Color.primary)
                    }
                    .width(min: 90, ideal: 150)

                    TableColumn("Holder") { row in
                        holderCell(listener: row.listener, managed: row.managedHolder)
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .contextMenu(forSelectionType: HarborCoordinator.ConventionRow.ID.self) { ids in
                    if let row = conventionRows.first(where: { ids.contains($0.id) }) {
                        rowContextMenu(port: row.port, listener: row.listener, projectNames: [row.projectName])
                    }
                } primaryAction: { ids in
                    if let id = ids.first { selection = .convention(id) }
                }
            }
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other claims")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Text("Ports outside the pool — [[port_claim]]s and hardcoded process ports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            Table(otherRows, selection: otherSelection) {
                TableColumn("Port") { row in
                    portCell(port: row.port)
                }
                .width(min: 50, ideal: 70)

                TableColumn("Claimed by") { row in
                    Text(row.projectNames.isEmpty ? "—" : row.projectNames.joined(separator: ", "))
                        .foregroundStyle(row.projectNames.isEmpty ? Color.secondary : Color.primary)
                        .help(row.claimDetails.joined(separator: "\n"))
                }

                TableColumn("Status") { row in
                    Text(statusText(listener: row.listener, managed: row.managedHolder != nil))
                        .foregroundStyle(row.listener == nil ? Color.secondary : Color.primary)
                }
                .width(min: 90, ideal: 150)

                TableColumn("Holder") { row in
                    holderCell(listener: row.listener, managed: row.managedHolder)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .contextMenu(forSelectionType: HarborCoordinator.OverviewRow.ID.self) { ids in
                if let row = otherRows.first(where: { ids.contains($0.port) }) {
                    rowContextMenu(port: row.port, listener: row.listener, projectNames: row.projectNames)
                }
            } primaryAction: { ids in
                if let id = ids.first { selection = .other(id) }
            }
        }
    }

    private var conventionSelection: Binding<Set<HarborCoordinator.ConventionRow.ID>> {
        Binding(
            get: {
                if case .convention(let id) = selection { return [id] }
                return []
            },
            set: { newValue in
                selection = newValue.first.map { .convention($0) }
            }
        )
    }

    private var otherSelection: Binding<Set<HarborCoordinator.OverviewRow.ID>> {
        Binding(
            get: {
                if case .other(let port) = selection { return [port] }
                return []
            },
            set: { newValue in
                selection = newValue.first.map { .other($0) }
            }
        )
    }

    @ViewBuilder
    private func portCell(port: Int) -> some View {
        HStack(spacing: 4) {
            if let overlap = overlapsByPort[port] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Claimed by multiple projects: \(overlap.projects.joined(separator: ", "))")
            }
            Text(String(port))
                .monospacedDigit()
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func holderCell(listener: Listener?, managed: PortPlanner.ManagedHolder?) -> some View {
        HStack(spacing: 4) {
            if managed != nil {
                Image(systemName: "sailboat.fill")
                    .foregroundStyle(.green)
                    .help("Managed by Harbor")
            }
            Text(holderText(listener: listener, managed: managed))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func rowContextMenu(port: Int, listener: Listener?, projectNames: [String]) -> some View {
        if let listener {
            Button("Kill (port \(port), PID \(listener.pid))") {
                appState.requestKill(listener: listener)
            }
        }
        if !projectNames.isEmpty {
            Button("Copy claimed by") {
                Pasteboard.copy(projectNames.joined(separator: ", "))
                flash("Copied projects")
            }
        }
        Button("Copy port") {
            Pasteboard.copy(String(port))
            flash("Copied port \(port)")
        }
    }

    private func statusText(listener: Listener?, managed: Bool) -> String {
        guard listener != nil else { return "Free" }
        return managed ? "Listening (managed)" : "Listening (external)"
    }

    private func holderText(listener: Listener?, managed: PortPlanner.ManagedHolder?) -> String {
        guard let listener else { return "—" }
        if let managed {
            return "\(managed.projectName) · \(managed.processName) (PID \(listener.pid))"
        }
        return "\(listener.processName) (PID \(listener.pid))"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No pool leases or other claims yet.")
                .foregroundStyle(.secondary)
            Text("Declare [[process]].port from the Harbor pool (the harbor-pilot skill does this when you register a project). Out-of-pool ports and [[port_claim]]s still show here as other claims.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func flash(_ text: String) {
        // Cancel the previous clear so a second copy isn't wiped early.
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copyFeedback = nil
        }
    }
}
