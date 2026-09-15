import SwiftUI

/// Confirmation dialogs for port conflicts (single process + start-all),
/// scoped to a project when `projectID` is given. Shared by the popover and
/// the project detail view.
struct ProjectConflictDialogs: ViewModifier {
    @EnvironmentObject private var appState: AppState
    var projectID: String?

    private var conflictVisible: Bool {
        guard let pending = appState.pendingConflict else { return false }
        return projectID == nil || pending.key.projectID == projectID
    }

    private var startAllVisible: Bool {
        guard let pending = appState.pendingStartAllConflicts else { return false }
        return projectID == nil || pending.projectID == projectID
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Port conflict",
                isPresented: Binding(
                    get: { conflictVisible },
                    set: { if !$0 { appState.cancelPendingConflict() } }
                ),
                presenting: conflictVisible ? appState.pendingConflict : nil
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
                    get: { startAllVisible },
                    set: { if !$0 { appState.cancelPendingStartAllConflicts() } }
                ),
                presenting: startAllVisible ? appState.pendingStartAllConflicts : nil
            ) { pending in
                Button("Start all anyway", role: .destructive) {
                    appState.confirmPendingStartAllConflicts()
                }
                Button("Cancel", role: .cancel) { appState.cancelPendingStartAllConflicts() }
            } message: { pending in
                Text(pending.items.map { "Port \($0.port) (\($0.processName)) is in use by \($0.owner) (PID \($0.pid))" }
                    .joined(separator: "\n"))
            }
    }
}

extension View {
    func projectConflictDialogs(projectID: String? = nil) -> some View {
        modifier(ProjectConflictDialogs(projectID: projectID))
    }
}
