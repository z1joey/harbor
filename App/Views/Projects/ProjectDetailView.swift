import SwiftUI
import AppKit
import HarborCore

struct ProjectDetailView: View {
    @EnvironmentObject private var appState: AppState
    let project: Project

    @State private var selectedProcessName: String?
    /// Draggable log-pane height, persisted across launches like a sidebar width.
    @AppStorage("logPaneHeight") private var logPaneHeight: Double = 240
    @State private var dragStartHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
            if let error = project.configError {
                errorBanner(error)
            }
            conflictBanners
            overlapBanners
            Divider()
            processList
            logPaneResizer
            logPane
        }
        .projectConflictDialogs(projectID: project.id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                WrappingDetailText(
                    text: project.root?.path ?? "Unknown location — fix the config error below",
                    font: .caption,
                    foreground: .secondary
                )
            }
            Spacer()
            if appState.projectBrowserURL(project) != nil {
                Button("Open in Browser") { appState.openProjectInBrowser(project) }
            }
            Button("Start All") { appState.startProjectWithConfirmation(project) }
                .disabled(project.processes.isEmpty)
            Button("Stop All") { appState.stopProject(project) }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Config error").font(.callout).fontWeight(.semibold)
                Text(text).font(.caption)
                Button("Fix Config…") {
                    NSWorkspace.shared.open(project.configURL)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
    }

    /// Static overlap warning: another project already claims one of this
    /// project's ports. Purely config-level — nothing needs to be running.
    @ViewBuilder
    private var overlapBanners: some View {
        let overlaps = appState.staticOverlaps.filter { $0.projects.contains(project.name) }
        if !overlaps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(overlaps) { overlap in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Port \(overlap.port) is also claimed by \(overlap.projects.filter { $0 != project.name }.joined(separator: ", ")). Only one project can bind it at a time.")
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
        }
    }

    @ViewBuilder
    private var conflictBanners: some View {
        let projectConflicts = appState.conflicts.filter { $0.projectName == project.name }
        if !projectConflicts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(projectConflicts) { conflict in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Port \(conflict.port) is in use by \(conflict.holderLabel) (PID \(conflict.listener.pid)). Starting will ask for confirmation.")
                            .font(.caption)
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(Color.yellow.opacity(0.1))
        }
    }

    // MARK: - Process list

    private var processList: some View {
        let verifications = appState.portVerifications(for: project)
        return VStack(spacing: 0) {
            if project.processes.isEmpty {
                emptyProcessList
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(project.processes) { definition in
                            processRow(definition, verification: verifications[definition.name])
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyProcessList: some View {
        VStack(spacing: 6) {
            Text(project.configError == nil
                 ? "This project has no [[process]] entries yet."
                 : "Fix the config error above to load processes.")
                .foregroundStyle(.secondary)
            if project.configError == nil {
                Button("Open \(project.configFileName)…") {
                    NSWorkspace.shared.open(project.configURL)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processRow(_ definition: ProcessDefinition, verification: PortVerification?) -> some View {
        let key = ProcessKey(projectID: project.id, processName: definition.name)
        let status = appState.supervisor.status(for: key)
        let isSelected = selectedProcessName == definition.name
        let canStart = !status.state.isRunningLike && status.state != .stopping
        let canStop = status.state.isRunningLike || status.state == .stopping
        let showPortLint = definition.port.map {
            !PortPlanner.commandReferencesDeclaredPort(definition.command, port: $0, envName: definition.portEnv)
        } ?? false

        return HStack(spacing: 10) {
            Circle()
                .fill(statusColor(status.state))
                .frame(width: 9, height: 9)
                .help(statusText(status))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(definition.name).fontWeight(.medium)
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if status.restartAttempt > 0 {
                        Text("restart ×\(status.restartAttempt)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if definition.autoRestart {
                        Text("auto-restart")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let verification {
                        let observed = verification.observed.sorted().map(String.init).joined(separator: ", ")
                        Text("listening on \(observed), expected \(verification.expected)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Command may not consume $\(definition.portEnv); the process bound a different port.")
                    }
                    if showPortLint {
                        Text("$\(definition.portEnv) not in command")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Add $\(definition.portEnv) or the declared port number to the command so Harbor's injected port is used.")
                    }
                }
                WrappingDetailText(text: definition.command, font: .caption, foreground: .secondary)
                if let cwd = definition.cwd, !cwd.isEmpty {
                    WrappingDetailText(text: "cwd: \(cwd)", font: .caption, foreground: .secondary)
                }
            }
            Spacer()
            if let port = definition.port {
                Text(":\(port)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let pid = status.pid {
                Text("PID \(pid)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if canStart {
                    Button("Start") { appState.start(project: project, definition: definition) }
                }
                if canStop {
                    Button("Stop", role: .destructive) { appState.stop(project: project, definition: definition) }
                    Button("Restart") { appState.restart(project: project, definition: definition) }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .onTapGesture { selectedProcessName = definition.name }
    }

    // MARK: - Logs

    /// Sidebar-style grabber between the process list and the logs: drag it
    /// up/down to resize the log pane (height persists across launches).
    private var logPaneResizer: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 10)
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? logPaneHeight
                        dragStartHeight = start
                        logPaneHeight = min(500, max(80, start - value.translation.height))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .accessibilityLabel("Resize logs")
            .accessibilityValue("\(Int(logPaneHeight)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: logPaneHeight = min(500, logPaneHeight + 20)
                case .decrement: logPaneHeight = max(80, logPaneHeight - 20)
                @unknown default: break
                }
            }
    }

    @ViewBuilder
    private var logPane: some View {
        if let definition = project.processes.first(where: { $0.name == selectedProcessName }) {
            let key = ProcessKey(projectID: project.id, processName: definition.name)
            let status = appState.supervisor.status(for: key)
            LogPaneView(
                buffer: appState.supervisor.logBuffer(for: key),
                processName: definition.name,
                port: livePort(for: definition, status: status),
                readyURL: definition.readyURL(port: livePort(for: definition, status: status)),
                isReady: status.ready
            )
            // New identity per process: the pane's @State (snapshot, scroll)
            // must reset — otherwise it keeps showing the previous process's
            // lines until the new buffer happens to emit.
            .id(selectedProcessName)
            .frame(height: logPaneHeight)
        } else {
            Text("Select a process above to see its logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
        }
    }
}
