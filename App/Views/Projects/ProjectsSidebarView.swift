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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No projects yet")
                            .font(.caption)
                        Text("Register one with the harbor-pilot skill — it writes ~/.harbor and Harbor picks it up automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                ForEach(appState.registry.projects) { project in
                    sidebarButton(
                        item: .project(project.id),
                        label: { projectRow(project) }
                    )
                    .contextMenu {
                        if let root = project.root {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([root])
                            }
                        }
                        Button("Open \(project.configFileName)…") {
                            NSWorkspace.shared.open(project.configURL)
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
                            Text("Port Convention")
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
                            Image(systemName: "dot.radiowaves.left.and.right")
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
