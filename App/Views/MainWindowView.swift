import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    enum SidebarItem: Hashable {
        case ports
        case portsOverview
        case project(String)
    }

    @State private var selection: SidebarItem? = .ports
    @State private var showAddSheet = false

    var body: some View {
        NavigationSplitView {
            ProjectsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAddSheet) {
            AddProjectSheet()
                .environmentObject(appState)
        }
        .navigationTitle("Harbor")
        .onAppear {
            appState.isMainWindowOpen = true
        }
        .onReceive(windowKeyPublisher) { _ in
            appState.reloadConfigsIfStale()
        }
        .onReceive(appState.registry.$projects) { projects in
            if case .project(let id) = selection,
               !projects.contains(where: { $0.id == id }) {
                selection = .ports
            }
        }
        .onDisappear {
            appState.isMainWindowOpen = false
            // Window closed: back to pure menubar agent (no Dock icon).
            NSApp.setActivationPolicy(.accessory)
        }
        .alert(
            "Launch at Login",
            isPresented: Binding(
                get: { appState.launchAtLoginError != nil },
                set: { if !$0 { appState.launchAtLoginError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.launchAtLoginError ?? "")
        }
    }

    private var windowKeyPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Project…", systemImage: "plus")
            }
        }
        if case .project(let id) = selection,
           let project = appState.registry.projects.first(where: { $0.id == id }) {
            ToolbarItem {
                Button("Remove Project", role: .destructive) {
                    appState.requestRemoveProject(project)
                }
            }
        }
        ToolbarItem {
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: launchAtLoginBinding)
            Divider()
            Button("Refresh Ports Now") {
                appState.refreshPortsNow()
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .ports:
            PortsTableView()
        case .portsOverview:
            PortsOverviewView()
        case .project(let id):
            projectDetail(id: id)
        case nil:
            Text("Select a project or Listening Ports in the sidebar.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func projectDetail(id: String) -> some View {
        Group {
            if let project = appState.registry.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
            } else {
                Text("Project not found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLoginEnabled },
            set: { appState.toggleLaunchAtLogin($0) }
        )
    }
}
