import SwiftUI
import AppKit
import HarborCore

struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var expandedListenerID: Listener.ID?

    private let maxPortRows = 8

    var body: some View {
        // One snapshot per render — the per-row helpers each used to trigger
        // their own process-table walk / conflict computation.
        let listeners = appState.portObserver.listeners
        let conflicts = appState.conflicts
        let holdersByPID = appState.managedHolders(for: listeners)
        let verifications = appState.allPortVerifications()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Harbor").font(.headline)
                Spacer()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let killError = appState.lastKillError {
                // Kill failures from every flow land here — the popover is
                // open when most kills happen, and no alert can present.
                HStack {
                    Label(killError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer()
                    Button("Dismiss") { appState.lastKillError = nil }
                        .controlSize(.small)
                }
            }

            Divider()
            projectsSection(conflicts: conflicts, verifications: verifications)

            Divider()
            KeepAwakeRow(sleepGuard: appState.sleepGuard)

            Divider()
            portsSection(listeners: listeners, holdersByPID: holdersByPID)

            // Confirmation dialogs (system alerts) cannot be presented from a
            // MenuBarExtra popover window on macOS 13 — their buttons never
            // fire. Pending confirmations render inline instead.
            if inlineConfirmation != nil {
                Divider()
                inlineConfirmationSection
            }

            Divider()
            HStack {
                Button("Open Harbor…") { openMainWindow() }
                Spacer()
                Button("Quit Harbor") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 400)
    }

    private enum InlineConfirmation {
        case startAll
        case conflict
        case claim
        case kill
    }

    private var inlineConfirmation: InlineConfirmation? {
        if appState.pendingStartAllConflicts != nil { return .startAll }
        if appState.pendingConflict != nil { return .conflict }
        if appState.pendingClaimConflict != nil { return .claim }
        if appState.pendingKill != nil { return .kill }
        return nil
    }

    @ViewBuilder
    private var inlineConfirmationSection: some View {
        switch inlineConfirmation {
        case .startAll:
            if let pending = appState.pendingStartAllConflicts {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Port conflict — \(pending.projectName)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ForEach(pending.items) { conflict in
                        Text("Port \(conflict.port) is in use by \(conflict.holderLabel) (PID \(conflict.listener.pid)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Free ports & start all") { appState.confirmPendingStartAllConflictsFreeingPorts() }
                        Button("Start all anyway") { appState.confirmPendingStartAllConflicts() }
                        Spacer()
                        Button("Cancel") { appState.cancelPendingStartAllConflicts() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
        case .conflict:
            if let pending = appState.pendingConflict {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Port \(pending.port) is in use", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("Held by \(pending.owner) (PID \(pending.pid)). Starting \"\(pending.processName)\" may fail.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(pending.holder == nil
                               ? "Kill PID \(pending.pid) & start"
                               : "Stop \(pending.owner) & start") {
                            appState.confirmPendingConflictFreeingPort()
                        }
                        Button("Start anyway") { appState.confirmPendingConflict() }
                        Spacer()
                        Button("Cancel") { appState.cancelPendingConflict() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
        case .claim:
            if let pending = appState.pendingClaimConflict {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Depended-on port held — \(pending.projectName)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ForEach(pending.items) { conflict in
                        Text("Port \(conflict.port) (\(conflict.processName ?? "claim")) is in use by \(conflict.holderLabel) (PID \(conflict.listener.pid)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("This port is a [[port_claim]] — its holder is usually infrastructure and is not killed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(claimButtonTitle(for: pending), role: .destructive) {
                            appState.confirmPendingClaimConflict()
                        }
                        Spacer()
                        Button("Cancel") { appState.cancelPendingClaimConflict() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
        case .kill:
            if let pending = appState.pendingKill {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Kill PID \(pending.listener.pid)?", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("Port \(pending.listener.port) — \(pending.listener.processName). SIGTERM first, SIGKILL after ~2s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Kill", role: .destructive) { appState.confirmPendingKill() }
                        Spacer()
                        Button("Cancel") { appState.cancelPendingKill() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
        case nil:
            EmptyView()
        }
    }

    private func claimButtonTitle(for pending: AppState.PendingClaimConflict) -> String {
        if let processName = pending.processName {
            return "Start \"\(processName)\" anyway"
        }
        return "Start all anyway"
    }

    private var summaryText: String {
        let count = appState.managedRunningCount
        if appState.hasVisibleConflict { return "conflict · \(count) running" }
        if count > 0 { return "\(count) running" }
        return "idle"
    }

    // MARK: - Projects

    @ViewBuilder
    private func projectsSection(conflicts: [PortPlanner.RuntimeConflict],
                                 verifications: [ProcessKey: PortVerification]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECTS").font(.caption2).foregroundStyle(.secondary)
            if appState.registry.projects.isEmpty {
                Text("No projects yet. Register one with the harbor-pilot skill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.registry.projects) { project in
                projectRow(project, conflicts: conflicts, verifications: verifications)
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project,
                            conflicts: [PortPlanner.RuntimeConflict],
                            verifications: [ProcessKey: PortVerification]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let conflict = conflicts.first(where: { $0.projectName == project.name }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                        .help("Port \(conflict.port) is in use by \(conflict.holderLabel) (PID \(conflict.listener.pid))")
                }
                Spacer()
                if let browserURL = appState.projectBrowserURL(project) {
                    Button {
                        appState.openProjectInBrowser(project)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(browserURL.absoluteString)")
                }
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
                    let key = ProcessKey(projectID: project.id, processName: definition.name)
                    processChip(project: project,
                                definition: definition,
                                verification: verifications[key])
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

    @ViewBuilder
    private func processChip(project: Project,
                           definition: ProcessDefinition,
                           verification: PortVerification?) -> some View {
        let key = ProcessKey(projectID: project.id, processName: definition.name)
        let status = appState.supervisor.status(for: key)
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor(status.state))
                .frame(width: 7, height: 7)
            Text(definition.name)
                .font(.caption)
                .lineLimit(1)
            if let portText = portLabel(for: definition, status: status) {
                Text(portText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .help(processStatusHelp(definition: definition, status: status, verification: verification))
    }

    // MARK: - Keep awake

    /// "Keep Awake" switch: blocks idle system sleep while on, so long tasks
    /// can run to completion. Lives in its own row-struct because the switch
    /// state lives on SleepGuard, not on AppState.
    private struct KeepAwakeRow: View {
        @ObservedObject var sleepGuard: SleepGuard

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: sleepGuard.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(sleepGuard.isEnabled ? Color.orange : Color.secondary)
                Text("Keep Awake")
                    .font(.caption)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sleepGuard.isEnabled },
                    set: { sleepGuard.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Prevent idle sleep while long tasks run — the display may still sleep. "
                      + "Released automatically when Harbor quits.")
            }
        }
    }

    // MARK: - Ports

    @ViewBuilder
    private func portsSection(listeners: [Listener],
                              holdersByPID: [pid_t: PortPlanner.ManagedHolder]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LISTENING PORTS").font(.caption2).foregroundStyle(.secondary)
            if listeners.isEmpty {
                Text(appState.portObserver.lastError ?? "No listening TCP ports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(listeners.prefix(maxPortRows))) { listener in
                portRow(listener, isManaged: holdersByPID[listener.pid] != nil)
            }
            if listeners.count > maxPortRows {
                Text("… \(listeners.count - maxPortRows) more — open Harbor for the full list")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ listener: Listener, isManaged: Bool) -> some View {
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
                    if isManaged {
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
                WrappingDetailText(text: listener.commandDisplay)
                    .padding(.leading, 11)
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
                    Button("Copy command") { Pasteboard.copy(listener.commandDisplay) }
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
