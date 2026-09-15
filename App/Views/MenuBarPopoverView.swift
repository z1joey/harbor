import SwiftUI
import AppKit

struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var portFilter = ""
    @State private var expandedListenerID: Listener.ID?

    private let maxPortRows = 8

    private var filteredListeners: [Listener] {
        let query = portFilter.trimmingCharacters(in: .whitespaces)
        var list = appState.portObserver.listeners
        if !query.isEmpty {
            list = list.filter {
                String($0.port).contains(query) || $0.processName.localizedCaseInsensitiveContains(query)
            }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Harbor").font(.headline)
                Spacer()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            projectsSection

            Divider()
            portsSection

            Divider()
            HStack {
                Button("Open Harbor…") { openMainWindow() }
                Spacer()
                Button("Quit Harbor") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 400)
        .confirmationDialog(
            "Port conflict",
            isPresented: Binding(
                get: { appState.pendingConflict != nil },
                set: { if !$0 { appState.cancelPendingConflict() } }
            ),
            presenting: appState.pendingConflict
        ) { conflict in
            Button("Start anyway (port \(conflict.port) is in use)", role: .destructive) {
                appState.confirmPendingConflict()
            }
            Button("Cancel", role: .cancel) { appState.cancelPendingConflict() }
        } message: { conflict in
            Text("Port \(conflict.port) is already in use by \(conflict.owner) (PID \(conflict.pid)). Starting \"\(conflict.processName)\" may fail.")
        }
        .confirmationDialog(
            "Port conflict",
            isPresented: Binding(
                get: { appState.pendingStartAllConflicts != nil },
                set: { if !$0 { appState.cancelPendingStartAllConflicts() } }
            ),
            presenting: appState.pendingStartAllConflicts
        ) { pending in
            Button("Start all anyway", role: .destructive) {
                appState.confirmPendingStartAllConflicts()
            }
            Button("Cancel", role: .cancel) { appState.cancelPendingStartAllConflicts() }
        } message: { pending in
            Text(pending.items.map { "Port \($0.port) (\($0.processName)) is in use by \($0.owner) (PID \($0.pid))" }
                .joined(separator: "\n"))
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

    private var summaryText: String {
        let count = appState.managedRunningCount
        if appState.hasVisibleConflict { return "conflict · \(count) running" }
        if count > 0 { return "\(count) running" }
        return "idle"
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECTS").font(.caption2).foregroundStyle(.secondary)
            if appState.registry.projects.isEmpty {
                Text("No projects yet. Open Harbor to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.registry.projects) { project in
                projectRow(project)
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let conflict = appState.conflicts.first(where: { $0.projectName == project.name }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                        .help("Port \(conflict.port) is in use by \(conflict.owner) (PID \(conflict.pid))")
                }
                Spacer()
                Button {
                    appState.startProjectWithConfirmation(project)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(project.processes.isEmpty)
                .help("Start all processes")

                Button {
                    appState.stopProject(project)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .disabled(appState.supervisor.runningCount() == 0
                          || !project.processes.contains {
                              appState.supervisor.status(for: ProcessKey(projectID: project.id, processName: $0.name)).state.isRunningLike
                          })
                .help("Stop all processes")
            }
            HStack(spacing: 10) {
                ForEach(project.processes) { definition in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(statusColor(appState.supervisor.status(for: ProcessKey(projectID: project.id, processName: definition.name)).state))
                            .frame(width: 7, height: 7)
                        Text(definition.name).font(.caption).lineLimit(1)
                    }
                }
            }
            if let error = project.configError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Ports

    @ViewBuilder
    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("LISTENING PORTS").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $portFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .font(.caption)
                    .controlSize(.small)
            }
            if filteredListeners.isEmpty {
                Text(appState.portObserver.lastError ?? "No listening TCP ports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(filteredListeners.prefix(maxPortRows))) { listener in
                portRow(listener)
            }
            if filteredListeners.count > maxPortRows {
                Text("… \(filteredListeners.count - maxPortRows) more — open Harbor for the full list")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ listener: Listener) -> some View {
        let expanded = expandedListenerID == listener.id
        VStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    expandedListenerID = expanded ? nil : listener.id
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(listener.isMine ? Color.accentColor : .secondary)
                        .frame(width: 5, height: 5)
                        .help(listener.isMine ? "Your process" : "Other user's process")
                    Text(String(listener.port))
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.medium)
                    Text(listener.processName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if appState.managedPIDs.contains(listener.pid) {
                        Text("managed")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                HStack(spacing: 8) {
                    Text("PID \(listener.pid) · \(listener.proto)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Kill") { appState.requestKill(listener: listener) }
                        .controlSize(.small)
                    Button("Copy port") { Pasteboard.copy(String(listener.port)) }
                        .controlSize(.small)
                    Button("Copy PID") { Pasteboard.copy(String(listener.pid)) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: HarborApp.mainWindowID)
    }
}
