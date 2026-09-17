import SwiftUI

struct PortsTableView: View {
    @EnvironmentObject private var appState: AppState

    @State private var filter = ""
    @State private var mineOnly = false
    @State private var selection = Set<Listener.ID>()
    @State private var copyFeedback: String?

    private var filtered: [Listener] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return appState.portObserver.listeners.filter { listener in
            if mineOnly && !listener.isMine { return false }
            if query.isEmpty { return true }
            return String(listener.port).contains(query)
                || listener.processName.lowercased().contains(query)
                || (listener.command?.lowercased().contains(query) ?? false)
                || String(listener.pid).contains(query)
        }
    }

    private var selectedListener: Listener? {
        guard let id = selection.first else { return nil }
        return appState.portObserver.listeners.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if let error = appState.portObserver.lastError {
                Text("lsof error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let listener = selectedListener {
                commandDetailPanel(listener)
            }
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                table
                    .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Kill process",
            isPresented: Binding(
                get: { appState.pendingKill != nil },
                set: { if !$0 { appState.cancelPendingKill() } }
            ),
            presenting: appState.pendingKill
        ) { pending in
            Button("Kill PID \(pending.listener.pid) (port \(pending.listener.port))", role: .destructive) {
                appState.confirmPendingKill()
            }
            Button("Cancel", role: .cancel) { appState.cancelPendingKill() }
        } message: { pending in
            Text("Send SIGTERM to PID \(pending.listener.pid) — \(pending.listener.processName). If it ignores SIGTERM, Harbor sends SIGKILL after ~2 seconds.")
        }
        .alert(
            "Could not kill process",
            isPresented: Binding(
                get: { appState.lastKillError != nil },
                set: { if !$0 { appState.lastKillError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.lastKillError ?? "")
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Port") { listener in
                Text(String(listener.port))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Proto") { listener in
                Text(listener.proto)
            }
            .width(min: 44, ideal: 54)

            TableColumn("PID") { listener in
                Text(String(listener.pid)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Process") { listener in
                HStack(spacing: 4) {
                    if appState.isManagedOrDescendant(listener.pid) {
                        Image(systemName: "sailboat.fill")
                            .foregroundStyle(.green)
                            .help("Managed by Harbor")
                    }
                    Text(listener.processName).lineLimit(1)
                }
            }

            TableColumn("User") { listener in
                Text(listener.user)
            }
            .width(min: 60, ideal: 100)

            TableColumn("Command / Path") { listener in
                Text(listener.commandDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .help(listener.commandDisplay)
            }
        }
        .contextMenu(forSelectionType: Listener.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            selection = ids
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<Listener.ID>) -> some View {
        let targets = appState.portObserver.listeners.filter { ids.contains($0.id) }
        ForEach(Array(targets)) { listener in
            Button("Kill (port \(listener.port), PID \(listener.pid))") {
                appState.requestKill(listener: listener)
            }
        }
        Divider()
        Button("Copy port") {
            Pasteboard.copy(targets.map { String($0.port) }.joined(separator: "\n"))
            flash("Copied port")
        }
        Button("Copy PID") {
            Pasteboard.copy(targets.map { String($0.pid) }.joined(separator: "\n"))
            flash("Copied PID")
        }
        Button("Copy command") {
            Pasteboard.copy(targets.map(\.commandDisplay).joined(separator: "\n"))
            flash("Copied command")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Filter (port, process, PID…)", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            Toggle("Mine only", isOn: $mineOnly)
                .toggleStyle(.checkbox)
            Spacer()
            if let feedback = copyFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Copy port") {
                if let listener = selectedListener {
                    Pasteboard.copy(String(listener.port))
                    flash("Copied port \(listener.port)")
                }
            }
            .disabled(selectedListener == nil)
            Button("Copy PID") {
                if let listener = selectedListener {
                    Pasteboard.copy(String(listener.pid))
                    flash("Copied PID \(listener.pid)")
                }
            }
            .disabled(selectedListener == nil)
            Button("Copy command") {
                if let listener = selectedListener {
                    Pasteboard.copy(listener.commandDisplay)
                    flash("Copied command")
                }
            }
            .disabled(selectedListener == nil)
            Button("Kill", role: .destructive) {
                if let listener = selectedListener {
                    appState.requestKill(listener: listener)
                }
            }
            .disabled(selectedListener == nil)
            Button {
                appState.refreshPortsNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
    }

    private func commandDetailPanel(_ listener: Listener) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Command / Path — port \(listener.port), PID \(listener.pid)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy command") {
                    Pasteboard.copy(listener.commandDisplay)
                    flash("Copied command")
                }
                .controlSize(.small)
            }
            ScrollView {
                WrappingDetailText(text: listener.commandDisplay)
            }
            .frame(minHeight: 48, maxHeight: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(filter.isEmpty || mineOnly
                 ? "No listening TCP ports detected."
                 : "No listening ports match your filter.")
                .foregroundStyle(.secondary)
            Text("Harbor refreshes the list every 2 seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func flash(_ text: String) {
        copyFeedback = text
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = nil
        }
    }
}
