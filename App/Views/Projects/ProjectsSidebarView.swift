import SwiftUI
import AppKit

struct ProjectsSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: MainWindowView.SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Projects") {
                if appState.registry.projects.isEmpty {
                    Text("No projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(appState.registry.projects) { project in
                    HStack {
                        Image(systemName: "folder")
                        Text(project.name).lineLimit(1)
                        Spacer()
                        runningBadge(for: project)
                    }
                    .tag(MainWindowView.SidebarItem.project(project.id) as MainWindowView.SidebarItem?)
                    .contextMenu {
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
                .tag(MainWindowView.SidebarItem.portsOverview as MainWindowView.SidebarItem?)
                HStack {
                    Image(systemName: "dot.3.connected.endpoints")
                    Text("Listening Ports")
                    Spacer()
                    Text(String(appState.portObserver.listeners.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(MainWindowView.SidebarItem.ports as MainWindowView.SidebarItem?)
            }
        }
        .listStyle(.sidebar)
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
