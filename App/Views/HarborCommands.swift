import SwiftUI
import AppKit
import HarborCore

struct HarborCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Project") {
            Button("Add Project…") {
                presentAddProject()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private func presentAddProject() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: HarborApp.mainWindowID)
        appState.showAddProjectSheet = true
    }
}
