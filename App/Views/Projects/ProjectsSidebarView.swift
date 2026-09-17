import SwiftUI
import AppKit
import HarborCore

struct ProjectsSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: MainWindowView.SidebarItem?

    var body: some View {
        List {
            Section("Projects") {
                if appState.registry.projects.isEmpty {
                    Text("No projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contextMenu { addProjectContextMenu() }
                }
                ForEach(appState.registry.projects) { project in
                    sidebarButton(
                        item: .project(project.id),
                        label: { projectRow(project) }
                    )
                    .contextMenu {
                        addProjectContextMenu()
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([project.root])
                        }
                        if let configURL = project.configURL() {
                            Button("Open \(configURL.lastPathComponent)…") {
                                NSWorkspace.shared.open(configURL)
                            }
                        }
                        Divider()
                        Button("Remove Project", role: .destructive) {
                            DispatchQueue.main.async {
                                appState.requestRemoveProject(project)
                            }
                        }
                    }
                }
            }
            Section("Observe") {
                sidebarButton(
                    item: .portsOverview,
                    label: {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                            Text("Ports Overview")
                            Spacer()
                            if !appState.staticOverlaps.isEmpty {
                                Text(String(appState.staticOverlaps.count))
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.3)))
                            }
                        }
                    }
                )
                sidebarButton(
                    item: .ports,
                    label: {
                        HStack {
                            Image(systemName: "dot.3.connected.endpoints")
                            Text("Listening Ports")
                            Spacer()
                            Text(String(appState.portObserver.listeners.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                )
            }
        }
        .listStyle(.sidebar)
        .contextMenu { addProjectContextMenu() }
    }

    @ViewBuilder
    private func addProjectContextMenu() -> some View {
        Button("Add Project…") {
            appState.showAddProjectSheet = true
        }
    }

    private func sidebarButton<ItemLabel: View>(
        item: MainWindowView.SidebarItem,
        @ViewBuilder label: () -> ItemLabel
    ) -> some View {
        Button {
            selection = item
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == item ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        HStack {
            Image(systemName: "folder")
            Text(project.name).lineLimit(1)
            Spacer()
            runningBadge(for: project)
        }
    }

    @ViewBuilder
    private func runningBadge(for project: Project) -> some View {
        let count = project.processes.filter {
            appState.supervisor.status(for: ProcessKey(projectID: project.id, processName: $0.name)).state.isRunningLike
        }.count
        if count > 0 {
            Text(String(count))
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.green.opacity(0.25)))
        }
    }
}
