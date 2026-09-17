import SwiftUI
import AppKit

struct ProjectDetailView: View {
    @EnvironmentObject private var appState: AppState
    let project: Project

    @State private var selectedProcessName: String?
    @State private var showImportEditor = false
    @State private var importDraft: ConfigImporter.Draft?
    @State private var importDraftText = ""

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
            Divider()
            logPane
        }
        .projectConflictDialogs(projectID: project.id)
        .sheet(isPresented: $showImportEditor) {
            ImportDraftEditor(
                root: project.root,
                draft: $importDraft,
                draftText: $importDraftText,
                onSaved: { appState.reloadConfigsIfStale() }
            )
            .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                WrappingDetailText(
                    text: project.root.path,
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
                HStack(spacing: 8) {
                    if let configURL = project.configURL() {
                        Button("Fix Config…") {
                            NSWorkspace.shared.open(configURL)
                        }
                    }
                    if HarborConfigParser.locateConfig(in: project.root) == nil {
                        Button("Create Template Config") {
                            _ = appState.createTemplateConfig(at: project.root)
                            appState.reloadConfigsIfStale()
                        }
                    }
                    Button("Import from Procfile / package.json…") {
                        openImportEditor()
                    }
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
                Button("Open harbor.toml…") {
                    if let url = project.configURL() ?? HarborConfigParser.locateConfig(in: project.root) {
                        NSWorkspace.shared.open(url)
                    }
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
        let showPortLint = definition.autoPort
            && !PortPlanner.commandReferencesPortEnv(definition.command, envName: definition.portEnv)

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
                            .help("Add $\(definition.portEnv) to the command so Harbor's assigned port is used.")
                    }
                }
                WrappingDetailText(text: definition.command, font: .caption, foreground: .secondary)
                if let cwd = definition.cwd, !cwd.isEmpty {
                    WrappingDetailText(text: "cwd: \(cwd)", font: .caption, foreground: .secondary)
                }
            }
            Spacer()
            if definition.autoPort {
                if let assigned = status.assignedPort {
                    Text(":\(assigned) auto")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(":auto")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if let port = definition.port {
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
            .frame(height: 240)
        } else {
            Text("Select a process above to see its logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
        }
    }

    // MARK: - Import

    private func openImportEditor() {
        let drafts = appState.importDrafts(at: project.root)
        if let first = drafts.first {
            importDraft = first
            importDraftText = first.toml
        } else {
            let template = ConfigImporter.Draft(
                sourceName: "manual template",
                notes: [],
                toml: HarborConfigParser.templateText(projectName: project.name)
            )
            importDraft = template
            importDraftText = template.toml
        }
        showImportEditor = true
    }
}
