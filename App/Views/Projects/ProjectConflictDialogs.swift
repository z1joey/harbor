import SwiftUI
import HarborCore

/// Confirmation dialogs for port conflicts (single process + start-all),
/// scoped to a project when `projectID` is given. Shared by the popover,
/// the project detail view, and every start flow. Each dialog offers the
/// three ways out: free the port (stop the managed holder or kill the
/// foreign process tree), start anyway, or cancel.
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

    private var claimVisible: Bool {
        guard let pending = appState.pendingClaimConflict else { return false }
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
            ) { pending in
                Button(Self.freeButtonTitle(for: pending), role: .destructive) {
                    appState.confirmPendingConflictFreeingPort()
                }
                Button("Start anyway (port \(pending.port) is in use)", role: .destructive) {
                    appState.confirmPendingConflict()
                }
                Button("Cancel", role: .cancel) { appState.cancelPendingConflict() }
            } message: { pending in
                Text(Self.message(for: pending))
            }
            .confirmationDialog(
                "Port conflict",
                isPresented: Binding(
                    get: { startAllVisible },
                    set: { if !$0 { appState.cancelPendingStartAllConflicts() } }
                ),
                presenting: startAllVisible ? appState.pendingStartAllConflicts : nil
            ) { pending in
                Button("Free ports & start all", role: .destructive) {
                    appState.confirmPendingStartAllConflictsFreeingPorts()
                }
                Button("Start all anyway", role: .destructive) {
                    appState.confirmPendingStartAllConflicts()
                }
                Button("Cancel", role: .cancel) { appState.cancelPendingStartAllConflicts() }
            } message: { pending in
                Text(pending.items.map { Self.message(for: $0) }.joined(separator: "\n"))
            }
            .confirmationDialog(
                "Port in use",
                isPresented: Binding(
                    get: { claimVisible },
                    set: { if !$0 { appState.cancelPendingClaimConflict() } }
                ),
                presenting: claimVisible ? appState.pendingClaimConflict : nil
            ) { pending in
                Button(Self.claimButtonTitle(for: pending), role: .destructive) {
                    appState.confirmPendingClaimConflict()
                }
                Button("Cancel", role: .cancel) { appState.cancelPendingClaimConflict() }
            } message: { pending in
                Text(pending.items.map { Self.message(for: $0) }.joined(separator: "\n"))
            }
    }

    /// Held `[[port_claim]]`s get no "free the port" escape: their holder is
    /// normally infrastructure (e.g. com.docker.backend) that must not be
    /// killed — the user decides between starting anyway and cancelling.
    private static func claimButtonTitle(for pending: AppState.PendingClaimConflict) -> String {
        if let processName = pending.processName {
            return "Start \"\(processName)\" anyway"
        }
        return "Start all anyway"
    }

    private static func freeButtonTitle(for pending: AppState.PendingConflict) -> String {
        if let holder = pending.holder {
            return "Stop \(holder.projectName) · \(holder.processName) & start"
        }
        return "Kill PID \(pending.pid) & start"
    }

    private static func message(for pending: AppState.PendingConflict) -> String {
        let holder = pending.holder == nil
            ? "\(pending.owner) (PID \(pending.pid))"
            : "\(pending.owner) — managed by Harbor (PID \(pending.pid))"
        return "Port \(pending.port) is in use by \(holder). Starting \"\(pending.processName)\" may fail."
    }

    private static func message(for conflict: PortPlanner.RuntimeConflict) -> String {
        let holder = conflict.managedHolder == nil
            ? "\(conflict.listener.processName) (PID \(conflict.listener.pid))"
            : "\(conflict.holderLabel) — managed by Harbor (PID \(conflict.listener.pid))"
        let consumer = conflict.processName ?? "this project"
        return "Port \(conflict.port) is in use by \(holder). Starting \"\(consumer)\" may fail."
    }
}

extension View {
    func projectConflictDialogs(projectID: String? = nil) -> some View {
        modifier(ProjectConflictDialogs(projectID: projectID))
    }
}
