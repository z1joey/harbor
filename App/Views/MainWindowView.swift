import SwiftUI
import AppKit
import HarborCore

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    enum SidebarItem: Hashable {
        case ports
        case portsOverview
        case project(String)
    }

    @State private var selection: SidebarItem? = .ports

    var body: some View {
        NavigationSplitView {
            ProjectsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: addProjectSheetBinding) {
            AddProjectSheet()
                .environmentObject(appState)
        }
        .navigationTitle("Harbor")
        .onAppear {
            appState.isMainWindowOpen = true
            selectDefaultSidebarItemIfNeeded()
        }
        .onReceive(appState.registry.$projects) { projects in
            if case .project(let id) = selection,
               !projects.contains(where: { $0.id == id }) {
                selection = projects.first.map { .project($0.id) } ?? .ports
            }
        }
        .onReceive(windowKeyPublisher) { _ in
            appState.reloadConfigsIfStale()
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

    private var addProjectSheetBinding: Binding<Bool> {
        Binding(
            get: { appState.showAddProjectSheet },
            set: { appState.showAddProjectSheet = $0 }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLoginEnabled },
            set: { appState.toggleLaunchAtLogin($0) }
        )
    }

    /// First launch: open the first project when one exists; otherwise Listening Ports.
    private func selectDefaultSidebarItemIfNeeded() {
        guard selection == .ports, appState.registry.projects.isEmpty == false,
              let first = appState.registry.projects.first else { return }
        selection = .project(first.id)
    }
}
